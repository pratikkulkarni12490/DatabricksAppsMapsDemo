# GeoLens: spatial network and retail intelligence on Databricks

GeoLens is a location-intelligence accelerator built entirely on the Databricks Data Intelligence Platform. It renders H3 hexagon maps, live operational points and vector tiles in the browser, served from **Lakebase** (managed Postgres with PostGIS) in milliseconds, governed by **Unity Catalog**, and hosted as a **Databricks App**.

It ships with two solutions on synthetic data for eight Indian metros:

* **Jio Fiber Network Control Center**: network health hexagons, live incidents (P1s glow until fixed), field technicians and dispatch, OLT and FDH capacity, fiber routes, growth and cross-sell layers.
* **Retail Intelligence**: customer demand, white space, stores, competitors and candidate plots.

See `docs/fiber/GeoLens_Jio_Fiber_Solution_Overview.pdf` for the full solution story and `docs/fiber/GeoLens_Jio_Fiber_Walkthrough.mp4` for a 3 minute walkthrough.

## Architecture

```
Sources ─▶ Delta Lake (bronze/silver/gold, Unity Catalog row filters)
        ─▶ Synced tables ─▶ Lakebase Postgres (PostGIS, RLS views, live tables, change notifications, read replica)
        ─▶ Databricks App (FastAPI API + SSE push, React + deck.gl + MapLibre UI, AI assistant on Foundation Model APIs)
```

Details: `docs/ARCHITECTURE.md`.

## Repository layout

| Path | Contents |
|---|---|
| `sql/01_*.sql` to `sql/08_*.sql` | Unity Catalog build: reference data, synthetic sources, silver, gold, access control (row filters), serving copies |
| `sql/pg_*.sql` | Lakebase setup: indexes, scope functions, secure RLS views, app tables, realtime triggers, grants, performance policies |
| `scripts/` | Helpers: run SQL on a warehouse, run SQL on Lakebase, create and refresh synced tables, seed the layer catalog, deploy the app, smoke and RLS tests, scripted browser walkthroughs |
| `app/` | The Databricks App: `app.py`, `app.yaml`, `backend/` (FastAPI) and `src/` (React) |
| `loadtest/` | HTTP/2 load test runnable as a Databricks job |
| `docs/` | Architecture notes, solution overview PDF and HTML, screenshots, walkthrough video |

## Prerequisites

* A Databricks workspace with Unity Catalog, serverless SQL, Lakebase and Databricks Apps enabled.
* Databricks CLI 0.292 or later, authenticated to the workspace (`databricks auth login --profile <profile>`).
* Python 3.11+ with `databricks-sdk`, `psycopg2-binary` and `requests` for the helper scripts.
* Node.js only if you want to run the browser walkthrough scripts locally (the app itself is built on Databricks Apps compute).

## Configuration

Set these once in your shell before running the scripts:

| Variable | Used by | Meaning |
|---|---|---|
| `DATABRICKS_PROFILE` | all scripts | CLI profile for your workspace (default `DEFAULT`) |
| `WAREHOUSE_ID` | `scripts/run_sql.py` | Serverless SQL warehouse ID |
| `CATALOG` | SQL and sync scripts | Unity Catalog catalog to create and use (default `geolens_demo`) |
| `PRESENTER_EMAIL` | `sql/07_access.sql`, tests | Your Databricks login; gets National scope and the persona switcher |
| `PG_PRIMARY_HOST`, `PG_REPLICA_HOST` | `scripts/pg.py` | Lakebase primary and read-replica endpoint hosts |
| `APP_SP_CLIENT_ID` | `sql/pg_03_grants.sql`, `sql/pg_04_signatures.sql` | The app service principal's client ID (shown by `databricks apps get geolens`) |
| `WORKSPACE_PATH` | `scripts/deploy-app.sh` | Workspace folder for the app source, e.g. `/Workspace/Users/<you>/geolens` |

In `app/app.yaml`, replace `<lakebase-primary-endpoint-host>`, `<lakebase-replica-endpoint-host>` and `<databricks-workspace-id>`, and set `UC_CATALOG` if you changed the catalog name. Add a serving endpoint resource named `llm` (for example a Claude model on Foundation Model APIs) to the app.

## Setup

1. **Build the lakehouse data** (serverless SQL; creates the catalog, synthetic data, gold tables and row filters):
   ```bash
   for f in sql/0[1-8]_*.sql; do python3 scripts/run_sql.py "$f"; done
   ```
   `sql/07_access.sql` seeds the entitlements table. Re-running it with `--from 3` keeps existing entitlements.
2. **Create Lakebase**: a Lakebase project (PostgreSQL 17) with a production branch, a read-write endpoint and one read-only replica. Note both endpoint hosts.
3. **Sync gold into Lakebase**:
   ```bash
   python3 scripts/create_synced_tables.py
   ```
4. **Create and start the app**, then note its service principal client ID:
   ```bash
   databricks apps create geolens
   databricks apps get geolens   # service_principal_client_id
   ```
5. **Set up Lakebase objects** (indexes, RLS views, app tables, realtime, grants):
   ```bash
   for f in sql/pg_0[1-5]_*.sql; do python3 scripts/pg.py -f "$f"; done
   python3 scripts/seed_catalog.py
   ```
6. **Deploy the app**:
   ```bash
   ./scripts/deploy-app.sh
   ```
   The first deployment installs the frontend dependencies and builds the UI on Databricks Apps compute.
7. **Grant access**: give users `CAN_USE` on the app and add a row for each in `<catalog>.access.user_region_scope` (NATIONAL, REGION or METRO). Refresh the scope sync with `python3 scripts/refresh_sync.py user_region_scope`.

## Testing

* `python3 scripts/smoke_api.py <app-url> <token>`: calls every API route.
* `python3 scripts/test_rls.py`: checks row-level security per persona in Lakebase.
* `node scripts/story.mjs <steps.json> <token> <outDir>`: scripted browser walkthrough with screenshots; set `VIDEO=<dir>` to record.
* `loadtest/geolens_load_h2.py`: HTTP/2 load test; run it as a serverless Databricks job in the same region as the app.

## Live data and freshness

* A built-in simulator (enabled with `SIMULATOR_ENABLED=true`) raises incidents, dispatches and moves technicians and resolves incidents. In production these tables are fed by NMS, OSS and workforce systems.
* Synced-table refreshes are detected automatically. `python3 scripts/refresh_sync.py <table>` triggers one, and every open map refetches only the affected layers, with no reload.

## Basemap note

The current build loads the Dark Matter and Positron basemap styles from CARTO's public basemap CDN; no CARTO account, key or SDK is used. Appendix D of the solution overview describes how to replace it with an OpenStreetMap basemap self-hosted inside Databricks.

## Data

All data is synthetic and generated by the SQL in `sql/`. It contains no customer information.
