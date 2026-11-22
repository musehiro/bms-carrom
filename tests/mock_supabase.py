#!/usr/bin/env python3
"""Local mock of the Supabase endpoints BMS Carrom v7 uses, for tests only.

Stdlib only. Implements just enough of GoTrue + PostgREST + Realtime for
the Godot client (scripts/supabase.gd) to run its full flow against it:

  Auth:    POST /auth/v1/signup {}            -> anonymous session
           POST /auth/v1/otp {email}          -> "sends" code 123456
           POST /auth/v1/verify {email, token}-> session (token must be 123456)
           POST /auth/v1/token?grant_type=pkce (auth_code TESTCODE)
                                              -> session for google-user@gmail.com
  REST:    GET/POST /rest/v1/profiles (upsert by id, filter by id/gmail)
           POST /rest/v1/rpc/search_players {q, exclude_id}
           GET/POST/PATCH /rest/v1/invites (filters: to_id/group_id/status)
  Realtime: wss handshake on /realtime/v1/websocket; phx_join on
           realtime:public:invites is answered with phx_reply ok, and
           every invite INSERT/UPDATE is broadcast as postgres_changes.

Run: python3 tests/mock_supabase.py --port 18080
Health: GET /health -> {"ok": true}
"""

import argparse
import base64
import hashlib
import json
import struct
import threading
import uuid
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
OTP_CODE = "123456"
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
        self.ws_clients = set()  # sockets

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
                rows = [r for r in rows if r.get("status") == status]
            rows.sort(key=lambda r: r["created_at"], reverse="desc")
            self._json(200, rows)
            return
        self._json(404, {"msg": "not found"})

    def do_POST(self):
        parsed = urlparse(self.path)
        path = parsed.path
        body = self._read_body()
        if path == "/auth/v1/signup":
            uid = STATE.new_user()
            self._json(200, STATE.session(uid))
            return
        if path == "/auth/v1/otp":
            email = str(body.get("email", "")).strip().lower()
            STATE.otps[email] = OTP_CODE
            self._json(200, {})
            return
        if path == "/auth/v1/verify":
            email = str(body.get("email", "")).strip().lower()
            token = str(body.get("token", ""))
            if STATE.otps.get(email) != token:
                self._json(400, {"msg": "Invalid code — check your Gmail and try again."})
                return
            uid = STATE.email_to_id.get(email)
            if uid is None:
                uid = STATE.new_user(email)
            self._json(200, STATE.session(uid))
            return
        if path == "/auth/v1/token":
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

    def do_PATCH(self):
        parsed = urlparse(self.path)
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
