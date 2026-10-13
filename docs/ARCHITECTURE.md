# GeoLens: CARTO-style spatial intelligence on Databricks

Two solution views on one geospatial engine:
- **Retail Intelligence** (Reliance Retail): demand hexes, store 360, catchments, white space, competitor overlay, site selection on candidate plots.
- **Jio Fiber Control Center** (Jio Fiber Home): network health by H3, live incidents, field force, OLT capacity, coverage and cross-sell.

App: deployed as a Databricks App named `geolens` (see README for setup)

## Data flow

```
ref + bronze (synthetic sources: lat/lon, WKT)
  -> silver (H3 res 7-9 via h3_longlatash3, GEOMETRY(4326) via ST_*; 70M orders, 5.9M subscribers, 4.4M hex-days, 4.2M OLT-hours)
  -> gold (H3 rollups res 5-9 with tile keys; KPIs, catchments, plot scores, OLT capacity)   [UC row filter access.can_see]
  -> serving (CDF on; GEOMETRY exported as EWKB)                                              [owner-only]
  -> Lakebase synced tables geo.* (Postgres 17 + PostGIS, primary + read replica)
       secure.* security_barrier views  = row-level security over synced tables
       app.*   native tables with ENABLE + FORCE ROW LEVEL SECURITY (saved maps, shortlist, live incidents, technicians)
  -> Databricks App (FastAPI + React/deck.gl/MapLibre)
```

## Why it is fast

| Technique | Where |
|---|---|
| Hexagons are drawn in the browser (deck.gl `H3HexagonLayer`); the API sends only `[h3_hex, value]` | `api.py /api/h3`, `layers.js` |
| Tiles = H3 parent at `res - 3` (max 343 hexes); identical across users, so cacheable and shareable | `tiles.js`, gold `tile_h3` |
| B-tree `(res, tile_h3, time)` index; scope resolved once per query via InitPlan | `pg_01_setup.sql` |
| Scope-keyed TTL cache with single-flight (1 DB query per tile per scope per instance) + ETag/304 + gzip | `cache.py`, `api.py cached()` |
| Plots and fiber routes as PostGIS vector tiles (`ST_AsMVT`) | `/api/mvt` |
| Double-buffered tile swaps + colour transitions (no flicker on pan/zoom or data change) | `App.jsx` |

Measured server-side (Server-Timing): H3 tile p50 15-17 ms, p95 40-51 ms on cache misses; cache hits sub-millisecond.

## Seamless updates

- `app.*` writes fire statement-level triggers -> `pg_notify('geolens')`.
- Every app instance holds one `LISTEN` connection and fans out over SSE (`/api/stream`); browsers fetch only the delta, RLS-scoped.
- The leader instance (Postgres advisory lock) watches `app.synced_table_signatures()` (relfilenode + size per geo table): when a
  Delta -> Lakebase sync lands it bumps `app.dataset_version`, whose trigger NOTIFYs; only the affected layers refetch.
- Pipeline refresh: `scripts/refresh_sync.py` (or a Lakeflow job) after the gold/serving rebuild.

## Entitlements (one source of truth)

`<catalog>.access.user_region_scope` (UC Delta table; NATIONAL / REGION / METRO rows per principal)
- UC: row filter `access.can_see(region, metro_code)` on all 17 gold tables (Genie, SQL, dashboards).
- Lakebase: synced to `geo.user_region_scope`; `secure.*` views and `app.*` RLS policies use `app.effective_principal()`.
- App role (service principal) has SELECT on `secure.*` only, no access to `geo.*`, no BYPASSRLS.
- Demo personas: a NATIONAL presenter may impersonate `is_demo_persona` principals; enforced inside Postgres.

## Scale envelope

- Databricks Apps: 1-5 instances per app behind one URL (Medium/Large/XLarge), stateless (all state in Lakebase).
- Lakebase: autoscaling primary + read replicas (shared storage); add replicas for read throughput.
- Users need workspace identities (SCIM from Entra ID) to sign in.

## Rebuild

```bash
python3 scripts/run_sql.py sql/01_setup_ref.sql      # ... through 08_serving.sql (07 after gold: row filters)
python3 scripts/create_synced_tables.py              # first time; later: scripts/refresh_sync.py
python3 scripts/pg.py -f sql/pg_01_setup.sql         # + pg_02_realtime, pg_03_grants, pg_04_signatures
python3 scripts/seed_catalog.py
./scripts/deploy-app.sh
```
