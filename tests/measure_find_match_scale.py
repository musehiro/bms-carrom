#!/usr/bin/env python3
"""Scale measurement: mock find_match pairing cost with a 10,000-row queue.

Worker 2 of the BMS Carrom scale-hardening round (2026-11-28).
Spawns tests/mock_supabase.py on port 18082 (NOT the default 18080),
seeds queue rows over HTTP, and measures the find_match RPC per call.

Scenarios (each on a fresh mock process, so the queue starts empty):
  A  2p drain, 10,000 rows, all level 5, same band  -> cost + correctness
  B  4p drain, 10,000 rows, all level 5, same band  -> 4p doubles pairing
  C  2p drain, 10,000 rows, levels cycling 1..10    -> missed-pairing check
  D  4p drain, 10,000 rows, levels cycling 1..10    -> 4p missed-pairing check
  E  2p adversarial, 9,996 rows, levels [1,3,5,2,4,6] repeating
     -> greedy oldest-first stranding (see notes in the summary)
  F  2p no-match scan, 10,000 rows: oldest level 1, rest level 100
     -> per-call cost of a full-partition scan that finds nobody
  G  In-process decomposition (no HTTP, no sort): time the pairing
     filter comprehension alone on 10,000 rows, and time sorted() on
     10,000 rows — separates the mock's re-sort overhead from the scan.

IMPORTANT — what the mock measures and what it does NOT:
  * The mock's find_match_impl re-sorts ALL queue rows by created_at on
    EVERY call (Python sorted(), O(N log N)) and then scans the whole
    list. Real Postgres with matchmaking_queue_lookup_idx /
    matchmaking_queue_pairing_idx does NOT re-sort (the index provides
    created_at order) and evaluates the level filter from the index.
    So the mock's per-call time is a PESSIMISTIC upper bound for SQL:
    the scan portion (scenario G) is the part SQL actually pays.
  * The mock identifies the caller as the OLDEST queue row (no auth).
    In the live system any queued player can be the caller, so a stall
    at the oldest row does not prove no pair exists — scenario E's
    leftovers are checked for mutually compatible pairs separately.
  * Stake validation is trivial here (stake 0, no profiles seeded:
    the mock treats a missing profile as 0 coins, and 0 <= 0 passes).
    The SQL coin check is a PK lookup per player (<= 4 lookups/call),
    negligible next to the scan.

Usage: python3 tests/measure_find_match_scale.py
Prints a per-scenario summary and a JSON summary block at the end.
Kills the mock subprocess when done (also on error).
"""

import json
import statistics
import subprocess
import sys
import time
import urllib.request
import uuid
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
MOCK = REPO / "tests" / "mock_supabase.py"
PORT = 18082
BASE = f"http://127.0.0.1:{PORT}"
N = 10_000


# ---------------------------------------------------------------- HTTP
def http_post(path, obj, timeout=30, retries=5):
    last = None
    for attempt in range(retries):
        try:
            req = urllib.request.Request(
                BASE + path, data=json.dumps(obj).encode(),
                headers={"Content-Type": "application/json",
                         "Connection": "close"}, method="POST")
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return json.loads(r.read().decode())
        except Exception as e:  # mock's listen backlog is small; retry
            last = e
            time.sleep(0.2 * (attempt + 1))
    raise last


def http_get(path, timeout=60):
    with urllib.request.urlopen(BASE + path, timeout=timeout) as r:
        return json.loads(r.read().decode())


# ---------------------------------------------------------------- mock lifecycle
def start_mock():
    proc = subprocess.Popen(
        [sys.executable, str(MOCK), "--port", str(PORT)],
        cwd=str(REPO), stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        text=True)
    deadline = time.time() + 15
    while time.time() < deadline:
        try:
            if http_get("/health", timeout=2).get("ok"):
                return proc
        except Exception:
            time.sleep(0.2)
    proc.kill()
    raise RuntimeError("mock did not become healthy on port %d" % PORT)


def stop_mock(proc):
    proc.terminate()
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()


# ---------------------------------------------------------------- seeding
def seed_queue(n, mode, level_fn, table=0, stake=0):
    base = datetime(2026, 1, 1, tzinfo=timezone.utc)
    rows = []
    for i in range(n):
        rows.append({
            "id": str(uuid.uuid4()),
            "display_name": f"P{i}",
            "level": level_fn(i),
            "table": table,
            "stake": stake,
            "mode": mode,
            "created_at": (base + timedelta(seconds=i)).isoformat(),
        })

    def post(row):
        return http_post("/rest/v1/matchmaking_queue", row)

    t0 = time.perf_counter()
    with ThreadPoolExecutor(max_workers=8) as ex:
        list(ex.map(post, rows))
    seed_ms = (time.perf_counter() - t0) * 1000
    got = http_get("/rest/v1/matchmaking_queue")
    assert len(got) == n, f"seeded {len(got)} rows, expected {n}"
    return seed_ms


def call_find_match(mode, widen=False):
    t0 = time.perf_counter()
    res = http_post("/rest/v1/rpc/find_match",
                    {"p_mode": mode, "p_widen": widen})
    return (time.perf_counter() - t0) * 1000, res


def drain(mode, max_calls=20_000):
    """Call find_match until it stops matching. Returns (calls, matched,
    latencies_ms, last_result)."""
    lat, matched, calls = [], 0, 0
    while calls < max_calls:
        ms, res = call_find_match(mode)
        calls += 1
        lat.append(ms)
        if res.get("matched"):
            matched += 1
        else:
            return calls, matched, lat, res
    return calls, matched, lat, {"matched": False, "error": "max_calls hit"}


def leftover_pairs_exist(rows, window=2):
    """True if any two leftover rows could pair (same mode/table,
    |level diff| <= window). Adjacent-in-sorted-level-order check:
    if any compatible pair exists, some adjacent pair in level order
    is within the window."""
    by_key = {}
    for r in rows:
        by_key.setdefault((r["mode"], r["table"]), []).append(r["level"])
    for levels in by_key.values():
        levels.sort()
        for a, b in zip(levels, levels[1:]):
            if b - a <= window:
                return True
    return False


def stats(lat):
    return {
        "calls": len(lat),
        "mean_ms": round(statistics.mean(lat), 2),
        "median_ms": round(statistics.median(lat), 2),
        "p95_ms": round(sorted(lat)[int(0.95 * len(lat)) - 1], 2) if lat else None,
        "max_ms": round(max(lat), 2) if lat else None,
    }


# ---------------------------------------------------------------- scenarios
def scenario_drain(tag, mode, n, level_fn):
    proc = start_mock()
    try:
        seed_ms = seed_queue(n, mode, level_fn)
        t0 = time.perf_counter()
        calls, matched, lat, last = drain(mode)
        drain_s = time.perf_counter() - t0
        left = http_get("/rest/v1/matchmaking_queue")
        per_match = (len(left) and (n - len(left)) or n)
        out = {
            "scenario": tag, "mode": mode, "seeded": n,
            "seed_ms": round(seed_ms),
            "matches_formed": matched,
            "players_paired": matched * (4 if mode == "4p" else 2),
            "leftover_rows": len(left),
            "leftover_pair_exists": leftover_pairs_exist(left) if left else False,
            "drain_seconds": round(drain_s, 2),
            "last_result": last,
            "per_call_ms": stats(lat),
        }
        print(f"[{tag}] matches={matched} leftover={len(left)} "
              f"pair_among_leftovers={out['leftover_pair_exists']} "
              f"per-call mean={out['per_call_ms']['mean_ms']}ms "
              f"median={out['per_call_ms']['median_ms']}ms "
              f"p95={out['per_call_ms']['p95_ms']}ms "
              f"max={out['per_call_ms']['max_ms']}ms "
              f"drain={drain_s:.1f}s seed={seed_ms:.0f}ms", flush=True)
        return out
    finally:
        stop_mock(proc)


def scenario_no_match_scan(tag, n, calls_n=30):
    proc = start_mock()
    try:
        seed_queue(n, "2p", lambda i: 1 if i == 0 else 100)
        lat = []
        for _ in range(calls_n):
            ms, res = call_find_match("2p")
            assert not res.get("matched"), f"unexpected match: {res}"
            lat.append(ms)
        out = {"scenario": tag, "mode": "2p", "seeded": n,
               "unmatched_calls": calls_n, "per_call_ms": stats(lat)}
        print(f"[{tag}] all {calls_n} calls unmatched; "
              f"per-call mean={out['per_call_ms']['mean_ms']}ms "
              f"median={out['per_call_ms']['median_ms']}ms "
              f"p95={out['per_call_ms']['p95_ms']}ms "
              f"max={out['per_call_ms']['max_ms']}ms", flush=True)
        return out
    finally:
        stop_mock(proc)


def scenario_decomposition(n):
    """In-process only: filter comprehension vs sorted() on 10k rows."""
    sys.path.insert(0, str(REPO / "tests"))
    import mock_supabase as mock  # noqa: E402
    base = datetime(2026, 1, 1, tzinfo=timezone.utc)
    rows = [{"id": str(uuid.uuid4()), "display_name": f"P{i}", "level": 5,
             "table": 0, "stake": 0, "mode": "2p",
             "created_at": (base + timedelta(seconds=i)).isoformat()}
            for i in range(n)]
    # The pairing filter, exactly as find_match_impl does it (minus sort).
    t0 = time.perf_counter()
    reps = 200
    for _ in range(reps):
        others = [r for r in rows[1:]
                  if r["mode"] == "2p" and r["table"] == 0
                  and abs(r["level"] - 5) <= 2]
    filter_ms = (time.perf_counter() - t0) * 1000 / reps
    t0 = time.perf_counter()
    for _ in range(reps):
        rows_sorted = sorted(rows, key=lambda r: r["created_at"])
    sort_ms = (time.perf_counter() - t0) * 1000 / reps
    assert len(others) == n - 1 and len(rows_sorted) == n
    out = {"scenario": "G-decomposition", "rows": n,
           "filter_only_ms_per_call": round(filter_ms, 3),
           "sort_only_ms_per_call": round(sort_ms, 3),
           "note": "filter = the scan SQL pays (index scan, level filter); "
                   "sort = mock-only overhead SQL avoids via the index"}
    print(f"[G-decomposition] filter-only={filter_ms:.3f}ms/call "
          f"sort-only={sort_ms:.3f}ms/call over {reps} reps", flush=True)
    return out


def main():
    results = []
    results.append(scenario_drain("A-2p-all-level5", "2p", N, lambda i: 5))
    results.append(scenario_drain("B-4p-all-level5", "4p", N, lambda i: 5))
    results.append(scenario_drain("C-2p-levels-1to10", "2p", N,
                                  lambda i: (i % 10) + 1))
    results.append(scenario_drain("D-4p-levels-1to10", "4p", N,
                                  lambda i: (i % 10) + 1))
    pat = [1, 3, 5, 2, 4, 6]
    results.append(scenario_drain("E-2p-adversarial", "2p", 9996,
                                  lambda i: pat[i % 6]))
    results.append(scenario_no_match_scan("F-2p-nomatch-scan", N))
    results.append(scenario_decomposition(N))
    print("SUMMARY_JSON " + json.dumps(results))
    return 0


if __name__ == "__main__":
    sys.exit(main())
