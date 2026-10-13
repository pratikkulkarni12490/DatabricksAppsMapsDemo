"""GeoLens load test: N virtual users browsing the map like real users (pan/zoom tile bursts, live polling, KPIs, details).

Usage: python3 geolens_load.py --base URL --token TOKEN --users 1000 --duration 300 [--tiles tiles.json]
Each virtual user: pick a solution + metro + resolution, fetch a viewport burst of ~12-24 tiles (6 in parallel, like a
browser), poll /api/live every 4 s, refresh KPIs every 60 s, open a detail every ~30 s, think 3-8 s between pans.
Prints per-endpoint p50/p95/p99, throughput and error rate.
"""
import argparse
import json
import random
import statistics
import threading
import time
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor

import requests
from requests.adapters import HTTPAdapter

METRICS = {
    "fiber_health": ["health_score", "uptime_pct", "pct_ont_low_power", "tickets_per_1k", "avg_latency_ms"],
    "fiber_coverage": ["penetration_pct", "unconnected_homes_passed", "cross_sell_prospects"],
    "retail_demand": ["revenue", "rev_fashion", "rev_grocery", "jiomart_share_pct", "orders"],
    "retail_market": ["whitespace_score", "households", "affluence_index", "penetration_pct"],
}
TIMES = {"fiber_health": [("2026-10-03", "2026-10-09"), ("2026-10-09", "2026-10-09"), ("2026-09-10", "2026-10-09")],
         "retail_demand": [("2025-10-01", "2026-09-01"), ("2026-07-01", "2026-09-01")]}

lat = defaultdict(list)
errors = defaultdict(int)
codes = defaultdict(int)
lock = threading.Lock()
stop_at = 0.0
BURST = None  # shared fetch pool, sized in main (browser-like 6-way parallelism per user, bounded overall)


def record(kind, ms, ok):
    with lock:
        lat[kind].append(ms)
        if not ok:
            errors[kind] += 1


def call(sess, base, kind, path):
    t0 = time.time()
    try:
        r = sess.get(base + path, timeout=30)
        ok = r.status_code in (200, 204, 304)
        with lock:
            codes[r.status_code] += 1
    except requests.RequestException as e:
        ok = False
        with lock:
            codes[type(e).__name__] += 1
    record(kind, 1000 * (time.time() - t0), ok)


def user(uid, base, token, pool):
    rnd = random.Random(uid)
    sess = requests.Session()
    sess.mount("https://", HTTPAdapter(pool_connections=6, pool_maxsize=6))
    sess.headers["Authorization"] = f"Bearer {token}"
    time.sleep(rnd.uniform(0, 20))  # ramp up
    call(sess, base, "me", "/api/me")
    call(sess, base, "catalog", "/api/catalog?solution=fiber")
    last_live = last_kpi = last_detail = 0.0
    while time.time() < stop_at:
        fiber = rnd.random() < 0.6
        ds = rnd.choice(["fiber_health", "fiber_health", "fiber_coverage"] if fiber else ["retail_demand", "retail_demand", "retail_market"])
        metro = rnd.choice(list(pool[ds]))
        res = rnd.choice([r for r in ("6", "7", "8", "9") if r in pool[ds][metro]] or ["8"])
        tiles = pool[ds][metro][res]
        start = rnd.randrange(len(tiles))
        view = [tiles[(start + i) % len(tiles)] for i in range(min(len(tiles), rnd.randint(12, 24)))]
        metric = rnd.choice(METRICS[ds])
        t0, t1 = rnd.choice(TIMES.get(ds, [(None, None)]))
        q = f"metric={metric}" + (f"&t0={t0}&t1={t1}" if t0 else "")
        futs = [BURST.submit(call, sess, base, "h3_tile", f"/api/h3/{ds}/{res}/{t}?{q}") for t in view]
        for f in futs:
            f.result()
        now = time.time()
        if fiber and now - last_live > 4:
            call(sess, base, "live", "/api/live?since=" + time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(now - 5)) + "%2B00:00")
            last_live = now
        if now - last_kpi > 60:
            call(sess, base, "kpis", "/api/fiber/kpis" if fiber else "/api/retail/kpis")
            last_kpi = now
        if now - last_detail > 30:
            call(sess, base, "points", "/api/points/olts" if fiber else "/api/points/stores")
            last_detail = now
        time.sleep(rnd.uniform(3, 8))


def pct(v, p):
    v = sorted(v)
    return v[min(len(v) - 1, int(p * len(v)))] if v else 0


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", required=True)
    ap.add_argument("--token", default=None, help="bearer token; or use --secret-scope/--secret-key inside Databricks")
    ap.add_argument("--secret-scope", default=None)
    ap.add_argument("--secret-key", default=None)
    ap.add_argument("--users", type=int, default=200)
    ap.add_argument("--duration", type=int, default=180)
    ap.add_argument("--tiles", default="tiles.json")
    a = ap.parse_args()
    if not a.token:
        from databricks.sdk.runtime import dbutils  # running as a Databricks job
        a.token = dbutils.secrets.get(a.secret_scope, a.secret_key)
    pool = json.load(open(a.tiles))
    BURST = ThreadPoolExecutor(max_workers=min(600, max(50, a.users // 2)))
    stop_at = time.time() + a.duration
    threads = [threading.Thread(target=user, args=(i, a.base.rstrip("/"), a.token, pool), daemon=True) for i in range(a.users)]
    t_start = time.time()
    for t in threads:
        t.start()
    while time.time() < stop_at:
        time.sleep(15)
        with lock:
            n = sum(len(v) for v in lat.values())
            e = sum(errors.values())
            recent = lat["h3_tile"][-2000:]
        print(f"t+{time.time() - t_start:4.0f}s requests={n} errors={e} tile p50={pct(recent, 0.5):.0f}ms p95={pct(recent, 0.95):.0f}ms", flush=True)
    elapsed = time.time() - t_start
    print(f"\n{a.users} virtual users, {elapsed:.0f}s")
    print(f"{'endpoint':10} {'count':>8} {'rps':>7} {'p50':>6} {'p95':>6} {'p99':>6} {'err%':>6}")
    total = 0
    for k, v in sorted(lat.items(), key=lambda x: -len(x[1])):
        total += len(v)
        print(f"{k:10} {len(v):8d} {len(v) / elapsed:7.1f} {pct(v, .5):6.0f} {pct(v, .95):6.0f} {pct(v, .99):6.0f} {100 * errors[k] / max(1, len(v)):6.2f}")
    print(f"TOTAL      {total:8d} {total / elapsed:7.1f}  errors={sum(errors.values())}")
    print("status codes:", dict(codes))
