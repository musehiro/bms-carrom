#!/usr/bin/env python3
"""Probe: what breaks first when many clients connect to the mock at once.

Fires N simultaneous fresh connections at tests/mock_supabase.py and
counts the outcome kinds. Used to explain the setup/find_match errors
seen in scale_load_driver.py runs (setup errors -> stuck searches).

Run: python3 tests/scale_probe_backlog.py [--clients 250] [--port 18084]
"""

import argparse
import http.client
import subprocess
import sys
import threading
import time
from http.server import ThreadingHTTPServer

sys.path.insert(0, __file__.rsplit("/", 1)[0])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--clients", type=int, default=250)
    ap.add_argument("--port", type=int, default=18084)
    args = ap.parse_args()

    print("mock listen backlog (ThreadingHTTPServer.request_queue_size): %s"
          % ThreadingHTTPServer.request_queue_size)

    proc = subprocess.Popen(
        [sys.executable, "tests/mock_supabase.py", "--port", str(args.port)],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    try:
        deadline = time.time() + 15
        while time.time() < deadline:
            try:
                c = http.client.HTTPConnection("127.0.0.1", args.port, timeout=2)
                c.request("GET", "/health")
                r = c.getresponse()
                r.read()
                c.close()
                if r.status == 200:
                    break
            except Exception:  # noqa: BLE001
                time.sleep(0.2)
        else:
            print("mock did not come up")
            return

        barrier = threading.Barrier(args.clients)
        outcomes = {}

        def one(_i):
            try:
                barrier.wait(timeout=30)
            except Exception:  # noqa: BLE001
                pass
            t0 = time.monotonic()
            try:
                c = http.client.HTTPConnection("127.0.0.1", args.port, timeout=10)
                c.request("GET", "/health")
                r = c.getresponse()
                r.read()
                c.close()
                kind = "HTTP %d" % r.status
            except ConnectionRefusedError:
                kind = "ConnectionRefused"
            except TimeoutError:
                kind = "Timeout"
            except Exception as exc:  # noqa: BLE001
                kind = type(exc).__name__
            outcomes.setdefault(kind, []).append(time.monotonic() - t0)

        threads = [threading.Thread(target=one, args=(i,)) for i in range(args.clients)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        for kind, dts in sorted(outcomes.items()):
            print("%-20s %4d  latency max %.2fs" % (kind, len(dts), max(dts)))
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()


if __name__ == "__main__":
    main()
