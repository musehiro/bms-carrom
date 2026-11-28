#!/usr/bin/env python3
"""Verification driver for the scale-SQL round (worker 5, 2026-11-28).

Spawns tests/mock_supabase.py on port 18084 (NOT the default 18080),
proves the mock now mirrors the FIXED SQL semantics, and kills the
mock when done.

  (a) concurrent find_match: 600 simultaneous searchers (one
      find_match call each, barrier-released) must produce ZERO
      duplicate matches, ZERO double-booked players, and a drained
      queue (600 players -> 300 matches).
  (b) cleanup_stale_matchmaking: stale queue rows are deleted, stale
      'waiting' matches and stale 'pending' invites expire, with the
      exact counts; fresh rows, 'playing' matches and 'accepted'
      invites are untouched; a second call returns all zeros.
  (c) invite-after-expiry: create_match_from_invites returns a FRESH
      match after the old one expired (and stays idempotent).
  (+) invite burst: 20 groups x 4 concurrent calls -> exactly 1
      match per group, all calls returning the same match id.

Stale rows are produced with client-supplied created_at (the mock's
POST setdefault honours it) and the /__test__/set_created_at seam
(matches are created by the RPCs with a fresh timestamp, so they must
be backdated through the seam).

Run: python3 tests/scale_sql_verify.py [--players 600]
Prints a JSON summary block at the end. Exits non-zero on any failure.
"""

import argparse
import http.client
import json
import subprocess
import sys
import threading
import time
import uuid
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone

HERE = __file__.rsplit("/", 1)[0]
MOCK = HERE + "/mock_supabase.py"
PORT = 18084
BASE = ("127.0.0.1", PORT)
FAILURES = []


def check(name, cond, detail=""):
    print(("PASS " if cond else "FAIL ") + name + ((" — " + str(detail)) if detail else ""), flush=True)
    if not cond:
        FAILURES.append(name)


class Conn:
    """One fresh HTTP/1.1 connection per use (threads must not share)."""

    def call(self, method, path, body=None):
        c = http.client.HTTPConnection(BASE[0], BASE[1], timeout=30)
        try:
            c.request(method, path,
                      body=json.dumps(body) if body is not None else None,
                      headers={"Content-Type": "application/json"})
            r = c.getresponse()
            raw = r.read()
            try:
                data = json.loads(raw.decode("utf-8")) if raw else None
            except ValueError:
                data = None
            return r.status, data
        finally:
            c.close()


def iso_ago(**kw):
    return (datetime.now(timezone.utc) - timedelta(**kw)).isoformat()


def start_mock():
    proc = subprocess.Popen(
        [sys.executable, MOCK, "--port", str(PORT)],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    deadline = time.time() + 15
    while time.time() < deadline:
        try:
            st, _ = Conn().call("GET", "/health")
            if st == 200:
                return proc
        except Exception:  # noqa: BLE001 - not up yet
            time.sleep(0.2)
    proc.kill()
    raise RuntimeError("mock did not come up on port %d" % PORT)


def stop_mock(proc):
    proc.terminate()
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait(timeout=5)


def fetch_matches():
    _, data = Conn().call("GET", "/rest/v1/matches?select=*")
    return data or []


def fetch_queue():
    _, data = Conn().call("GET", "/rest/v1/matchmaking_queue?select=*")
    return data or []


def fetch_invites():
    _, data = Conn().call("GET", "/rest/v1/invites?select=*")
    return data or []


def seed_player(pid, level=5, created_at=None):
    conn = Conn()
    conn.call("POST", "/rest/v1/profiles",
              {"id": pid, "display_name": "V-%s" % pid[:8],
               "coins": 100000, "xp": 2000})
    row = {"id": pid, "user_id": pid, "display_name": "V-%s" % pid[:8],
           "level": level, "table": 0, "stake": 100, "mode": "2p"}
    if created_at:
        row["created_at"] = created_at
    conn.call("POST", "/rest/v1/matchmaking_queue", row)


def make_group(accepted=True):
    """One 2p invite group with both sides accepted (or pending)."""
    inviter, invitee = str(uuid.uuid4()), str(uuid.uuid4())
    gid = str(uuid.uuid4())
    conn = Conn()
    for pid in (inviter, invitee):
        conn.call("POST", "/rest/v1/profiles",
                  {"id": pid, "display_name": "G-%s" % pid[:8],
                   "coins": 100000, "xp": 2000})
    st, data = conn.call("POST", "/rest/v1/invites",
                         {"group_id": gid, "from_id": inviter, "to_id": invitee,
                          "from_name": "Inviter", "to_name": "Invitee",
                          "mode": "2p", "stake": 0,
                          "status": "accepted" if accepted else "pending"})
    return gid, (data[0]["id"] if isinstance(data, list) and data else None)


# ------------------------------------------------------------------ (a)

def scenario_concurrent_find_match(n_players):
    print("== (a) concurrent find_match: %d simultaneous searchers ==" % n_players, flush=True)
    ids = [str(uuid.uuid4()) for _ in range(n_players)]
    with ThreadPoolExecutor(max_workers=64) as pool:
        list(pool.map(seed_player, ids))
    check("seed queue size == players", len(fetch_queue()) == n_players,
          len(fetch_queue()))

    barrier = threading.Barrier(n_players)
    answers = []
    lock = threading.Lock()

    def one(_i):
        barrier.wait(timeout=60)
        st, data = Conn().call("POST", "/rest/v1/rpc/find_match",
                               {"p_mode": "2p", "p_widen": False})
        with lock:
            answers.append((st, data if isinstance(data, dict) else {}))

    with ThreadPoolExecutor(max_workers=n_players) as pool:
        list(pool.map(one, range(n_players)))

    matched_true = sum(1 for _, d in answers if d.get("matched") is True)
    http_ok = sum(1 for st, _ in answers if st == 200)
    matches = fetch_matches()
    by_players = {}
    for row in matches:
        by_players.setdefault(tuple(sorted(row.get("player_ids", []))), []).append(row["id"])
    dup_groups = {k: v for k, v in by_players.items() if len(v) > 1}
    seen = {}
    for row in matches:
        for pid in row.get("player_ids", []):
            seen.setdefault(pid, []).append(row["id"])
    double_booked = {p: m for p, m in seen.items() if len(m) > 1}
    wrong_size = [r for r in matches if len(r.get("player_ids", [])) != 2]
    return {
        "searchers": n_players,
        "http_200_answers": http_ok,
        "matched_true_answers": matched_true,
        "matches_created": len(matches),
        "expected_matches": n_players // 2,
        "duplicate_player_sets": len(dup_groups),
        "duplicate_match_rows": sum(len(v) - 1 for v in dup_groups.values()),
        "players_double_booked": len(double_booked),
        "matches_wrong_size": len(wrong_size),
        "final_queue_size": len(fetch_queue()),
    }


# ------------------------------------------------------- (+) invite burst

def scenario_invite_burst(n_groups=20, calls_per_group=4):
    print("== (+) invite burst: %d groups x %d concurrent calls ==" % (n_groups, calls_per_group), flush=True)
    with ThreadPoolExecutor(max_workers=32) as pool:
        groups = list(pool.map(lambda _i: make_group()[0], range(n_groups)))
    barrier = threading.Barrier(n_groups * calls_per_group)
    results = []
    lock = threading.Lock()

    def one(args):
        gid, _i = args
        barrier.wait(timeout=60)
        st, data = Conn().call("POST", "/rest/v1/rpc/create_match_from_invites",
                               {"p_group_id": gid})
        with lock:
            results.append((gid, st, data if isinstance(data, dict) else {}))

    tasks = [(g, i) for g in groups for i in range(calls_per_group)]
    with ThreadPoolExecutor(max_workers=len(tasks)) as pool:
        list(pool.map(one, tasks))
    per_group = {}
    for gid, st, data in results:
        per_group.setdefault(gid, []).append((st, data))
    dup = sum(1 for gid in groups
              if len({d.get("match_id") for _, d in per_group[gid] if d.get("ok")}) > 1)
    no_match = sum(1 for gid in groups
                   if not any(d.get("ok") and d.get("match_id") for _, d in per_group[gid]))
    all_matches = fetch_matches()
    rows_per_group = {g: sum(1 for r in all_matches if r.get("group_id") == g)
                      for g in groups}
    return {
        "groups": n_groups,
        "calls_per_group": calls_per_group,
        "groups_with_more_than_one_match_id": dup,
        "groups_with_no_match": no_match,
        "max_rows_for_one_group": max(rows_per_group.values()),
        "total_rows_for_burst_groups": sum(rows_per_group.values()),
    }


# ------------------------------------------------------------------ (b)

def scenario_cleanup():
    print("== (b) cleanup_stale_matchmaking ==", flush=True)
    conn = Conn()
    # Stale queue rows (11 min old) + fresh ones.
    stale_q = [str(uuid.uuid4()) for _ in range(3)]
    fresh_q = [str(uuid.uuid4()) for _ in range(2)]
    with ThreadPoolExecutor(max_workers=8) as pool:
        list(pool.map(lambda pid: seed_player(pid, created_at=iso_ago(minutes=11)), stale_q))
        list(pool.map(seed_player, fresh_q))
    # Matches: 2 fresh waiting via the invite RPC; backdate 1 to 11 min.
    g1, _ = make_group()
    _, d1 = conn.call("POST", "/rest/v1/rpc/create_match_from_invites", {"p_group_id": g1})
    m_wait_stale = d1["match_id"]
    g2, _ = make_group()
    _, d2 = conn.call("POST", "/rest/v1/rpc/create_match_from_invites", {"p_group_id": g2})
    m_wait_fresh = d2["match_id"]
    # A 'playing' match, also 11 min old — must NOT expire.
    g3, _ = make_group()
    _, d3 = conn.call("POST", "/rest/v1/rpc/create_match_from_invites", {"p_group_id": g3})
    m_playing = d3["match_id"]
    conn.call("PATCH", "/rest/v1/matches?id=eq.%s" % m_playing, {"status": "playing"})
    conn.call("POST", "/__test__/set_created_at",
              {"table": "matches", "id": m_wait_stale, "created_at": iso_ago(minutes=11)})
    conn.call("POST", "/__test__/set_created_at",
              {"table": "matches", "id": m_playing, "created_at": iso_ago(minutes=11)})
    # Invites: 2 pending stale (25 h), 1 pending fresh, 1 accepted stale.
    stale_inv_ids = []
    for _ in range(2):
        _, inv_id = make_group(accepted=False)
        conn.call("POST", "/__test__/set_created_at",
                  {"table": "invites", "id": inv_id, "created_at": iso_ago(hours=25)})
        stale_inv_ids.append(inv_id)
    _, fresh_inv_id = make_group(accepted=False)
    _, accepted_inv_id = make_group(accepted=True)
    conn.call("POST", "/__test__/set_created_at",
              {"table": "invites", "id": accepted_inv_id, "created_at": iso_ago(hours=25)})

    st, res = conn.call("POST", "/rest/v1/rpc/cleanup_stale_matchmaking", {})
    by_id = {m["id"]: m for m in fetch_matches()}
    queue_ids = {r["id"] for r in fetch_queue()}
    inv_by_id = {r["id"]: r for r in fetch_invites()}
    # Second call must be a no-op (idempotent).
    _, res2 = conn.call("POST", "/rest/v1/rpc/cleanup_stale_matchmaking", {})
    return {
        "cleanup_http_status": st,
        "cleanup_result": res,
        "cleanup_second_call": res2,
        "stale_queue_rows_deleted": all(pid not in queue_ids for pid in stale_q),
        "fresh_queue_rows_kept": all(pid in queue_ids for pid in fresh_q),
        "stale_waiting_match_expired": by_id.get(m_wait_stale, {}).get("status") == "expired",
        "fresh_waiting_match_kept": by_id.get(m_wait_fresh, {}).get("status") == "waiting",
        "old_playing_match_kept": by_id.get(m_playing, {}).get("status") == "playing",
        "stale_pending_invites_expired": all(
            inv_by_id.get(i, {}).get("status") == "expired" for i in stale_inv_ids),
        "fresh_pending_invite_kept": inv_by_id.get(fresh_inv_id, {}).get("status") == "pending",
        "old_accepted_invite_kept": inv_by_id.get(accepted_inv_id, {}).get("status") == "accepted",
        "stale_match_row_still_exists": m_wait_stale in by_id,
    }


# ------------------------------------------------------------------ (c)

def scenario_invite_after_expiry():
    print("== (c) invite RPC after the old match expired ==", flush=True)
    conn = Conn()
    gid, _ = make_group()
    _, d1 = conn.call("POST", "/rest/v1/rpc/create_match_from_invites", {"p_group_id": gid})
    m1 = d1.get("match_id")
    conn.call("POST", "/__test__/set_created_at",
              {"table": "matches", "id": m1, "created_at": iso_ago(minutes=11)})
    _, clean = conn.call("POST", "/rest/v1/rpc/cleanup_stale_matchmaking", {})
    _, d2 = conn.call("POST", "/rest/v1/rpc/create_match_from_invites", {"p_group_id": gid})
    m2 = d2.get("match_id")
    _, d3 = conn.call("POST", "/rest/v1/rpc/create_match_from_invites", {"p_group_id": gid})
    rows = [r for r in fetch_matches() if r.get("group_id") == gid]
    by_id = {r["id"]: r for r in rows}
    return {
        "first_match_id": m1,
        "cleanup_expired_matches": (clean or {}).get("expired_matches"),
        "second_match_id": m2,
        "second_call_ok": bool(d2.get("ok")),
        "fresh_match_differs_from_expired": bool(m1 and m2 and m1 != m2),
        "third_call_same_match_id": d3.get("match_id") == m2,
        "rows_for_group": len(rows),
        "old_match_status": by_id.get(m1, {}).get("status"),
        "new_match_status": by_id.get(m2, {}).get("status"),
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--players", type=int, default=600)
    args = ap.parse_args()
    proc = start_mock()
    results = {}
    try:
        results["concurrent_find_match"] = scenario_concurrent_find_match(args.players)
        r = results["concurrent_find_match"]
        check("(a) all answers HTTP 200", r["http_200_answers"] == args.players, r["http_200_answers"])
        check("(a) matches created == players/2", r["matches_created"] == args.players // 2, r["matches_created"])
        check("(a) ZERO duplicate matches", r["duplicate_match_rows"] == 0, r["duplicate_match_rows"])
        check("(a) ZERO double-booked players", r["players_double_booked"] == 0, r["players_double_booked"])
        check("(a) all matches size 2", r["matches_wrong_size"] == 0, r["matches_wrong_size"])
        check("(a) queue drained", r["final_queue_size"] == 0, r["final_queue_size"])

        results["invite_burst"] = scenario_invite_burst()
        r = results["invite_burst"]
        check("(+) exactly 1 match row per group", r["max_rows_for_one_group"] == 1 and r["total_rows_for_burst_groups"] == 20, r)
        check("(+) no group with >1 match id", r["groups_with_more_than_one_match_id"] == 0, r)
        check("(+) no group without a match", r["groups_with_no_match"] == 0, r)

        results["cleanup"] = scenario_cleanup()
        r = results["cleanup"]
        check("(b) cleanup HTTP 200 + ok", r["cleanup_http_status"] == 200 and (r["cleanup_result"] or {}).get("ok") is True, r["cleanup_result"])
        check("(b) counts exact {expired_matches 1, deleted_queue 3, expired_invites 2}",
              (r["cleanup_result"] or {}) == {"ok": True, "expired_matches": 1,
                                              "deleted_queue_rows": 3, "expired_invites": 2},
              r["cleanup_result"])
        check("(b) stale queue rows deleted", r["stale_queue_rows_deleted"])
        check("(b) fresh queue rows kept", r["fresh_queue_rows_kept"])
        check("(b) stale waiting match expired", r["stale_waiting_match_expired"])
        check("(b) fresh waiting match kept", r["fresh_waiting_match_kept"])
        check("(b) old playing match kept", r["old_playing_match_kept"])
        check("(b) stale pending invites expired", r["stale_pending_invites_expired"])
        check("(b) fresh pending invite kept", r["fresh_pending_invite_kept"])
        check("(b) old accepted invite kept", r["old_accepted_invite_kept"])
        check("(b) expired match row NOT deleted", r["stale_match_row_still_exists"])
        check("(b) second cleanup call all zeros",
              r["cleanup_second_call"] == {"ok": True, "expired_matches": 0,
                                           "deleted_queue_rows": 0, "expired_invites": 0},
              r["cleanup_second_call"])

        results["invite_after_expiry"] = scenario_invite_after_expiry()
        r = results["invite_after_expiry"]
        check("(c) first call ok", bool(r["first_match_id"]), r["first_match_id"])
        check("(c) cleanup expired exactly that match", r["cleanup_expired_matches"] == 1, r["cleanup_expired_matches"])
        check("(c) second call ok with a FRESH match", r["second_call_ok"] and r["fresh_match_differs_from_expired"], r)
        check("(c) third call idempotent (same fresh id)", r["third_call_same_match_id"])
        check("(c) group has exactly 2 rows (expired + fresh)", r["rows_for_group"] == 2, r["rows_for_group"])
        check("(c) old match stays expired", r["old_match_status"] == "expired", r["old_match_status"])
        check("(c) new match waiting", r["new_match_status"] == "waiting", r["new_match_status"])
    finally:
        stop_mock(proc)
    print(json.dumps(results, indent=2), flush=True)
    if FAILURES:
        print("FAILURES: %d — %s" % (len(FAILURES), FAILURES), flush=True)
        sys.exit(1)
    print("ALL CHECKS PASSED", flush=True)


if __name__ == "__main__":
    main()
