#!/usr/bin/env python3
"""Scale load driver for BMS Carrom — MOCK measurements only.

Talks to tests/mock_supabase.py over HTTP (started by this driver on
port 18083). Simulates the real client's request pattern (see
scripts/net_client.gd: queue insert once, then find_match every ~2 s
while searching, plus a matches poll for the "other side" of a pairing;
presence heartbeat ~30 s is NOT simulated — it is a separate low-rate
endpoint and the mock's presence table is trivially cheap).

Scenarios:
  1. random_search(N, mode): N players queue for random matches —
     mode '2p' (pairs) or '4p' (doubles: four players, seats 0-3,
     teams 0,2 vs 1,3). Roster validation checks size, seat
     uniqueness, stake preservation, and double-booking.
  2. invite_burst(G, K): G invite groups, K concurrent
     create_match_from_invites calls per group (both phones + a
     double-tick), to test the mock's idempotency under concurrency.

IMPORTANT — mock deviations that shape these numbers (do NOT read
them as live-Supabase behaviour):
  * The mock's find_match_impl identifies the caller as the OLDEST
    queue row (it has no auth), not the actual caller. Pairing is
    still FIFO-oldest-two, so pairing throughput is representative,
    but a caller whose row is already gone can still get
    {"matched": true} for a match it is NOT in — the driver checks
    membership and ignores those answers, as the real client's
    validate_match_row would.
  * The mock's find_match_impl now holds one lock across read+insert
    (worker 5, mirroring the live FOR UPDATE + SKIP LOCKED fix in
    supabase/migrations/2026-11-28-find-match-lock.sql, UNRUN).
    Concurrent calls can no longer pair the same players twice.
  * The mock's create_match_from_invites_impl is now idempotent
    under concurrency (whole check+insert under one lock, live-status
    filter on the existing-match check) — the deliberate 50 ms race
    sleep was removed (worker 5), since live is now protected by the
    atomic guard (pg_advisory_xact_lock + unique index,
    supabase/migrations/2026-11-28-create-match-atomic-guard.sql,
    applied live 2026-11-28 06:03).

Run: python3 tests/scale_load_driver.py [--players 1000] [--invite-groups 50]
Writes: tests/scale_load_results.json (machine-readable summary).
"""

import argparse
import json
import math
import os
import statistics
import subprocess
import sys
import threading
import time
import uuid
from concurrent.futures import ThreadPoolExecutor

import http.client

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
MOCK = os.path.join(HERE, "mock_supabase.py")
PORT = 18083
BASE = ("127.0.0.1", PORT)


# ------------------------------------------------------------------ client

class PlayerConn:
    """One persistent HTTP/1.1 connection per simulated player thread."""

    def __init__(self):
        self.conn = http.client.HTTPConnection(BASE[0], BASE[1], timeout=15)

    def call(self, method, path, body=None):
        payload = json.dumps(body) if body is not None else None
        headers = {"Content-Type": "application/json"}
        t0 = time.monotonic()
        try:
            self.conn.request(method, path, body=payload, headers=headers)
            resp = self.conn.getresponse()
            raw = resp.read()
            dt = time.monotonic() - t0
            try:
                data = json.loads(raw.decode("utf-8")) if raw else None
            except ValueError:
                data = None
            return resp.status, data, dt, None
        except Exception as exc:  # noqa: BLE001 - record and continue
            dt = time.monotonic() - t0
            try:
                self.conn.close()
            except Exception:  # noqa: BLE001
                pass
            self.conn = http.client.HTTPConnection(BASE[0], BASE[1], timeout=15)
            return 0, None, dt, repr(exc)

    def close(self):
        try:
            self.conn.close()
        except Exception:  # noqa: BLE001
            pass


def percentile(values, pct):
    if not values:
        return None
    ordered = sorted(values)
    idx = math.ceil(pct / 100.0 * len(ordered)) - 1
    return ordered[max(0, min(idx, len(ordered) - 1))]


# ------------------------------------------------------------------ mock mgmt

def start_mock():
    proc = subprocess.Popen(
        [sys.executable, MOCK, "--port", str(PORT)],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    deadline = time.time() + 15
    while time.time() < deadline:
        try:
            c = http.client.HTTPConnection(BASE[0], BASE[1], timeout=2)
            c.request("GET", "/health")
            r = c.getresponse()
            r.read()
            c.close()
            if r.status == 200:
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


def fetch_all_matches():
    c = http.client.HTTPConnection(BASE[0], BASE[1], timeout=30)
    c.request("GET", "/rest/v1/matches?select=*")
    r = c.getresponse()
    data = json.loads(r.read().decode("utf-8"))
    c.close()
    return data


def fetch_queue_size():
    c = http.client.HTTPConnection(BASE[0], BASE[1], timeout=30)
    c.request("GET", "/rest/v1/matchmaking_queue?select=*")
    r = c.getresponse()
    data = json.loads(r.read().decode("utf-8"))
    c.close()
    return len(data)


# ------------------------------------------------------- scenario 1: random

def run_random_search(n_players, deadline_s=60.0, poll_interval=2.0, mode="2p", stake=100):
    """N players queue for random matches (mode '2p' or '4p'); each
    ticks find_match + a matches poll every 2 s until matched or the
    deadline. The mock's find_match_impl DOES support 4p (need = 3
    others, same level window) — see its `need` line. Returns metrics."""
    group_size = 4 if mode == "4p" else 2
    ids = [str(uuid.uuid4()) for _ in range(n_players)]
    lat_find, lat_poll = [], []
    errors = {"find_match": 0, "poll": 0, "setup": 0}
    matched = {}  # player id -> match id
    match_seen = {}  # match id -> set of player ids (from answers)
    lock = threading.Lock()
    stop = threading.Event()
    queue_samples = []

    def setup(pid):
        conn = PlayerConn()
        # Profile with plenty of coins (stake 0 anyway) + level 5 xp.
        st, _, _, err = conn.call("POST", "/rest/v1/profiles",
                                  {"id": pid, "display_name": "Load-%s" % pid[:8],
                                   "coins": 100000, "xp": 2000})
        if st not in (200, 201) or err:
            with lock:
                errors["setup"] += 1
        st, _, _, err = conn.call("POST", "/rest/v1/matchmaking_queue",
                                  {"id": pid, "user_id": pid, "display_name": "Load-%s" % pid[:8],
                                   "level": 5, "table": 0, "stake": stake, "mode": mode})
        if st not in (200, 201) or err:
            with lock:
                errors["setup"] += 1
        conn.close()

    t_setup0 = time.monotonic()
    with ThreadPoolExecutor(max_workers=64) as pool:
        list(pool.map(setup, ids))
    setup_s = time.monotonic() - t_setup0

    def sampler():
        while not stop.is_set():
            try:
                queue_samples.append((time.monotonic(), fetch_queue_size()))
            except Exception:  # noqa: BLE001
                pass
            stop.wait(2.0)

    sampler_t = threading.Thread(target=sampler, daemon=True)
    sampler_t.start()

    def player_loop(pid):
        conn = PlayerConn()
        t_end = time.monotonic() + deadline_s
        while time.monotonic() < t_end:
            with lock:
                if pid in matched:
                    break
            st, data, dt, err = conn.call(
                "POST", "/rest/v1/rpc/find_match", {"p_mode": mode, "p_widen": False})
            with lock:
                lat_find.append(dt)
                if st != 200 or err:
                    errors["find_match"] += 1
                elif isinstance(data, dict) and data.get("matched"):
                    players = data.get("players", [])
                    pids = [p.get("id") for p in players]
                    match_seen.setdefault(str(data.get("match_id")), set()).update(pids)
                    if pid in pids:
                        matched[pid] = str(data.get("match_id"))
                        break
            # The "other side" of a pairing learns via the matches poll.
            st, data, dt, err = conn.call(
                "GET", "/rest/v1/matches?select=*&player_ids=cs.{%s}&status=in.(waiting,ready,playing)" % pid)
            with lock:
                lat_poll.append(dt)
                if st != 200 or err:
                    errors["poll"] += 1
                elif isinstance(data, list) and data:
                    matched[pid] = str(data[0].get("id"))
                    for row in data:
                        match_seen.setdefault(str(row.get("id")), set()).update(row.get("player_ids", []))
                    break
            time.sleep(poll_interval)
        conn.close()

    t0 = time.monotonic()
    with ThreadPoolExecutor(max_workers=n_players) as pool:
        list(pool.map(player_loop, ids))
    elapsed = time.monotonic() - t0
    stop.set()
    sampler_t.join(timeout=5)

    # Final state from the server (ground truth, not driver memory).
    all_matches = fetch_all_matches()
    final_queue = fetch_queue_size()
    # Duplicate matches: same sorted player-id set appearing in >1 row.
    by_players = {}
    for row in all_matches:
        key = tuple(sorted(row.get("player_ids", [])))
        by_players.setdefault(key, []).append(row.get("id"))
    dup_groups = {k: v for k, v in by_players.items() if len(v) > 1}
    dup_rows = sum(len(v) - 1 for v in dup_groups.values())
    # 4p/2p roster validation: size, unique seats 0..n-1, stakes as
    # inserted, and no player double-booked into two matches. Teams
    # in 4p are seats 0,2 vs 1,3 (scripts/rules.gd team_of) — the
    # roster check below verifies the seat assignment the teams rest on.
    wrong_size = sum(1 for r in all_matches if len(r.get("player_ids", [])) != group_size)
    bad_seats = 0
    bad_stakes = 0
    for row in all_matches:
        seats = sorted(int(p.get("seat", -1)) for p in row.get("players", []))
        if seats != list(range(group_size)):
            bad_seats += 1
        if any(int(p.get("stake", -1)) != stake for p in row.get("players", [])):
            bad_stakes += 1
    seen_players = {}
    for row in all_matches:
        for pid in row.get("player_ids", []):
            seen_players.setdefault(pid, []).append(row.get("id"))
    double_booked = {p: m for p, m in seen_players.items() if len(m) > 1}
    # Missed pairings: players still queued at the end who had enough
    # pairable partners also still queued (same mode/table, level ±2 —
    # all rows share level 5 / table 0 / mode by construction).
    unmatched = n_players - len(matched)
    missed = final_queue - (final_queue % group_size)
    stuck = [pid for pid in ids if pid not in matched]
    return {
        "scenario": "random_search",
        "mode": mode,
        "group_size": group_size,
        "stake": stake,
        "players": n_players,
        "setup_seconds": round(setup_s, 2),
        "elapsed_seconds": round(elapsed, 2),
        "matched_players": len(matched),
        "unmatched_players": unmatched,
        "matches_created": len(all_matches),
        "duplicate_match_rows": dup_rows,
        "duplicate_player_sets": len(dup_groups),
        "matches_wrong_size": wrong_size,
        "matches_bad_seats": bad_seats,
        "matches_bad_stakes": bad_stakes,
        "players_double_booked": len(double_booked),
        "missed_pairings": missed,
        "stuck_searches": len(stuck),
        "final_queue_size": final_queue,
        "errors": errors,
        "find_match_calls": len(lat_find),
        "find_match_latency_ms": {
            "p50": round(percentile(lat_find, 50) * 1000, 1) if lat_find else None,
            "p95": round(percentile(lat_find, 95) * 1000, 1) if lat_find else None,
            "max": round(max(lat_find) * 1000, 1) if lat_find else None,
        },
        "poll_matches_latency_ms": {
            "p50": round(percentile(lat_poll, 50) * 1000, 1) if lat_poll else None,
            "p95": round(percentile(lat_poll, 95) * 1000, 1) if lat_poll else None,
            "max": round(max(lat_poll) * 1000, 1) if lat_poll else None,
        },
        "queue_size_samples": [(round(t - t0, 1), q) for t, q in queue_samples],
    }


# ------------------------------------------------------- scenario 2: invites

def run_invite_burst(n_groups, concurrent_calls):
    """G 2p invite groups, all invites accepted; then K concurrent
    create_match_from_invites calls per group. Returns metrics."""
    groups = []
    err_count = {"n": 0}
    lat = []
    lock = threading.Lock()

    def setup_group(_i):
        inviter = str(uuid.uuid4())
        invitee = str(uuid.uuid4())
        gid = str(uuid.uuid4())
        conn = PlayerConn()
        for pid in (inviter, invitee):
            conn.call("POST", "/rest/v1/profiles",
                      {"id": pid, "display_name": "Inv-%s" % pid[:8],
                       "coins": 100000, "xp": 2000})
        st, data, _, err = conn.call("POST", "/rest/v1/invites",
                                     {"group_id": gid, "from_id": inviter, "to_id": invitee,
                                      "from_name": "Inviter", "to_name": "Invitee",
                                      "mode": "2p", "stake": 0, "status": "accepted"})
        if st not in (200, 201) or err:
            with lock:
                err_count["n"] += 1
        conn.close()
        return gid

    with ThreadPoolExecutor(max_workers=32) as pool:
        groups = list(pool.map(setup_group, range(n_groups)))

    # Sequential control: one call per group, twice in a row — the
    # idempotent path should return the SAME match id both times.
    seq_conn = PlayerConn()
    seq_same = 0
    seq_second_ok = 0
    for gid in groups:
        _, d1, _, _ = seq_conn.call("POST", "/rest/v1/rpc/create_match_from_invites",
                                    {"p_group_id": gid})
        _, d2, _, _ = seq_conn.call("POST", "/rest/v1/rpc/create_match_from_invites",
                                    {"p_group_id": gid})
        if isinstance(d1, dict) and isinstance(d2, dict):
            if d1.get("match_id") and d1.get("match_id") == d2.get("match_id"):
                seq_same += 1
            if d2.get("ok"):
                seq_second_ok += 1
    seq_conn.close()

    # Fresh groups for the concurrent burst (the sequential ones
    # already have matches, which would mask the race).
    burst_groups = []
    with ThreadPoolExecutor(max_workers=32) as pool:
        burst_groups = list(pool.map(setup_group, range(n_groups)))

    def burst_call(args):
        gid, _i = args
        # All burst threads wait on the barrier so the K calls for a
        # group (and all groups) fire at the same instant — a
        # sequential loop per group would NOT test the race at all.
        start_barrier.wait(timeout=60)
        conn = PlayerConn()
        st, data, dt, err = conn.call(
            "POST", "/rest/v1/rpc/create_match_from_invites", {"p_group_id": gid})
        conn.close()
        with lock:
            lat.append(dt)
            if st != 200 or err:
                err_count["n"] += 1
        return gid, data if isinstance(data, dict) else {}

    # Fire all groups' calls at once: K threads per group, released
    # together by the barrier.
    start_barrier = threading.Barrier(n_groups * concurrent_calls)
    tasks = [(g, i) for g in burst_groups for i in range(concurrent_calls)]
    t0 = time.monotonic()
    with ThreadPoolExecutor(max_workers=n_groups * concurrent_calls) as pool:
        burst_results = list(pool.map(burst_call, tasks))
    burst_s = time.monotonic() - t0

    all_matches = fetch_all_matches()
    per_group = {}
    for row in all_matches:
        per_group.setdefault(row.get("group_id"), []).append(row.get("id"))
    burst_match_counts = {g: len(per_group.get(g, [])) for g in burst_groups}
    dup_groups = sum(1 for c in burst_match_counts.values() if c > 1)
    dup_rows = sum(c - 1 for c in burst_match_counts.values() if c > 1)
    no_match = sum(1 for c in burst_match_counts.values() if c == 0)
    return {
        "scenario": "invite_burst",
        "groups_sequential_control": n_groups,
        "sequential_same_match_id_both_calls": seq_same,
        "sequential_second_call_ok": seq_second_ok,
        "groups_concurrent_burst": n_groups,
        "concurrent_calls_per_group": concurrent_calls,
        "burst_seconds": round(burst_s, 2),
        "groups_with_duplicate_matches": dup_groups,
        "duplicate_match_rows": dup_rows,
        "groups_with_no_match": no_match,
        "total_matches_for_burst_groups": sum(burst_match_counts.values()),
        "errors": err_count["n"],
        "create_match_latency_ms": {
            "p50": round(percentile(lat, 50) * 1000, 1) if lat else None,
            "p95": round(percentile(lat, 95) * 1000, 1) if lat else None,
            "max": round(max(lat) * 1000, 1) if lat else None,
        },
    }


# ------------------------------------------------------------------ main

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--players", type=int, default=1000)
    ap.add_argument("--mode", choices=["2p", "4p", "both"], default="both")
    ap.add_argument("--invite-groups", type=int, default=50)
    ap.add_argument("--invite-concurrency", type=int, default=4)
    ap.add_argument("--only", choices=["random", "invite", "all"], default="all")
    args = ap.parse_args()

    def run_random_mode(mode, wanted):
        # Ramp: try the requested size, step down on failure.
        sizes = [wanted, 500, 250, 100] if mode == "2p" else [wanted, 496, 248, 100]
        for n in sizes:
            if n > wanted:
                continue
            if mode == "4p":
                n -= n % 4
            if n < 4:
                continue
            proc = start_mock()
            try:
                print("== random search %s: %d players ==" % (mode, n), flush=True)
                res = run_random_search(n, mode=mode)
                results["scenarios"].append(res)
                print(json.dumps(res, indent=2), flush=True)
                # Stop ramping once a size completes cleanly.
                if res["errors"]["setup"] == 0 and res["errors"]["find_match"] == 0:
                    return
                print("!! errors at %d players %s — stepping down" % (n, mode), flush=True)
            finally:
                stop_mock(proc)

    results = {"mock_port": PORT, "scenarios": []}
    try:
        if args.only in ("random", "all"):
            if args.mode in ("2p", "both"):
                run_random_mode("2p", args.players)
            if args.mode in ("4p", "both"):
                run_random_mode("4p", args.players)
        if args.only in ("invite", "all"):
            proc = start_mock()
            try:
                print("== invite burst: %d groups x %d concurrent calls ==" % (
                    args.invite_groups, args.invite_concurrency), flush=True)
                res = run_invite_burst(args.invite_groups, args.invite_concurrency)
                results["scenarios"].append(res)
                print(json.dumps(res, indent=2), flush=True)
            finally:
                stop_mock(proc)
    finally:
        out = os.path.join(HERE, "scale_load_results.json")
        with open(out, "w") as fh:
            json.dump(results, fh, indent=2)
        print("results written to %s" % out, flush=True)


if __name__ == "__main__":
    main()
