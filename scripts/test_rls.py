"""Verify Postgres scope enforcement per persona and tile query latency on the replica."""
import os
import sys
import time

sys.path.insert(0, "scripts")
from pg import connect

ME = os.environ.get("PRESENTER_EMAIL", "presenter@example.com")
conn = connect("replica")
cur = conn.cursor()


def as_user(persona):
    cur.execute("SELECT set_config('app.principal', %s, true), set_config('app.persona', %s, true)", (ME, persona or ""))


for persona in [None, "west.head@ril-demo.in", "mumbai.cluster@ril-demo.in", "south.mumbai.ops@ril-demo.in", "nobody@x.in"]:
    as_user(persona)
    cur.execute("SELECT region, count(*) FROM secure.retail_stores GROUP BY 1 ORDER BY 1")
    stores = cur.fetchall()
    cur.execute("SELECT count(*) FROM secure.fiber_olts")
    olts = cur.fetchone()[0]
    print(f"{persona or 'presenter'}: stores={stores} olts={olts}")
    conn.rollback()

# tile latency: res 9 fiber health for one Mumbai tile, 7 days
as_user(None)
cur.execute("SELECT tile_h3 FROM geo.fiber_hex_daily WHERE res = 9 AND metro_code = 'MUM' GROUP BY 1 ORDER BY count(*) DESC LIMIT 1")
tile = cur.fetchone()[0]
q = """SELECT to_hex(h3), sum(health_score * subscribers) / sum(subscribers)
       FROM secure.fiber_hex_daily WHERE res = %s AND tile_h3 = %s AND day BETWEEN %s AND %s GROUP BY h3"""
for i in range(3):
    t0 = time.time()
    cur.execute(q, (9, tile, "2026-10-03", "2026-10-09"))
    rows = cur.fetchall()
    print(f"tile query {i}: {len(rows)} hexes in {1000 * (time.time() - t0):.0f} ms")
cur.execute("EXPLAIN (ANALYZE, BUFFERS) " + q, (9, tile, "2026-10-03", "2026-10-09"))
print("\n".join(r[0] for r in cur.fetchall()[:14]))
conn.rollback()
