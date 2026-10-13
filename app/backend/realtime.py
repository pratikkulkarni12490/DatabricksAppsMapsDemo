"""Push updates from Lakebase to browsers.

- Listener (every instance): one LISTEN connection on the primary; notifications are fanned out to SSE subscribers.
- Version watcher (leader only): polls synced-table status (last synced Delta commit) and bumps app.dataset_version,
  whose trigger NOTIFYs every instance. Per-dataset versions are also part of cache keys / ETags.
"""
import asyncio
import json
import logging
import select
import threading
import time

from . import cache, config, db

log = logging.getLogger("geolens.realtime")

SYNCED_TABLE_DATASETS = {
    "retail_hex_monthly": ["retail_demand", "retail_kpis"],
    "retail_hex_profile": ["retail_market", "retail_kpis"],
    "retail_stores": ["stores", "retail_kpis"],
    "retail_store_monthly": ["stores"],
    "retail_store_catchment": ["stores"],
    "retail_competitors": ["competitors"],
    "retail_plots": ["plots", "retail_kpis"],
    "fiber_hex_daily": ["fiber_health"],
    "fiber_hex_profile": ["fiber_coverage"],
    "fiber_olts": ["olts", "fiber_kpis"],
    "fiber_olt_hourly": ["olts"],
    "fiber_fdh": ["fdh"],
    "fiber_incidents": ["incidents_30d", "fiber_kpis"],
    "fiber_kpi_daily": ["fiber_kpis"],
    "fiber_technicians": ["fiber_kpis"],
    "fiber_routes": ["routes"],
    "fiber_open_tickets": ["fiber_kpis"],
    "user_region_scope": ["scope"],
}


class Versions:
    """Per-dataset versions, refreshed instantly on NOTIFY and every 60 s as a fallback."""

    def __init__(self):
        self._v: dict[str, int] = {}
        self._ts = 0.0
        self._lock = threading.Lock()

    def load(self):
        _, rows = db.query("SELECT dataset, version FROM app.dataset_version")
        with self._lock:
            self._v = {r[0]: int(r[1]) for r in rows}
            self._ts = time.time()

    def get(self, dataset: str) -> int:
        if time.time() - self._ts > 60:
            try:
                self.load()
            except Exception as e:
                log.warning("version load failed: %s", e)
                self._ts = time.time()
        return self._v.get(dataset, 0)

    def set(self, dataset: str, version: int):
        with self._lock:
            self._v[dataset] = version

    def all(self) -> dict:
        return dict(self._v)


versions = Versions()


class Hub:
    """Fan-out of server events to SSE subscribers (asyncio queues), fed from the listener thread."""

    def __init__(self):
        self.loop: asyncio.AbstractEventLoop | None = None
        self.subscribers: set[asyncio.Queue] = set()
        self.events_sent = 0

    def subscribe(self) -> asyncio.Queue:
        q: asyncio.Queue = asyncio.Queue(maxsize=200)
        self.subscribers.add(q)
        return q

    def unsubscribe(self, q):
        self.subscribers.discard(q)

    def _broadcast(self, event: dict):
        for q in list(self.subscribers):
            try:
                q.put_nowait(event)
            except asyncio.QueueFull:
                pass  # slow client; it re-syncs on the next event
        self.events_sent += 1

    def publish(self, event: dict):
        if self.loop:
            self.loop.call_soon_threadsafe(self._broadcast, event)


hub = Hub()


def _coalesce_live(notifications: list[dict]) -> list[dict]:
    """Collapse a burst of row/statement notifications into at most one live + one shortlist event."""
    out, kinds = [], set()
    for n in notifications:
        k = n.get("kind")
        if k == "dataset":
            versions.set(n["dataset"], int(n["version"]))
            cache.live.clear() if n["dataset"] == "scope" else None
            out.append(n)
        elif k not in kinds:
            kinds.add(k)
            out.append({"kind": k, "ts": n.get("ts")})
    return out


def listener_loop():
    while True:
        conn = None
        try:
            conn = db.direct_primary_connection()
            cur = conn.cursor()
            cur.execute("LISTEN geolens")
            log.info("listening on geolens")
            born = time.time()
            while time.time() - born < 40 * 60:
                if select.select([conn], [], [], 15) == ([], [], []):
                    hub.publish({"kind": "heartbeat", "ts": time.time()})
                    continue
                conn.poll()
                batch = []
                while conn.notifies:
                    n = conn.notifies.pop(0)
                    try:
                        batch.append(json.loads(n.payload))
                    except ValueError:
                        pass
                time.sleep(0.25)  # small debounce window so one tick = one event
                conn.poll()
                while conn.notifies:
                    try:
                        batch.append(json.loads(conn.notifies.pop(0).payload))
                    except ValueError:
                        pass
                for ev in _coalesce_live(batch):
                    hub.publish(ev)
        except Exception as e:
            log.warning("listener error: %s", e)
            time.sleep(5)
        finally:
            if conn:
                try:
                    conn.close()
                except Exception:
                    pass


def watch_synced_tables_once(cur, last: dict):
    """Leader only: detect landed syncs and bump dataset versions (the NOTIFY trigger fans out to every instance).

    Primary signal: storage signature of each geo.* table from Postgres (relfilenode + size change on every refresh).
    Secondary: the synced-table API's last synced Delta version, if the app principal can read it."""
    sigs = {}
    try:
        cur.execute("SELECT table_name, signature FROM app.synced_table_signatures()")
        sigs = {t: f"pg:{s}" for t, s in cur.fetchall()}
    except Exception as e:
        log.warning("signature query failed: %s", e)
        cur.execute("ROLLBACK")
    if not sigs:
        api = config.workspace_client().api_client
        for table in SYNCED_TABLE_DATASETS:
            try:
                st = api.do("GET", f"/api/2.0/postgres/synced_tables/{config.UC_CATALOG}.geo.{table}")
                ls = st.get("status", {}).get("last_sync", {})
                sigs[table] = f"api:{ls.get('delta_table_sync_info', {}).get('delta_commit_version')}@{ls.get('sync_end_time')}"
            except Exception as e:
                log.warning("synced table status %s: %s", table, e)
    bumped = set()
    for table, sig in sigs.items():
        if table in last and last[table] != sig:
            bumped.update(SYNCED_TABLE_DATASETS.get(table, []))
            log.info("synced table %s changed", table)
        last[table] = sig
    for ds in bumped:
        cur.execute("SELECT app.bump_dataset(%s)", (ds,))
        log.info("dataset %s version bumped", ds)


def start(loop: asyncio.AbstractEventLoop):
    hub.loop = loop
    try:
        versions.load()
    except Exception as e:
        log.warning("initial version load failed: %s", e)
    threading.Thread(target=listener_loop, name="pg-listener", daemon=True).start()
