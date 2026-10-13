import asyncio
import datetime as dt
import hashlib
import json
from decimal import Decimal

from fastapi import APIRouter, HTTPException, Request, Response
from fastapi.responses import StreamingResponse
from pydantic import BaseModel

from . import agent, cache, config, db, metrics, realtime
from .datasets import CATALOG, H3_DATASETS, METROS, MVT_DATASETS, POINT_DATASETS

router = APIRouter(prefix="/api")


# ---------- identity, scope, response helpers ----------

class Ctx:
    def __init__(self, principal: str, persona: str, scope_key: str, scope_rows: list):
        self.principal, self.persona, self.scope_key, self.scope_rows = principal, persona, scope_key, scope_rows

    def q(self, sql, params=(), write=False):
        return db.query(sql, params, self.principal, self.persona, write)

    def qd(self, sql, params=(), write=False):
        return db.query_dicts(sql, params, self.principal, self.persona, write)


def ctx(request: Request) -> Ctx:
    principal = request.headers.get("x-forwarded-email") if config.IS_APP else config.LOCAL_USER
    if not principal:
        raise HTTPException(401, "No authenticated user")
    persona = (request.headers.get("x-geolens-persona") or "").strip()

    def load():
        _, rows = db.query("SELECT scope_level, scope_value, persona FROM app.my_scope() ORDER BY 1, 2", (), principal, persona)
        key = "|".join(f"{r[0]}:{r[1]}" for r in rows) or "NONE"
        return key, [{"scope_level": r[0], "scope_value": r[1], "persona": r[2]} for r in rows]

    key, rows = cache.scopes.get_or_compute((principal, persona), load)
    return Ctx(principal, persona, key, rows)


def version(dataset: str = "catalog") -> int:
    return realtime.versions.get(dataset)


def _default(o):
    if isinstance(o, Decimal):
        return float(o)
    if isinstance(o, (dt.date, dt.datetime)):
        return o.isoformat()
    if isinstance(o, (bytes, memoryview)):
        return None
    return str(o)


def dumps(obj) -> bytes:
    return json.dumps(obj, separators=(",", ":"), default=_default).encode()


def cached(request: Request, store: cache.SharedCache, key: tuple, compute, dataset: str, max_age=600,
           media="application/json"):
    """Serve from the shared cache with an ETag. Keys include scope + the dataset's version, never the user."""
    full_key = key + (version(dataset), version("scope"))
    etag = '"' + hashlib.md5(repr(full_key).encode()).hexdigest() + '"'
    headers = {"ETag": etag, "Cache-Control": f"private, max-age={max_age}"}
    if request.headers.get("if-none-match") == etag:
        return Response(status_code=304, headers=headers)
    body = store.get_or_compute(full_key, compute)
    return Response(content=body, media_type=media, headers=headers)


def _date(s: str | None, default: str) -> str:
    try:
        return dt.date.fromisoformat(s or default).isoformat()
    except ValueError:
        raise HTTPException(400, f"bad date {s}")


TIME_DEFAULTS = {"month": ("2025-10-01", "2026-09-01"), "day": ("2026-10-03", "2026-10-09")}


def _time_clause(ds: dict, t0, t1):
    if not ds["time"]:
        return "", ()
    d0, d1 = TIME_DEFAULTS[ds["time_kind"]]
    return f" AND {ds['time']} BETWEEN %s AND %s", (_date(t0, d0), _date(t1, d1))


METRO_CODES = {m["code"] for m in METROS}


def _metro(metro: str | None) -> str | None:
    if not metro:
        return None
    if metro not in METRO_CODES:
        raise HTTPException(400, "unknown metro")
    return metro


def _round(v):
    if v is None:
        return None
    v = float(v)
    return round(v, 4) if abs(v) < 100 else round(v, 1)


# ---------- metadata ----------

@router.get("/me")
def me(request: Request):
    c = ctx(request)
    presenter = any(r["scope_level"] == "NATIONAL" for r in c.scope_rows) and not c.persona
    _, real = db.query("SELECT bool_or(scope_level = 'NATIONAL') FROM app.my_scope()", (), c.principal, "")
    is_presenter = bool(real and real[0][0])
    personas = c.qd("SELECT principal, persona, scopes FROM app.demo_personas()") if is_presenter else []
    label = (c.scope_rows[0]["persona"] if c.scope_rows else "No access")
    return {"principal": c.principal, "persona": c.persona, "persona_label": label, "scope_key": c.scope_key,
            "scopes": c.scope_rows, "is_presenter": is_presenter, "national": presenter or c.scope_key.startswith("NATIONAL"),
            "personas": personas, "versions": realtime.versions.all()}


@router.get("/meta")
def meta():
    datasets = {k: {"time": v["time"], "time_kind": v.get("time_kind"),
                    "metrics": {mk: {**{x: mv[x] for x in ("label", "unit", "fmt", "palette", "better")},
                                     # plain sums can be added up when the map rolls cells into parents; rates are averaged
                                     "additive": mv["expr"].startswith("sum(") and "/" not in mv["expr"]}
                                for mk, mv in v["metrics"].items()}}
                for k, v in H3_DATASETS.items()}
    months = [f"{y}-{m:02d}-01" for y, m in [(2025, 10), (2025, 11), (2025, 12)] + [(2026, i) for i in range(1, 10)]]
    days = [(dt.date(2026, 9, 10) + dt.timedelta(days=i)).isoformat() for i in range(30)]
    return {"metros": METROS, "datasets": datasets, "months": months, "days": days, "as_of": "2026-10-10T06:00:00Z",
            "genie": {"retail": config.GENIE_SPACE_RETAIL, "fiber": config.GENIE_SPACE_FIBER},
            "workspace_host": config.workspace_host() if config.IS_APP else ""}


@router.get("/catalog")
def catalog(request: Request, solution: str):
    def load():
        try:
            rows = db.query_dicts("SELECT * FROM app.layer_catalog WHERE solution = %s ORDER BY sort_order", (solution,))
        except Exception:
            rows = []
        return dumps(rows or [c for c in CATALOG if c["solution"] == solution])
    return cached(request, cache.entities, ("catalog", solution), load, dataset="catalog", max_age=300)


# ---------- H3 tiles ----------

@router.get("/h3/{dataset}/{res}/{tile}")
def h3_tile(request: Request, dataset: str, res: int, tile: str, metric: str, t0: str | None = None, t1: str | None = None,
            metro: str | None = None):
    ds = H3_DATASETS.get(dataset)
    if not ds or metric not in ds["metrics"] or not 5 <= res <= 9:
        raise HTTPException(400, "unknown dataset/metric/res")
    try:
        tile_id = int(tile, 16)
    except ValueError:
        raise HTTPException(400, "bad tile")
    c = ctx(request)
    tclause, tparams = _time_clause(ds, t0, t1)
    m = _metro(metro)
    mclause, mparams = (" AND metro_code = %s", (m,)) if m else ("", ())
    sql = (f"SELECT to_hex(h3), ({ds['metrics'][metric]['expr']})::float8 FROM {ds['view']} "
           f"WHERE res = %s AND tile_h3 = %s{tclause}{mclause} GROUP BY h3")

    def load():
        _, rows = c.q(sql, (res, tile_id) + tparams + mparams)
        return dumps({"h": [r[0] for r in rows], "v": [_round(r[1]) for r in rows]})

    return cached(request, cache.tiles, ("h3", dataset, metric, res, tile_id, tparams, m, c.scope_key), load, dataset=dataset, max_age=1800)


@router.get("/h3cell/{dataset}/{h3}")
def h3_cell(request: Request, dataset: str, h3: str, t0: str | None = None, t1: str | None = None):
    ds = H3_DATASETS.get(dataset)
    if not ds:
        raise HTTPException(400, "unknown dataset")
    c = ctx(request)
    tclause, tparams = _time_clause(ds, t0, t1)
    exprs = ", ".join(f"({m['expr']})::float8 AS {k}" for k, m in ds["metrics"].items())
    sql = f"SELECT {exprs}, max(metro_code) AS metro_code FROM {ds['view']} WHERE h3 = %s{tclause}"

    def load():
        rows = c.qd(sql, (int(h3, 16),) + tparams)
        return dumps({k: (_round(v) if k != "metro_code" else v) for k, v in (rows[0] if rows else {}).items()})

    return cached(request, cache.entities, ("cell", dataset, h3, tparams, c.scope_key), load, dataset=dataset, max_age=600)


# ---------- point layers ----------

@router.get("/points/{dataset}")
def points(request: Request, dataset: str, metro: str | None = None):
    ds = POINT_DATASETS.get(dataset)
    if not ds:
        raise HTTPException(400, "unknown dataset")
    c = ctx(request)
    m = _metro(metro)
    sql, params = (f"SELECT * FROM ({ds['sql']}) p WHERE metro_code = %s", (m,)) if m else (ds["sql"], ())

    def load():
        cols, rows = c.q(sql, params)
        return dumps({"cols": cols, "rows": [[_round(x) if isinstance(x, (float, Decimal)) else x for x in r] for r in rows]})

    return cached(request, cache.entities, ("points", dataset, m, c.scope_key), load, dataset=dataset, max_age=600)


# ---------- PostGIS vector tiles ----------

@router.get("/mvt/{dataset}/{z}/{x}/{y}.pbf")
def mvt(request: Request, dataset: str, z: int, x: int, y: int, metro: str | None = None):
    ds = MVT_DATASETS.get(dataset)
    if not ds:
        raise HTTPException(400, "unknown dataset")
    if z < ds["min_zoom"]:
        return Response(status_code=204)
    c = ctx(request)
    m = _metro(metro)
    zf = f" AND {ds['zoom_filter']}" if ds.get("zoom_filter") else ""
    if m:
        zf += " AND v.metro_code = %(metro)s"
    sql = f"""
      WITH b AS (SELECT ST_TileEnvelope(%(z)s, %(x)s, %(y)s) AS env),
      f AS (
        SELECT {ds['props']},
               ST_AsMVTGeom(ST_Transform(ST_GeomFromEWKB(v.geom_ewkb), 3857), b.env, 4096, 64, true) AS geom
        FROM {ds['view']} v, b
        WHERE ST_GeomFromEWKB(v.geom_ewkb) && ST_Transform(b.env, 4326){zf}
      )
      SELECT ST_AsMVT(f, '{ds['layer']}', 4096, 'geom') FROM f"""

    def load():
        _, rows = c.q(sql, {"z": z, "x": x, "y": y, "metro": m})
        return bytes(rows[0][0]) if rows and rows[0][0] is not None else b""

    return cached(request, cache.tiles, ("mvt", dataset, z, x, y, m, c.scope_key), load, dataset=dataset, max_age=1800,
                  media="application/vnd.mapbox-vector-tile")


# ---------- live operations (Jio Fiber) ----------

LIVE_INC_COLS = ("incident_id, incident_type, severity, latitude, longitude, homes_impacted, status, start_ts, end_ts, "
                 "root_cause, metro_code, olt_id, fdh_id, assigned_technician, updated_at")


@router.get("/live")
def live(request: Request, since: str | None = None, metro: str | None = None):
    c = ctx(request)
    m = _metro(metro)
    try:
        since_ts = dt.datetime.fromisoformat(since.replace(" ", "+")) if since else None
    except ValueError:
        since_ts = None

    def load():
        if since_ts is None:
            inc = c.qd(f"SELECT {LIVE_INC_COLS} FROM app.live_incidents WHERE status = 'Open' OR updated_at > now() - interval '10 minutes'")
            noc = c.qd("""SELECT incident_id, incident_type, severity, latitude, longitude, homes_impacted, status, start_ts,
                                 root_cause, metro_code, olt_id, fdh_id, age_min FROM secure.fiber_incidents
                          WHERE status = 'Open' AND incident_id NOT IN (SELECT incident_id FROM app.live_incidents)""")
            tech = c.qd("SELECT technician_id, skill, status, latitude, longitude, target_lat, target_lon, metro_code, assigned_incident FROM app.live_technicians")
        else:
            inc = c.qd(f"SELECT {LIVE_INC_COLS} FROM app.live_incidents WHERE updated_at > %s", (since_ts,))
            noc = []
            tech = c.qd("""SELECT technician_id, skill, status, latitude, longitude, target_lat, target_lon, metro_code, assigned_incident
                           FROM app.live_technicians WHERE updated_at > %s""", (since_ts,))
        now = c.q("SELECT now()")[1][0][0]
        return dumps({"server_ts": now, "full": since_ts is None, "live": inc, "noc": noc, "technicians": tech})

    # since is quantised to the simulator tick by clients echoing server_ts, so concurrent pollers share entries
    body = cache.live.get_or_compute(("live", since, c.scope_key), load)
    if m:
        def scoped():
            d = json.loads(body)
            for k in ("live", "noc", "technicians"):
                d[k] = [r for r in d[k] if r.get("metro_code") == m]
            return dumps(d)
        body = cache.live.get_or_compute(("live", since, m, c.scope_key), scoped)
    return Response(content=body, media_type="application/json", headers={"Cache-Control": "no-store"})


@router.get("/fiber/kpis")
def fiber_kpis(request: Request, metro: str | None = None):
    c = ctx(request)
    m = _metro(metro)
    w, wp = (" AND metro_code = %s", (m,)) if m else ("", ())
    w1 = w.replace(" AND", " WHERE", 1)

    def load():
        last = c.q("SELECT max(day) FROM secure.fiber_kpi_daily")[1][0][0]
        by_metro = c.qd(f"""SELECT metro_code, region, subscribers, uptime_pct, health_score, incidents, p1_incidents, sla_breaches,
                                  tickets, mttr_min, homes_impacted FROM secure.fiber_kpi_daily WHERE day = %s{w} ORDER BY metro_code""",
                        (last,) + wp)
        trend = c.qd(f"""SELECT day, sum(subscribers) AS subscribers,
                               round((sum(uptime_pct * subscribers) / sum(subscribers))::numeric, 3) AS uptime_pct,
                               round((sum(health_score * subscribers) / sum(subscribers))::numeric, 1) AS health_score,
                               sum(incidents) AS incidents, sum(p1_incidents) AS p1, sum(tickets) AS tickets, sum(sla_breaches) AS sla_breaches
                        FROM secure.fiber_kpi_daily{w1} GROUP BY day ORDER BY day""", wp)
        olts = c.qd(
            f"""SELECT count(*) AS olts, count(*) FILTER (WHERE capacity_status = 'Exhausted') AS exhausted,
                      count(*) FILTER (WHERE capacity_status = 'Augment <6m') AS augment,
                      count(*) FILTER (WHERE current_status = 'Down') AS down_now,
                      count(*) FILTER (WHERE current_status = 'Degraded') AS degraded_now,
                      sum(homes_connected) AS subscribers, sum(homes_passed) AS homes_passed
               FROM secure.fiber_olts{w1}""", wp)[0]
        return dumps({"day": last, "by_metro": by_metro, "trend": trend, "olts": olts})

    static = json.loads(cache.entities.get_or_compute(("fiber_kpis", m, c.scope_key, version("fiber_kpis"), version("scope")), load))

    def load_live():
        mf = "AND metro_code = %(m)s" if m else ""
        return dumps(c.qd(f"""
          SELECT (SELECT count(*) FROM secure.fiber_incidents WHERE status = 'Open' {mf}
                    AND incident_id NOT IN (SELECT incident_id FROM app.live_incidents)) +
                 (SELECT count(*) FROM app.live_incidents WHERE status = 'Open' {mf}) AS open_incidents,
                 (SELECT count(*) FROM secure.fiber_incidents WHERE status = 'Open' AND severity = 'P1' {mf}
                    AND incident_id NOT IN (SELECT incident_id FROM app.live_incidents)) +
                 (SELECT count(*) FROM app.live_incidents WHERE status = 'Open' AND severity = 'P1' {mf}) AS open_p1,
                 coalesce((SELECT sum(homes_impacted) FROM secure.fiber_incidents WHERE status = 'Open' {mf}
                    AND incident_id NOT IN (SELECT incident_id FROM app.live_incidents)), 0) +
                 coalesce((SELECT sum(homes_impacted) FROM app.live_incidents WHERE status = 'Open' {mf}), 0) AS homes_impacted_now,
                 (SELECT count(*) FROM app.live_technicians WHERE status = 'Available' {mf}) AS techs_available,
                 (SELECT count(*) FROM app.live_technicians WHERE status IN ('En route', 'On job') {mf}) AS techs_busy""",
                          {"m": m})[0])

    static["live"] = json.loads(cache.live.get_or_compute(("fiber_kpis_live", m, c.scope_key), load_live))
    return static


@router.get("/fiber/olt/{olt_id}")
def fiber_olt(request: Request, olt_id: str):
    c = ctx(request)

    def load():
        olt = c.qd("SELECT * FROM secure.fiber_olts WHERE olt_id = %s", (olt_id,))
        if not olt:
            return dumps(None)
        hourly = c.qd("""SELECT hour_ts, pon_util_pct, uplink_util_pct, active_onts, alarms, status FROM secure.fiber_olt_hourly
                         WHERE olt_id = %s AND hour_ts >= timestamptz '2026-10-07 06:00:00+00' ORDER BY hour_ts""", (olt_id,))
        inc = c.qd("""SELECT incident_id, incident_type, severity, start_ts, outage_min, status, homes_impacted, root_cause, sla_breached
                      FROM secure.fiber_incidents WHERE olt_id = %s ORDER BY start_ts DESC LIMIT 25""", (olt_id,))
        fdh = c.qd("""SELECT fdh_id, latitude, longitude, health_7d, open_incidents, homes_connected FROM secure.fiber_fdh
                      WHERE olt_id = %s ORDER BY health_7d NULLS LAST LIMIT 60""", (olt_id,))
        return dumps({"olt": olt[0], "hourly": hourly, "incidents": inc, "fdh": fdh})

    return cached(request, cache.entities, ("olt", olt_id, c.scope_key), load, dataset="olts", max_age=300)


@router.get("/fiber/incident/{incident_id}")
def fiber_incident(request: Request, incident_id: str):
    c = ctx(request)
    rows = c.qd(f"SELECT {LIVE_INC_COLS}, true AS live FROM app.live_incidents WHERE incident_id = %s", (incident_id,), write=True) or \
        c.qd("""SELECT incident_id, incident_type, severity, latitude, longitude, homes_impacted, status, start_ts, end_ts, root_cause,
                       metro_code, olt_id, fdh_id, outage_min, sla_breached, age_min, sla_min, false AS live
                FROM secure.fiber_incidents WHERE incident_id = %s""", (incident_id,))
    if not rows:
        raise HTTPException(404, "incident not visible")
    inc = rows[0]
    techs = c.qd("""SELECT technician_id, skill, status, latitude, longitude,
                           round((111.32 * sqrt(power((longitude - %s) * cos(radians(%s)), 2) + power(latitude - %s, 2)))::numeric, 2) AS dist_km
                    FROM app.live_technicians WHERE metro_code = %s AND status = 'Available'
                    ORDER BY power((longitude - %s) * cos(radians(%s)), 2) + power(latitude - %s, 2) LIMIT 5""",
                 (inc["longitude"], inc["latitude"], inc["latitude"], inc["metro_code"], inc["longitude"], inc["latitude"], inc["latitude"]),
                 write=True)
    return {"incident": inc, "nearest_technicians": techs}


class Dispatch(BaseModel):
    incident_id: str
    technician_id: str


@router.post("/fiber/dispatch")
def fiber_dispatch(request: Request, body: Dispatch):
    c = ctx(request)
    # Promote a NOC incident into the live table if needed, then assign. RLS WITH CHECK rejects out-of-scope writes.
    c.q("""INSERT INTO app.live_incidents (incident_id, incident_type, severity, network_level, olt_id, fdh_id, metro_code, region,
                                           locality, latitude, longitude, homes_impacted, start_ts, status, root_cause)
           SELECT incident_id, incident_type, severity, network_level, olt_id, fdh_id, metro_code, region, locality, latitude, longitude,
                  homes_impacted, start_ts, 'Open', root_cause FROM secure.fiber_incidents WHERE incident_id = %s
           ON CONFLICT (incident_id) DO NOTHING""", (body.incident_id,), write=True)
    _, rows = c.q("""WITH i AS (UPDATE app.live_incidents SET assigned_technician = %s, updated_at = now()
                                WHERE incident_id = %s AND status = 'Open' RETURNING latitude, longitude)
                     UPDATE app.live_technicians t SET status = 'En route', assigned_incident = %s, target_lat = i.latitude,
                            target_lon = i.longitude, updated_at = now()
                     FROM i WHERE t.technician_id = %s RETURNING t.technician_id""",
                  (body.technician_id, body.incident_id, body.incident_id, body.technician_id), write=True)
    if not rows:
        raise HTTPException(409, "incident or technician not available in your scope")
    return {"ok": True}


# ---------- Retail ----------

@router.get("/retail/kpis")
def retail_kpis(request: Request, metro: str | None = None):
    c = ctx(request)
    m = _metro(metro)
    w1, wp = (" WHERE metro_code = %s", (m,)) if m else ("", ())
    wa = w1.replace(" WHERE", " AND", 1)

    def load():
        s = c.qd(f"""SELECT count(*) AS stores, sum(revenue_12m) AS revenue_12m, sum(orders_12m) AS orders_12m,
                           sum(revenue_12m * jiomart_share) / nullif(sum(revenue_12m), 0) AS jiomart_share,
                           avg(growth_3m_pct) AS growth_3m_pct,
                           count(*) FILTER (WHERE perf_band = 'Watch') AS watch_stores
                    FROM secure.retail_stores{w1}""", wp)[0]
        mk = c.qd(f"""SELECT sum(customers) AS customers, sum(households) AS households, sum(population) AS population
                    FROM secure.retail_hex_profile WHERE res = 5{wa}""", wp)[0]
        p = c.qd(f"""SELECT count(*) AS plots, count(*) FILTER (WHERE best_score >= 65) AS strong_plots,
                           sum(est_annual_revenue_cr) FILTER (WHERE best_score >= 65) AS strong_plot_rev_cr
                    FROM secure.retail_plots WHERE plot_status <> 'Shortlisted'{wa}""", wp)[0]
        by_region = c.qd(f"""SELECT region, count(*) AS stores, sum(revenue_12m) AS revenue_12m FROM secure.retail_stores{w1}
                            GROUP BY region ORDER BY 3 DESC""", wp)
        by_format = c.qd(f"""SELECT format, count(*) AS stores, sum(revenue_12m) AS revenue_12m FROM secure.retail_stores{w1}
                            GROUP BY format ORDER BY 3 DESC""", wp)
        trend = c.qd(f"""SELECT month, sum(revenue) AS revenue FROM secure.retail_hex_monthly WHERE res = 5{wa}
                         GROUP BY month ORDER BY month""", wp)
        return dumps({**s, **mk, **p, "by_region": by_region, "by_format": by_format, "trend": trend})

    return cached(request, cache.entities, ("retail_kpis", m, c.scope_key), load, dataset="retail_kpis", max_age=300)


@router.get("/retail/store/{code}")
def retail_store(request: Request, code: str):
    c = ctx(request)

    def load():
        st = c.qd("SELECT * FROM secure.retail_stores WHERE store_code = %s", (code,))
        if not st:
            return dumps(None)
        s = st[0]
        monthly = c.qd("""SELECT month, sum(revenue) AS revenue, sum(orders) AS orders, sum(rev_jiomart) AS rev_jiomart
                          FROM secure.retail_store_monthly WHERE store_code = %s GROUP BY month ORDER BY month""", (code,))
        mix = c.qd("""SELECT category, sum(revenue) AS revenue FROM secure.retail_store_monthly WHERE store_code = %s
                      GROUP BY category ORDER BY 2 DESC""", (code,))
        catch = c.qd("""SELECT to_hex(h3) AS h, share_pct, revenue, customers, ring_distance FROM secure.retail_store_catchment
                        WHERE store_code = %s ORDER BY revenue DESC LIMIT 800""", (code,))
        comp = c.qd("""SELECT brand, category_group, count(*) AS n FROM secure.retail_competitors
                       WHERE metro_code = %s AND power((longitude - %s) * cos(radians(%s)), 2) + power(latitude - %s, 2) < power(3 / 111.32, 2)
                       GROUP BY 1, 2 ORDER BY 3 DESC""", (s["metro_code"], s["longitude"], s["latitude"], s["latitude"]))
        peers = c.qd("""SELECT store_code, store_name, revenue_12m, revenue_per_sqft, perf_band FROM secure.retail_stores
                        WHERE metro_code = %s AND format = %s ORDER BY revenue_12m DESC LIMIT 5""", (s["metro_code"], s["format"]))
        cum, p80 = 0.0, 0
        for i, r in enumerate(catch):
            cum += float(r["share_pct"] or 0)
            if cum >= 80 and not p80:
                p80 = i + 1
        return dumps({"store": s, "monthly": monthly, "mix": mix, "catchment": catch, "competitors_3km": comp, "peers": peers,
                      "cells_for_80pct": p80})

    return cached(request, cache.entities, ("store", code, c.scope_key), load, dataset="stores", max_age=300)


@router.get("/retail/plots")
def retail_plots(request: Request, metro: str | None = None, fmt: str | None = None, status: str | None = None,
                 min_score: float = 0, limit: int = 100):
    c = ctx(request)
    where, params = ["best_score >= %s"], [min_score]
    if metro:
        where.append("metro_code = %s"); params.append(metro)
    if fmt:
        where.append("recommended_format = %s"); params.append(fmt)
    if status:
        where.append("plot_status = %s"); params.append(status)
    sql = f"""SELECT plot_id, metro_code, locality, area_sqm, zoning, plot_status, transaction_type, recommended_format, best_score,
                     score_grocery, score_fashion, score_electronics, est_annual_revenue_cr, cannibalisation_risk_pct,
                     households_3km, affluence_3km, centroid_lat, centroid_lon
              FROM secure.retail_plots WHERE {' AND '.join(where)} ORDER BY best_score DESC LIMIT %s"""

    def load():
        return dumps(c.qd(sql, tuple(params) + (min(limit, 500),)))

    return cached(request, cache.entities, ("plots", metro, fmt, status, min_score, limit, c.scope_key), load, dataset="plots", max_age=300)


@router.get("/retail/plot/{plot_id}")
def retail_plot(request: Request, plot_id: str):
    c = ctx(request)
    rows = c.qd("""SELECT p.*, to_hex(h3_r8) AS h3_r8_hex, ST_AsGeoJSON(ST_GeomFromEWKB(geom_ewkb))::json AS geometry FROM secure.retail_plots p
                   WHERE plot_id = %s""", (plot_id,))
    if not rows:
        raise HTTPException(404, "plot not visible")
    r = rows[0]
    r.pop("geom_ewkb", None)
    short = c.qd("SELECT principal, note, created_at FROM app.plot_shortlist WHERE plot_id = %s ORDER BY created_at DESC",
                 (plot_id,), write=True)
    return {"plot": r, "shortlist": short}


class Shortlist(BaseModel):
    plot_id: str
    note: str = ""


@router.post("/retail/shortlist")
def add_shortlist(request: Request, body: Shortlist):
    c = ctx(request)
    _, rows = c.q("""INSERT INTO app.plot_shortlist (plot_id, region, metro_code, note)
                     SELECT plot_id, region, metro_code, %s FROM secure.retail_plots WHERE plot_id = %s
                     ON CONFLICT (plot_id, principal) DO UPDATE SET note = EXCLUDED.note, created_at = now()
                     RETURNING plot_id""", (body.note, body.plot_id), write=True)
    if not rows:
        raise HTTPException(404, "plot not visible")
    return {"ok": True}


@router.get("/retail/shortlist")
def list_shortlist(request: Request):
    c = ctx(request)
    return c.qd("""SELECT s.plot_id, s.principal, s.note, s.created_at, p.locality, p.metro_code, p.best_score, p.recommended_format,
                          p.est_annual_revenue_cr, p.centroid_lat, p.centroid_lon
                   FROM app.plot_shortlist s JOIN secure.retail_plots p USING (plot_id) ORDER BY s.created_at DESC LIMIT 200""",
                write=True)


# ---------- saved maps ----------

class SavedMap(BaseModel):
    solution: str
    name: str
    config: dict
    shared: bool = True


@router.get("/maps")
def list_maps(request: Request, solution: str):
    c = ctx(request)
    return c.qd("""SELECT map_id, owner, name, shared, created_at FROM app.saved_maps WHERE solution = %s
                   ORDER BY created_at DESC LIMIT 50""", (solution,), write=True)


@router.post("/maps")
def save_map(request: Request, body: SavedMap):
    c = ctx(request)
    _, rows = c.q("INSERT INTO app.saved_maps (solution, name, config, shared) VALUES (%s, %s, %s::jsonb, %s) RETURNING map_id",
                  (body.solution, body.name[:120], json.dumps(body.config), body.shared), write=True)
    return {"map_id": str(rows[0][0])}


@router.get("/maps/{map_id}")
def get_map(request: Request, map_id: str):
    c = ctx(request)
    rows = c.qd("SELECT map_id, owner, solution, name, config, shared FROM app.saved_maps WHERE map_id = %s::uuid", (map_id,), write=True)
    if not rows:
        raise HTTPException(404, "map not found")
    return rows[0]


@router.get("/health")
def health():
    from .simulator import simulator
    return {"ok": True, "is_app": config.IS_APP, "versions": realtime.versions.all(), "cache": cache.stats(),
            "pools": {"ro": db.ro_pool.stats(), "rw": db.rw_pool.stats()}, "sse_clients": len(realtime.hub.subscribers),
            "events_sent": realtime.hub.events_sent, "simulator_leader": simulator.leader, "ticks": simulator.ticks,
            "server_ms": metrics.summary()}


# ---------- realtime push (SSE) ----------

@router.get("/stream")
async def stream(request: Request):
    principal = request.headers.get("x-forwarded-email") if config.IS_APP else config.LOCAL_USER
    if not principal:
        raise HTTPException(401, "No authenticated user")
    q = realtime.hub.subscribe()

    async def gen():
        try:
            # 2 KB comment first: pushes intermediary proxy buffers to flush so events arrive immediately
            yield ":" + " " * 2048 + "\n\n"
            yield f"event: hello\ndata: {json.dumps({'versions': realtime.versions.all()})}\n\n"
            while True:
                if await request.is_disconnected():
                    break
                try:
                    ev = await asyncio.wait_for(q.get(), timeout=15)
                except asyncio.TimeoutError:
                    yield ": keep-alive\n\n"
                    continue
                if ev.get("kind") == "heartbeat":
                    continue
                yield f"event: {ev['kind']}\ndata: {json.dumps(ev, default=str)}\n\n"
        finally:
            realtime.hub.unsubscribe(q)

    return StreamingResponse(gen(), media_type="text/event-stream",
                             headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"})


# ---------- agent ----------

class AgentRequest(BaseModel):
    question: str
    solution: str
    state: dict = {}
    history: list = []


@router.post("/agent")
def ask_agent(request: Request, body: AgentRequest):
    c = ctx(request)
    try:
        return agent.run(body.question[:1000], body.solution, body.state, c, body.history)
    except Exception as e:
        raise HTTPException(502, f"agent failed: {str(e)[:300]}")
