"""Smoke-test every GeoLens API route. Usage: python3 scripts/smoke_api.py [base_url] (local by default)."""
import json
import sys
import threading
import time

import requests

BASE = (sys.argv[1] if len(sys.argv) > 1 else "http://localhost:8799").rstrip("/")
HDRS = {}
if len(sys.argv) > 2:
    HDRS["Authorization"] = f"Bearer {sys.argv[2]}"
S = requests.Session()
S.headers.update(HDRS)


def get(path, **kw):
    t0 = time.time()
    r = S.get(BASE + path, timeout=60, **kw)
    return r, 1000 * (time.time() - t0)


def check(name, path, show=None, **kw):
    r, ms = get(path, **kw)
    ok = r.status_code in (200, 204)
    size = len(r.content)
    detail = ""
    if ok and show and r.headers.get("content-type", "").startswith("application/json"):
        detail = show(r.json())
    print(f"{'OK ' if ok else 'ERR'} {r.status_code} {ms:6.0f} ms {size:8d} B  {name}  {detail if ok else r.text[:200]}")
    return r


meta = check("meta", "/api/meta", lambda j: f"metros={len(j['metros'])}").json()
check("catalog retail", "/api/catalog?solution=retail", lambda j: f"layers={len(j)}")
# find a Mumbai res-9 tile from the stores' h3 (tile = parent at res 6)
pts = check("points stores", "/api/points/stores", lambda j: f"rows={len(j['rows'])}").json()
for ds in ["competitors", "plots", "olts", "fdh", "incidents_30d"]:
    check(f"points {ds}", f"/api/points/{ds}", lambda j: f"rows={len(j['rows'])}")
r = check("retail kpis", "/api/retail/kpis", lambda j: f"stores={j['stores']} rev_cr={round(j['revenue_12m'] / 1e7)}")
r = check("fiber kpis", "/api/fiber/kpis", lambda j: f"day={j['day']} live={j['live']}")

try:
    import h3  # type: ignore
except ImportError:
    h3 = None
tile6 = "8660145b7ffffff"
tile5 = "85608b0bfffffff"
if h3:
    tile6 = h3.cell_to_parent(h3.latlng_to_cell(19.07, 72.88, 9), 6)
for res, tile in [(9, tile6), (8, None)]:
    if tile is None:
        continue
    check(f"h3 fiber_health r{res}", f"/api/h3/fiber_health/{res}/{tile}?metric=health_score", lambda j: f"hexes={len(j['h'])}")
    check(f"h3 retail_demand r{res}", f"/api/h3/retail_demand/{res}/{tile}?metric=revenue", lambda j: f"hexes={len(j['h'])}")
    r2 = check(f"h3 retail_market r{res} (repeat=cache)", f"/api/h3/retail_market/{res}/{tile}?metric=whitespace_score",
               lambda j: f"hexes={len(j['h'])}")
    etag = r2.headers.get("etag")
    r3, ms = get(f"/api/h3/retail_market/{res}/{tile}?metric=whitespace_score", headers={"If-None-Match": etag})
    print(f"{'OK ' if r3.status_code == 304 else 'ERR'} {r3.status_code} {ms:6.0f} ms  etag revalidation")
    hexes = r2.json()["h"]
    if hexes:
        check("h3cell retail_market", f"/api/h3cell/retail_market/{hexes[0]}", lambda j: f"keys={len(j)}")
check("mvt plots z12", "/api/mvt/plots/12/2919/1872.pbf")
check("mvt routes z12", "/api/mvt/routes/12/2919/1872.pbf")
code = pts["rows"][0][0]
check("store 360", f"/api/retail/store/{code}", lambda j: f"catch={len(j['catchment'])} p80={j['cells_for_80pct']}")
plots = check("plots ranked", "/api/retail/plots?metro=MUM&limit=5", lambda j: f"top={j[0]['plot_id']} {j[0]['best_score']}").json()
check("plot detail", f"/api/retail/plot/{plots[0]['plot_id']}", lambda j: f"geom={j['plot']['geometry']['type']}")
r = S.post(BASE + "/api/retail/shortlist", json={"plot_id": plots[0]["plot_id"], "note": "smoke test"}, timeout=30)
print(("OK " if r.ok else "ERR"), r.status_code, "shortlist add", r.text[:100])
check("shortlist list", "/api/retail/shortlist", lambda j: f"n={len(j)}")
olts = check("points olts", "/api/points/olts", lambda j: "").json()
check("olt detail", f"/api/fiber/olt/{olts['rows'][0][0]}", lambda j: f"hourly={len(j['hourly'])} fdh={len(j['fdh'])}")
live = check("live full", "/api/live", lambda j: f"live={len(j['live'])} noc={len(j['noc'])} tech={len(j['technicians'])}").json()
check("live delta", f"/api/live?since={live['server_ts']}", lambda j: f"live={len(j['live'])} tech={len(j['technicians'])}")
inc = (live["live"] or live["noc"])[0]["incident_id"]
check("incident detail", f"/api/fiber/incident/{inc}", lambda j: f"techs={len(j['nearest_technicians'])}")
r = S.post(BASE + "/api/maps", json={"solution": "fiber", "name": "smoke", "config": {"layers": []}, "shared": True}, timeout=30)
print(("OK " if r.ok else "ERR"), r.status_code, "save map", r.text[:80])
check("persona west: stores", "/api/points/stores", lambda j: f"rows={len(j['rows'])}", headers={"X-GeoLens-Persona": "west.head@ril-demo.in"})
check("persona delhi.noc: olts", "/api/points/olts", lambda j: f"rows={len(j['rows'])}", headers={"X-GeoLens-Persona": "delhi.noc@ril-demo.in"})

events = []


def sse():
    with S.get(BASE + "/api/stream", stream=True, timeout=30) as r:
        for line in r.iter_lines():
            if line.startswith(b"event:"):
                events.append(line.decode()[7:])
            if len(events) >= 3:
                break


t = threading.Thread(target=sse, daemon=True)
t.start()
t.join(timeout=20)
print(("OK " if len(events) >= 2 else "ERR"), "SSE events:", events)
check("health", "/api/health", lambda j: f"leader={j['simulator_leader']} ticks={j['ticks']} cache={j['cache']['tiles']}")
