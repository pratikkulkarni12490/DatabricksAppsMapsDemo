"""GeoLens load test, browser-like: each virtual user is one HTTP/2 connection (multiplexed), as a real browser tab is.

Usage: python3 geolens_load_h2.py --base URL --users 1000 --duration 240 --tiles tiles.json (--token T | --secret-scope S --secret-key K)
Per user loop: viewport burst of 12-24 tiles (6 concurrent streams), live delta every 4 s (fiber), KPIs every 60 s,
a point layer every ~30 s, think 3-8 s. Reports per-endpoint p50/p95/p99, throughput, status codes, plus the app's own
server-side latency from the Server-Timing header.
"""
import argparse
import asyncio
import json
import random
import time
from collections import defaultdict

import httpx

METRICS = {
    "fiber_health": ["health_score", "uptime_pct", "pct_ont_low_power", "tickets_per_1k", "avg_latency_ms"],
    "fiber_coverage": ["penetration_pct", "unconnected_homes_passed", "cross_sell_prospects"],
    "retail_demand": ["revenue", "rev_fashion", "rev_grocery", "jiomart_share_pct", "orders"],
    "retail_market": ["whitespace_score", "households", "affluence_index", "penetration_pct"],
}
TIMES = {"fiber_health": [("2026-10-03", "2026-10-09"), ("2026-10-09", "2026-10-09"), ("2026-09-10", "2026-10-09")],
         "retail_demand": [("2025-10-01", "2026-09-01"), ("2026-07-01", "2026-09-01")]}

lat = defaultdict(list)
srv = defaultdict(list)
THINK = 1.0  # multiplier on 3-8 s think time; 0 = saturation test
codes = defaultdict(int)


async def call(client, kind, path):
    t0 = time.perf_counter()
    try:
        r = await client.get(path)
        codes[r.status_code] += 1
        ok = r.status_code in (200, 204, 304)
        st = r.headers.get("server-timing", "")
        if "dur=" in st:
            srv[kind].append(float(st.split("dur=")[1].split(",")[0]))
    except Exception as e:  # noqa: BLE001
        codes[type(e).__name__] += 1
        ok = False
    lat[kind].append((1000 * (time.perf_counter() - t0), ok))


async def user(uid, base, token, pool, stop_at):
    rnd = random.Random(uid)
    await asyncio.sleep(rnd.uniform(0, 30 if THINK else 5))  # ramp
    limits = httpx.Limits(max_connections=1, max_keepalive_connections=1)
    async with httpx.AsyncClient(base_url=base, http2=True, limits=limits, timeout=30,
                                 headers={"Authorization": f"Bearer {token}"}) as client:
        await call(client, "me", "/api/me")
        await call(client, "catalog", "/api/catalog?solution=fiber")
        last_live = last_kpi = last_pts = 0.0
        sem = asyncio.Semaphore(6)

        async def tile(path):
            async with sem:
                await call(client, "h3_tile", path)

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
            await asyncio.gather(*(tile(f"/api/h3/{ds}/{res}/{t}?{q}") for t in view))
            now = time.time()
            if fiber and now - last_live > 4:
                since = time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(now - 5)) + "%2B00:00"
                await call(client, "live", f"/api/live?since={since}")
                last_live = now
            if now - last_kpi > 60:
                await call(client, "kpis", "/api/fiber/kpis" if fiber else "/api/retail/kpis")
                last_kpi = now
            if now - last_pts > 30:
                await call(client, "points", "/api/points/olts" if fiber else "/api/points/stores")
                last_pts = now
            await asyncio.sleep(rnd.uniform(3, 8) * THINK)


def pct(v, p):
    v = sorted(v)
    return v[min(len(v) - 1, int(p * len(v)))] if v else 0


async def main(a, token):
    pool = json.load(open(a.tiles))
    stop_at = time.time() + a.duration
    t_start = time.time()

    async def progress():
        while time.time() < stop_at:
            await asyncio.sleep(20)
            recent = [x[0] for x in lat["h3_tile"][-3000:]]
            n = sum(len(v) for v in lat.values())
            print(f"t+{time.time() - t_start:4.0f}s requests={n} tile p50={pct(recent, .5):.0f}ms p95={pct(recent, .95):.0f}ms codes={dict(codes)}", flush=True)

    await asyncio.gather(progress(), *(user(i, a.base.rstrip("/"), token, pool, stop_at) for i in range(a.users)))
    elapsed = time.time() - t_start
    print(f"\n{a.users} virtual users (HTTP/2, 1 connection each), {elapsed:.0f}s")
    print(f"{'endpoint':10} {'count':>8} {'rps':>7} {'p50':>6} {'p95':>6} {'p99':>6} {'err%':>6} {'srv p50':>8} {'srv p95':>8}")
    total = 0
    for k, v in sorted(lat.items(), key=lambda x: -len(x[1])):
        ms = [x[0] for x in v]
        err = sum(1 for x in v if not x[1])
        total += len(v)
        print(f"{k:10} {len(v):8d} {len(v) / elapsed:7.1f} {pct(ms, .5):6.0f} {pct(ms, .95):6.0f} {pct(ms, .99):6.0f} "
              f"{100 * err / max(1, len(v)):6.2f} {pct(srv[k], .5):8.1f} {pct(srv[k], .95):8.1f}")
    print(f"TOTAL      {total:8d} {total / elapsed:7.1f}")
    print("status codes:", dict(codes))


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", required=True)
    ap.add_argument("--token", default=None)
    ap.add_argument("--secret-scope", default=None)
    ap.add_argument("--secret-key", default=None)
    ap.add_argument("--users", type=int, default=200)
    ap.add_argument("--duration", type=int, default=180)
    ap.add_argument("--tiles", default="tiles.json")
    ap.add_argument("--think", type=float, default=1.0)
    a = ap.parse_args()
    THINK = a.think
    tok = a.token
    if not tok:
        from databricks.sdk.runtime import dbutils
        tok = dbutils.secrets.get(a.secret_scope, a.secret_key)
    # Databricks job runtimes already run an event loop on the main thread; use a dedicated thread for ours
    import threading
    t = threading.Thread(target=lambda: asyncio.run(main(a, tok)))
    t.start()
    t.join()
