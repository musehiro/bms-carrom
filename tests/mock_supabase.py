#!/usr/bin/env python3
"""Local mock of the Supabase endpoints BMS Carrom v7 uses, for tests only.

Stdlib only. Implements just enough of GoTrue + PostgREST + Realtime for
the Godot client (scripts/supabase.gd) to run its full flow against it:

  Auth:    POST /auth/v1/signup {}            -> anonymous session
           POST /auth/v1/otp {email}          -> "sends" code 123456
           POST /auth/v1/verify {email, token}-> session (token must be 123456)
           POST /auth/v1/token?grant_type=pkce (auth_code TESTCODE)
                                              -> session for google-user@gmail.com
           POST /auth/v1/token?grant_type=refresh_token
             {refresh_token: "ref-<uid>"}     -> ROTATED session, same user
             (unknown token -> 400)
  REST:    GET/POST /rest/v1/profiles (upsert by id, filter by id/gmail)
           POST /rest/v1/rpc/search_players {q, exclude_id}
           GET/POST/PATCH /rest/v1/invites (filters: to_id/group_id/status)
  v11 P2P: GET/POST/DELETE /rest/v1/matchmaking_queue (upsert by id)
           GET/PATCH /rest/v1/matches (filters: player_ids cs.{id}, group_id, status)
           POST /rest/v1/rpc/find_match {p_mode, p_widen} (atomic pairing,
             ±2 / ±4 window, stake validated against profiles.coins)
           POST /rest/v1/rpc/create_match_from_invites {p_group_id}
             (idempotent; all invites must be accepted)
           GET/POST/DELETE /rest/v1/presence (upsert by id)
           Fake Broadcast: a "broadcast" event on a realtime:carrom-match-*
             topic is stored + re-emitted to every WS client as a
             broadcast signal; GET /broadcast/<channel> lists stored
             messages (test-only seam — the real Realtime does this).
  Realtime: wss handshake on /realtime/v1/websocket; phx_join on
           realtime:public:invites is answered with phx_reply ok, and
           every invite INSERT/UPDATE is broadcast as postgres_changes.

Run: python3 tests/mock_supabase.py --port 18080
Health: GET /health -> {"ok": true}
Test seams: POST /__test__/otp_redirect_fail {"enabled": bool} — reject
OTP requests that carry redirect_to (fresh-project behaviour).
"""

import argparse
import base64
import hashlib
import json
import struct
import threading
import time
import uuid
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
OTP_CODE = "123456"
# Second accepted code, with a leading zero: proves the client sends the
# 6-digit code as a STRING end to end (an int parse would drop the zero
# and send "12345"). Accepted only for an email that was actually sent
# a code, same gate as the normal code.
OTP_CODE_LEADING_ZERO = "012345"
PKCE_TEST_CODE = "TESTCODE"
GOOGLE_TEST_EMAIL = "google-user@gmail.com"


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "+00:00")


class State:
    def __init__(self):
        self.lock = threading.Lock()
        self.users = {}      # id -> {"id", "email"}
        self.email_to_id = {}  # email -> id
        self.otps = {}       # email -> code
        self.profiles = {}   # id -> row dict
        self.invites = []    # list of row dicts
        self.queue = {}      # v11: id -> matchmaking_queue row
        self.matches = []    # v11: list of matches rows
        self.presence = {}   # v11: id -> presence row
        self.broadcast_log = []  # v11: [{channel, msg}] fake Broadcast store
        self.ws_clients = set()  # sockets
        self.otp_redirect_fail = False  # test seam: reject OTP requests
        # that carry redirect_to (a fresh Supabase project with no
        # Redirect URLs allow-listed) — the client must retry code-only.
        self.last_post = None  # test seam: the last POST seen
        # {"method", "path", "headers", "body"} — read back via
        # GET /__test__/last_post so tests can assert the exact
        # request the client sent (URL, body, Prefer header).
        self.rpc_counts = {}  # round 4: RPC path -> call count
        # (single-flight test reads it via GET /__test__/rpc_counts).

    def new_user(self, email=None):
        uid = str(uuid.uuid4())
        self.users[uid] = {"id": uid, "email": email}
        if email:
            self.email_to_id[email] = uid
        return uid

    def session(self, uid):
        user = self.users[uid]
        return {
            "access_token": "tok-" + uid,
            "token_type": "bearer",
            "expires_in": 3600,
            "refresh_token": "ref-" + uid,
            "user": {"id": uid, "email": user["email"]},
        }


STATE = State()


# ------------------------------------------------------------------ WS out

def ws_send_text(sock, text: str) -> None:
    payload = text.encode("utf-8")
    header = bytearray([0x81])
    n = len(payload)
    if n < 126:
        header.append(n)
    elif n < 65536:
        header.append(126)
        header += struct.pack(">H", n)
    else:
        header.append(127)
        header += struct.pack(">Q", n)
    try:
        sock.sendall(bytes(header) + payload)
    except OSError:
        pass


def broadcast_invite(row, event_type: str) -> None:
    msg = json.dumps({
        "topic": "realtime:public:invites",
        "event": "postgres_changes",
        "payload": {"data": {"record": row, "old_record": {}}, "type": event_type},
        "ref": None,
    })
    with STATE.lock:
        clients = list(STATE.ws_clients)
    for sock in clients:
        ws_send_text(sock, msg)


def broadcast_signal(channel, msg):
    """Fake Broadcast: store + re-emit a signal to every WS client."""
    with STATE.lock:
        STATE.broadcast_log.append({"channel": channel, "msg": msg})
        clients = list(STATE.ws_clients)
    wire = json.dumps({
        "topic": "realtime:%s" % channel,
        "event": "broadcast",
        "payload": {"event": "signal", "payload": msg},
        "ref": None,
    })
    for sock in clients:
        ws_send_text(sock, wire)


def find_match_impl(mode, widen):
    """Mirror of schema-p2p.sql find_match (mock): pair the caller
    (the single queue row that called first is 'me' — the mock has no
    auth, so the caller is identified by the most recent queue row
    when only one caller exists; the tests call it per-player via the
    queue rows directly). Returns the RPC dict."""
    with STATE.lock:
        rows = sorted(STATE.queue.values(), key=lambda r: r["created_at"])
    if not rows:
        return {"matched": False, "error": "You are not in the queue."}
    me = rows[0]
    window = 4 if widen else 2
    need = 3 if mode == "4p" else 1
    others = [r for r in rows[1:]
              if r["mode"] == mode and r["table"] == me["table"]
              and abs(r["level"] - me["level"]) <= window]
    if len(others) < need:
        return {"matched": False}
    group = [me] + others[:need]
    for r in group:
        prof = STATE.profiles.get(r["id"], {})
        if r["stake"] < 0 or r["stake"] > prof.get("coins", 0):
            with STATE.lock:
                STATE.queue.pop(r["id"], None)
            return {"matched": False, "error": "A player staked more coins than they own."}
    players = [{"id": r["id"], "name": r["display_name"], "level": r["level"],
                "stake": r["stake"], "seat": i} for i, r in enumerate(group)]
    match_id = str(uuid.uuid4())
    with STATE.lock:
        STATE.matches.append({
            "id": match_id, "group_id": None, "mode": mode,
            "table": me["table"],
            "player_ids": [r["id"] for r in group],
            "players": players, "status": "waiting",
            "created_at": now_iso()})
        for r in group:
            STATE.queue.pop(r["id"], None)
    return {"matched": True, "match_id": match_id, "players": players}


def create_match_from_invites_impl(group_id):
    with STATE.lock:
        existing = [m for m in STATE.matches if m.get("group_id") == group_id]
        if existing:
            m = existing[0]
            return {"ok": True, "match_id": m["id"], "players": m["players"]}
        inv_rows = sorted([r for r in STATE.invites if r["group_id"] == group_id],
                          key=lambda r: r["created_at"])
    if not inv_rows:
        return {"ok": False, "error": "No invites in this group."}
    if any(r["status"] != "accepted" for r in inv_rows):
        return {"ok": False, "error": "Not everyone has accepted yet."}
    inviter_id = inv_rows[0]["from_id"]
    inviter_name = inv_rows[0]["from_name"]
    inviter_stake = inv_rows[0]["stake"]
    prof = STATE.profiles.get(inviter_id, {})
    inviter_level = int(prof.get("xp", 0)) // 500 + 1
    if inviter_stake < 0 or inviter_stake > prof.get("coins", 0):
        return {"ok": False, "error": "The inviter staked more coins than they own."}
    players = [{"id": inviter_id, "name": inviter_name, "level": inviter_level,
                "stake": inviter_stake, "seat": 0}]
    ids = [inviter_id]
    for i, inv in enumerate(inv_rows):
        p = STATE.profiles.get(inv["to_id"], {})
        if inv["stake"] < 0 or inv["stake"] > p.get("coins", 0):
            return {"ok": False, "error": "A player staked more coins than they own."}
        players.append({"id": inv["to_id"], "name": inv["to_name"],
                        "level": int(p.get("xp", 0)) // 500 + 1,
                        "stake": inv["stake"], "seat": i + 1})
        ids.append(inv["to_id"])
    match_id = str(uuid.uuid4())
    # Round 4: model the live function's multi-query validation window.
    # The live RPC runs several SELECTs between its existing-match
    # check and its INSERT, so two concurrent calls both pass the
    # check and both insert. Without this sleep the mock's append is
    # instant and the race almost never reproduces; with it, an
    # unfixed client double-fire deterministically makes 2 matches.
    time.sleep(0.05)
    with STATE.lock:
        STATE.matches.append({
            "id": match_id, "group_id": group_id, "mode": inv_rows[0]["mode"],
            "table": 0, "player_ids": ids, "players": players,
            "status": "waiting", "created_at": now_iso()})
    return {"ok": True, "match_id": match_id, "players": players}


def ws_recv_frame(rfile):
    """Read one client frame. Returns (opcode, payload bytes) or (None, b'')."""
    head = rfile.read(2)
    if len(head) < 2:
        return None, b""
    b0, b1 = head[0], head[1]
    opcode = b0 & 0x0F
    masked = bool(b1 & 0x80)
    length = b1 & 0x7F
    if length == 126:
        length = struct.unpack(">H", rfile.read(2))[0]
    elif length == 127:
        length = struct.unpack(">Q", rfile.read(8))[0]
    mask = rfile.read(4) if masked else b"\x00\x00\x00\x00"
    payload = rfile.read(length) if length > 0 else b""
    if masked:
        payload = bytes(c ^ mask[i % 4] for i, c in enumerate(payload))
    return opcode, payload


# ------------------------------------------------------------------ handler

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass

    # -- helpers ------------------------------------------------------
    def _json(self, status, obj):
        body = json.dumps(obj).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _read_body(self):
        n = int(self.headers.get("Content-Length", "0") or 0)
        raw = self.rfile.read(n) if n > 0 else b""
        if not raw:
            return {}
        try:
            return json.loads(raw.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            return {}

    def _eq(self, query, key):
        vals = query.get(key, [])
        if not vals:
            return None
        v = vals[0]
        return v[3:] if v.startswith("eq.") else v

    # -- routing ------------------------------------------------------
    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path
        if path == "/health":
            self._json(200, {"ok": True})
            return
        if path == "/__test__/last_post":
            with STATE.lock:
                last = STATE.last_post
            self._json(200, last if last is not None else {})
            return
        if path == "/__test__/rpc_counts":
            # Round 4: how many times each RPC path was called —
            # the single-flight test asserts create_match_from_invites
            # ran exactly once for a group despite a double tick.
            with STATE.lock:
                counts = dict(STATE.rpc_counts)
            self._json(200, counts)
            return
        if path == "/realtime/v1/websocket":
            self._ws_upgrade()
            return
        if path == "/rest/v1/profiles":
            query = parse_qs(parsed.query)
            rows = list(STATE.profiles.values())
            pid = self._eq(query, "id")
            gmail = self._eq(query, "gmail")
            if pid is not None:
                rows = [r for r in rows if r["id"] == pid]
            if gmail is not None:
                rows = [r for r in rows if r.get("gmail") == gmail]
            self._json(200, rows)
            return
        if path == "/rest/v1/matchmaking_queue":
            query = parse_qs(parsed.query)
            rows = list(STATE.queue.values())
            qid = self._eq(query, "id")
            if qid is not None:
                rows = [r for r in rows if r["id"] == qid]
            self._json(200, rows)
            return
        if path == "/rest/v1/matches":
            query = parse_qs(parsed.query)
            rows = list(STATE.matches)
            # player_ids=cs.{uuid} — array-contains (the v11 poll).
            raw_q = parsed.query
            if "player_ids=cs.{" in raw_q:
                want = raw_q.split("player_ids=cs.{", 1)[1].split("}", 1)[0]
                rows = [r for r in rows if want in r.get("player_ids", [])]
            match_id = self._eq(query, "id")
            group_id = self._eq(query, "group_id")
            status = self._eq(query, "status")
            if match_id is not None:
                rows = [r for r in rows if r.get("id") == match_id]
            if group_id is not None:
                rows = [r for r in rows if r.get("group_id") == group_id]
            if status is not None:
                # v11 match-fix: polls use status=in.(waiting,ready,playing)
                if status.startswith("in.(") and status.endswith(")"):
                    wanted = set(s.strip() for s in status[4:-1].split(","))
                    rows = [r for r in rows if r.get("status") in wanted]
                else:
                    rows = [r for r in rows if r.get("status") == status]
            self._json(200, rows)
            return
        if path == "/rest/v1/presence":
            rows = sorted(STATE.presence.values(),
                          key=lambda r: r.get("updated_at", ""), reverse=True)
            self._json(200, rows)
            return
        if path.startswith("/broadcast/"):
            channel = path[len("/broadcast/"):]
            with STATE.lock:
                msgs = [b["msg"] for b in STATE.broadcast_log if b["channel"] == channel]
            self._json(200, msgs)
            return
        if path == "/rest/v1/invites":
            query = parse_qs(parsed.query)
            rows = list(STATE.invites)
            to_id = self._eq(query, "to_id")
            group_id = self._eq(query, "group_id")
            status = self._eq(query, "status")
            if to_id is not None:
                rows = [r for r in rows if r["to_id"] == to_id]
            if group_id is not None:
                rows = [r for r in rows if r["group_id"] == group_id]
            if status is not None:
                # v11: list_outgoing_invites uses status=in.(pending,accepted)
                if status.startswith("in.(") and status.endswith(")"):
                    wanted = set(s.strip() for s in status[4:-1].split(","))
                    rows = [r for r in rows if r.get("status") in wanted]
                else:
                    rows = [r for r in rows if r.get("status") == status]
            rows.sort(key=lambda r: r["created_at"], reverse="desc")
            self._json(200, rows)
            return
        self._json(404, {"msg": "not found"})

    def do_POST(self):
        parsed = urlparse(self.path)
        path = parsed.path
        body = self._read_body()
        with STATE.lock:
            STATE.last_post = {"method": "POST", "path": self.path,
                               "headers": dict(self.headers), "body": body}
        if path == "/auth/v1/signup":
            uid = STATE.new_user()
            self._json(200, STATE.session(uid))
            return
        if path == "/__test__/otp_redirect_fail":
            # Test seam (auth fix, 2026-11-27): toggle the fresh-project
            # behaviour — OTP requests WITH a redirect_to are rejected.
            STATE.otp_redirect_fail = bool(body.get("enabled", False))
            self._json(200, {"ok": True, "enabled": STATE.otp_redirect_fail})
            return
        if path == "/auth/v1/otp":
            email = str(body.get("email", "")).strip().lower()
            if STATE.otp_redirect_fail and "redirect_to" in parsed.query:
                # Fresh project: the Redirect URL is not allow-listed,
                # so GoTrue rejects the redirect variant with 400.
                self._json(400, {"msg": "redirect_to is not allowed"})
                return
            STATE.otps[email] = OTP_CODE
            self._json(200, {})
            return
        if path == "/auth/v1/verify":
            email = str(body.get("email", "")).strip().lower()
            token = str(body.get("token", ""))
            # The leading-zero code is accepted only for an email that
            # was actually sent one (same gate as the normal code).
            sent = STATE.otps.get(email)
            if token != sent and not (sent is not None and token == OTP_CODE_LEADING_ZERO):
                self._json(400, {"msg": "Invalid code — check your Gmail and try again."})
                return
            uid = STATE.email_to_id.get(email)
            if uid is None:
                uid = STATE.new_user(email)
            self._json(200, STATE.session(uid))
            return
        if path == "/auth/v1/token":
            qs = parse_qs(parsed.query)
            grant = qs.get("grant_type", [""])[0]
            if grant == "refresh_token":
                # v11 session restore: "ref-<uid>" (or the rotated
                # "ref-refreshed-<uid>") -> a ROTATED session for the
                # same user (new tokens, same id). Unknown tokens fail.
                token = str(body.get("refresh_token", ""))
                uid = None
                for prefix in ("ref-refreshed-", "ref-"):
                    if token.startswith(prefix):
                        uid = token[len(prefix):]
                        break
                if uid is None or uid not in STATE.users:
                    self._json(400, {"error_description": "Invalid refresh token."})
                    return
                sess = STATE.session(uid)
                sess["access_token"] = "tok-refreshed-" + uid
                sess["refresh_token"] = "ref-refreshed-" + uid
                self._json(200, sess)
                return
            if body.get("auth_code") == PKCE_TEST_CODE:
                uid = STATE.email_to_id.get(GOOGLE_TEST_EMAIL)
                if uid is None:
                    uid = STATE.new_user(GOOGLE_TEST_EMAIL)
                self._json(200, STATE.session(uid))
                return
            self._json(400, {"error_description": "Invalid auth code."})
            return
        if path == "/rest/v1/profiles":
            row = dict(body)
            row.setdefault("id", str(uuid.uuid4()))
            row["updated_at"] = now_iso()
            row.setdefault("created_at", now_iso())
            with STATE.lock:
                STATE.profiles[row["id"]] = row
            self._json(201, [row])
            return
        if path == "/rest/v1/rpc/search_players":
            q = str(body.get("q", "")).lower()
            exclude = str(body.get("exclude_id", ""))
            out = []
            for row in STATE.profiles.values():
                if row["id"] == exclude:
                    continue
                if q and q not in str(row.get("display_name", "")).lower():
                    continue
                out.append({"id": row["id"], "display_name": row.get("display_name", ""),
                            "level": int(row.get("xp", 0)) // 500 + 1})
            out.sort(key=lambda r: r["display_name"])
            self._json(200, out[:20])
            return
        if path == "/rest/v1/matchmaking_queue":
            row = dict(body)
            row.setdefault("created_at", now_iso())
            with STATE.lock:
                STATE.queue[row["id"]] = row
            self._json(201, [row])
            return
        if path == "/rest/v1/presence":
            row = dict(body)
            row["updated_at"] = now_iso()
            with STATE.lock:
                STATE.presence[row["id"]] = row
            self._json(201, [row])
            return
        if path == "/rest/v1/rpc/find_match":
            # The mock has no auth: the caller is the oldest queue row
            # (tests queue one player, then the other, then call).
            with STATE.lock:
                STATE.rpc_counts["find_match"] = STATE.rpc_counts.get("find_match", 0) + 1
            self._json(200, find_match_impl(str(body.get("p_mode", "2p")),
                                            bool(body.get("p_widen", False))))
            return
        if path == "/rest/v1/rpc/create_match_from_invites":
            with STATE.lock:
                STATE.rpc_counts["create_match_from_invites"] = STATE.rpc_counts.get("create_match_from_invites", 0) + 1
            self._json(200, create_match_from_invites_impl(str(body.get("p_group_id", ""))))
            return
        if path == "/rest/v1/invites":
            row = dict(body)
            row["id"] = str(uuid.uuid4())
            row.setdefault("status", "pending")
            row["created_at"] = now_iso()
            row["updated_at"] = now_iso()
            with STATE.lock:
                STATE.invites.append(row)
            broadcast_invite(row, "INSERT")
            self._json(201, [row])
            return
        self._json(404, {"msg": "not found"})

    def do_DELETE(self):
        parsed = urlparse(self.path)
        query = parse_qs(parsed.query)
        if parsed.path == "/rest/v1/matchmaking_queue":
            qid = self._eq(query, "id")
            with STATE.lock:
                STATE.queue.pop(qid, None)
            self._json(200, [])
            return
        if parsed.path == "/rest/v1/presence":
            qid = self._eq(query, "id")
            with STATE.lock:
                STATE.presence.pop(qid, None)
            self._json(200, [])
            return
        self._json(404, {"msg": "not found"})

    def do_PATCH(self):
        parsed = urlparse(self.path)
        if parsed.path == "/rest/v1/matches":
            query = parse_qs(parsed.query)
            match_id = self._eq(query, "id")
            body = self._read_body()
            with STATE.lock:
                for row in STATE.matches:
                    if row["id"] == match_id:
                        row.update(body)
                        updated = dict(row)
                        break
                else:
                    self._json(404, {"msg": "match not found"})
                    return
            self._json(200, [updated])
            return
        if parsed.path == "/rest/v1/invites":
            query = parse_qs(parsed.query)
            invite_id = self._eq(query, "id")
            body = self._read_body()
            with STATE.lock:
                for row in STATE.invites:
                    if row["id"] == invite_id:
                        row.update(body)
                        row["updated_at"] = now_iso()
                        updated = dict(row)
                        break
                else:
                    self._json(404, {"msg": "invite not found"})
                    return
            broadcast_invite(updated, "UPDATE")
            self._json(200, [updated])
            return
        self._json(404, {"msg": "not found"})

    # -- realtime websocket -------------------------------------------
    def _ws_upgrade(self):
        key = self.headers.get("Sec-WebSocket-Key", "")
        accept = base64.b64encode(
            hashlib.sha1((key + WS_GUID).encode("ascii")).digest()).decode("ascii")
        self.send_response(101, "Switching Protocols")
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", accept)
        self.end_headers()
        sock = self.connection
        with STATE.lock:
            STATE.ws_clients.add(sock)
        try:
            while True:
                opcode, payload = ws_recv_frame(self.rfile)
                if opcode is None:
                    break
                if opcode == 0x8:  # close
                    break
                if opcode == 0x9:  # ping -> pong
                    try:
                        sock.sendall(bytes([0x8A, len(payload)]) + payload)
                    except OSError:
                        break
                    continue
                if opcode != 0x1:  # text only
                    continue
                try:
                    msg = json.loads(payload.decode("utf-8"))
                except (ValueError, UnicodeDecodeError):
                    continue
                event = msg.get("event", "")
                ref = msg.get("ref")
                if event == "broadcast":
                    topic = str(msg.get("topic", ""))
                    if topic.startswith("realtime:carrom-match-"):
                        channel = topic[len("realtime:"):]
                        payload = msg.get("payload", {})
                        if str(payload.get("event", "")) == "signal":
                            broadcast_signal(channel, payload.get("payload", {}))
                    continue
                if event == "phx_join":
                    ws_send_text(sock, json.dumps({
                        "topic": msg.get("topic", ""), "event": "phx_reply",
                        "payload": {"status": "ok", "response": {}}, "ref": ref}))
                elif event == "heartbeat":
                    ws_send_text(sock, json.dumps({
                        "topic": "phoenix", "event": "phx_reply",
                        "payload": {"status": "ok", "response": {}}, "ref": ref}))
        finally:
            with STATE.lock:
                STATE.ws_clients.discard(sock)
            try:
                sock.close()
            except OSError:
                pass


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=18080)
    args = ap.parse_args()
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    print("MOCK_SUPABASE_READY %d" % args.port, flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
