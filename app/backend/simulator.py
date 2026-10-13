"""Live Jio Fiber network simulator + synced-table watcher. Exactly one app instance runs it (Postgres advisory lock).

Every tick: maybe raise new incidents (occasionally a storm burst in one metro), auto-dispatch the nearest available
technician, move en-route technicians, resolve finished jobs, jitter idle technicians. All writes go to app.* tables,
whose triggers NOTIFY every app instance, which push to browsers over SSE.
"""
import datetime as dt
import logging
import random
import threading
import time

from . import config, db, realtime

log = logging.getLogger("geolens.simulator")

LOCK_ID = 424242
TICK_S = 4
MAX_OPEN = 90
TYPES = [("Distribution fiber cut", 0.34, "FDH"), ("LOS alarm cluster", 0.26, "FDH"), ("Power failure", 0.16, "OLT"),
         ("FDH damage", 0.10, "FDH"), ("Feeder fiber cut", 0.08, "OLT"), ("OLT card failure", 0.06, "OLT")]
CAUSES = {"Distribution fiber cut": ["Civil works (third party)", "Rodent damage", "Waterlogging", "Vehicle hit pole"],
          "Feeder fiber cut": ["Civil works (third party)", "Metro construction", "Vandalism"],
          "Power failure": ["Grid outage, battery exhausted", "DG set failure"],
          "FDH damage": ["Cabinet damage", "Water ingress"], "OLT card failure": ["Line card hardware fault"],
          "LOS alarm cluster": ["Macro-bend / connector degradation"]}


class Simulator:
    def __init__(self):
        self.olts: list[dict] = []
        self.weights: list[float] = []
        self.last_sync_sigs: dict = {}
        self.last_watch = 0.0
        self.ticks = 0
        self.leader = False

    def _seed(self, cur):
        cur.execute("SELECT set_config('app.principal', %s, false)", (config.SIMULATOR_PRINCIPAL,))
        cur.execute("""SELECT olt_id, metro_code, region, locality, latitude, longitude, homes_connected
                       FROM secure.fiber_olts WHERE homes_connected > 0""")
        cols = [d[0] for d in cur.description]
        self.olts = [dict(zip(cols, r)) for r in cur.fetchall()]
        self.weights = [float(o["homes_connected"]) for o in self.olts]
        cur.execute("SELECT count(*) FROM app.live_technicians")
        if cur.fetchone()[0] == 0:
            cur.execute("""INSERT INTO app.live_technicians (technician_id, metro_code, region, locality, skill, status, latitude, longitude)
                           SELECT technician_id, metro_code, region, locality, skill, status, latitude, longitude
                           FROM secure.fiber_technicians ON CONFLICT DO NOTHING""")
            log.info("seeded live technicians: %s", cur.rowcount)

    def _new_incident(self, cur, olt: dict, storm: bool = False):
        r = random.random()
        acc = 0.0
        for name, p, lvl in TYPES:
            acc += p
            if r <= acc:
                break
        homes_base = float(olt["homes_connected"])
        homes = int(homes_base * {"OLT card failure": 0.125, "LOS alarm cluster": random.uniform(0.02, 0.06),
                                  "FDH damage": random.uniform(0.03, 0.08)}.get(
            name, 1.0 if lvl == "OLT" else random.uniform(0.04, 0.12)))
        homes = max(homes, random.randint(8, 40))
        sev = "P1" if homes > 1000 else "P2" if homes > 300 else "P3" if homes > 50 else "P4"
        lat = float(olt["latitude"]) + random.uniform(-0.012, 0.012)
        lon = float(olt["longitude"]) + random.uniform(-0.012, 0.012)
        iid = f"LIVE-{dt.datetime.utcnow():%y%m%d%H%M%S}-{random.randint(1000, 9999)}"
        cause = "Storm damage" if storm else random.choice(CAUSES[name])
        cur.execute("""INSERT INTO app.live_incidents (incident_id, incident_type, severity, network_level, olt_id, metro_code, region,
                                                       locality, latitude, longitude, homes_impacted, root_cause)
                       VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s) ON CONFLICT DO NOTHING""",
                    (iid, name, sev, lvl, olt["olt_id"], olt["metro_code"], olt["region"], olt["locality"], lat, lon, homes, cause))

    def tick(self, cur):
        self.ticks += 1
        cur.execute("BEGIN")
        cur.execute("SELECT count(*) FROM app.live_incidents WHERE status = 'Open'")
        open_now = cur.fetchone()[0]
        if open_now < MAX_OPEN and self.olts:
            for _ in range(random.choice([0, 1, 1, 1, 2])):
                self._new_incident(cur, random.choices(self.olts, self.weights)[0])
            if self.ticks % 45 == 0:  # roughly every 3 minutes: a storm cell hits one locality
                epicentre = random.choices(self.olts, self.weights)[0]
                nearby = [o for o in self.olts if o["metro_code"] == epicentre["metro_code"]
                          and abs(float(o["latitude"]) - float(epicentre["latitude"])) < 0.05
                          and abs(float(o["longitude"]) - float(epicentre["longitude"])) < 0.05]
                for o in random.sample(nearby, min(len(nearby), random.randint(4, 7))):
                    self._new_incident(cur, o, storm=True)
                log.info("storm burst near %s", epicentre["locality"])
        # dispatch nearest available technician (same metro) to unassigned incidents older than ~8 s
        cur.execute("""
          WITH pending AS (
            SELECT incident_id, metro_code, latitude, longitude FROM app.live_incidents
            WHERE status = 'Open' AND assigned_technician IS NULL AND start_ts < now() - interval '8 seconds'
            ORDER BY severity, start_ts LIMIT 6),
          pick AS (
            SELECT DISTINCT ON (t.technician_id) p.incident_id, t.technician_id, p.latitude, p.longitude
            FROM pending p CROSS JOIN LATERAL (
              SELECT technician_id FROM app.live_technicians t
              WHERE t.metro_code = p.metro_code AND t.status = 'Available'
              ORDER BY power((t.longitude - p.longitude) * cos(radians(p.latitude)), 2) + power(t.latitude - p.latitude, 2)
              LIMIT 1) t),
          upd AS (
            UPDATE app.live_technicians t SET status = 'En route', assigned_incident = pick.incident_id,
                   target_lat = pick.latitude, target_lon = pick.longitude, updated_at = now()
            FROM pick WHERE t.technician_id = pick.technician_id RETURNING t.technician_id, pick.incident_id)
          UPDATE app.live_incidents i SET assigned_technician = upd.technician_id, updated_at = now()
          FROM upd WHERE i.incident_id = upd.incident_id""")
        # drive en-route technicians towards their incident; arrive within ~150 m
        cur.execute("""UPDATE app.live_technicians SET
                         latitude = latitude + (target_lat - latitude) * 0.3,
                         longitude = longitude + (target_lon - longitude) * 0.3, updated_at = now()
                       WHERE status = 'En route' AND target_lat IS NOT NULL""")
        cur.execute("""UPDATE app.live_technicians SET status = 'On job', latitude = target_lat, longitude = target_lon, updated_at = now()
                       WHERE status = 'En route' AND abs(latitude - target_lat) < 0.0014 AND abs(longitude - target_lon) < 0.0014""")
        # resolve jobs after 1-4 minutes on site
        cur.execute("""
          WITH done AS (
            UPDATE app.live_incidents i SET status = 'Resolved', end_ts = now(), updated_at = now()
            FROM app.live_technicians t
            WHERE t.technician_id = i.assigned_technician AND t.status = 'On job' AND i.status = 'Open'
              AND t.updated_at < now() - make_interval(secs => 60 + abs(hashtext(i.incident_id)) % 180)
            RETURNING i.assigned_technician)
          UPDATE app.live_technicians t SET status = 'Available', assigned_incident = NULL, target_lat = NULL, target_lon = NULL,
                 updated_at = now()
          FROM done WHERE t.technician_id = done.assigned_technician""")
        # a little idle movement so the field force looks alive
        cur.execute("""UPDATE app.live_technicians SET latitude = latitude + (random() - 0.5) * 0.002,
                              longitude = longitude + (random() - 0.5) * 0.002, updated_at = now()
                       WHERE status = 'Available' AND random() < 0.01""")
        cur.execute("DELETE FROM app.live_incidents WHERE status = 'Resolved' AND end_ts < now() - interval '30 minutes'")
        cur.execute("COMMIT")

    def run(self):
        while True:
            conn = None
            try:
                conn = db.direct_primary_connection()
                cur = conn.cursor()
                cur.execute("SELECT pg_try_advisory_lock(%s)", (LOCK_ID,))
                self.leader = bool(cur.fetchone()[0])
                if not self.leader:
                    conn.close()
                    time.sleep(30)
                    continue
                log.info("simulator leader elected")
                self._seed(cur)
                born = time.time()
                while time.time() - born < 40 * 60:  # reconnect before the OAuth token expires
                    t0 = time.time()
                    if config.SIMULATOR_ENABLED:
                        try:
                            self.tick(cur)
                        except Exception as e:
                            log.warning("tick failed: %s", e)
                            cur.execute("ROLLBACK")
                    if time.time() - self.last_watch > 30:
                        self.last_watch = time.time()
                        realtime.watch_synced_tables_once(cur, self.last_sync_sigs)
                    time.sleep(max(0.5, TICK_S - (time.time() - t0)))
            except Exception as e:
                log.warning("simulator error: %s", e)
                self.leader = False
                time.sleep(10)
            finally:
                if conn:
                    try:
                        conn.close()
                    except Exception:
                        pass


simulator = Simulator()


def start():
    threading.Thread(target=simulator.run, name="simulator", daemon=True).start()
