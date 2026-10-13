"""Create Lakebase synced tables (serving.* Delta -> Postgres schema "geo") on projects/geo-retail-serving.

Usage: python3 scripts/create_synced_tables.py [table ...]   (default: all)
SNAPSHOT mode: each refresh is a full copy, which is robust to CREATE OR REPLACE of the serving tables.
"""
import json
import os
import subprocess
import sys

CATALOG = os.environ.get("CATALOG", "geolens_demo")
BRANCH = "projects/geo-retail-serving/branches/production"
ENV = {**os.environ, "DATABRICKS_AUTH_STORAGE": "plaintext"}

TABLES = {
    "retail_hex_monthly": ["h3", "month"],
    "retail_hex_profile": ["h3"],
    "retail_stores": ["store_code"],
    "retail_store_monthly": ["store_code", "month", "category"],
    "retail_store_catchment": ["store_code", "h3"],
    "retail_competitors": ["outlet_id"],
    "retail_plots": ["plot_id"],
    "fiber_hex_daily": ["h3", "day"],
    "fiber_hex_profile": ["h3"],
    "fiber_olts": ["olt_id"],
    "fiber_olt_hourly": ["olt_id", "hour_ts"],
    "fiber_fdh": ["fdh_id"],
    "fiber_incidents": ["incident_id"],
    "fiber_kpi_daily": ["metro_code", "day"],
    "fiber_technicians": ["technician_id"],
    "fiber_routes": ["route_id"],
    "fiber_open_tickets": ["ticket_id"],
    "user_region_scope": ["principal", "scope_level", "scope_value"],
}


def cli(*args):
    return subprocess.run(["databricks", *args, "--profile", "DEFAULT", "-o", "json"], capture_output=True, text=True, env=ENV)


if __name__ == "__main__":
    wanted = sys.argv[1:] or list(TABLES)
    for t in wanted:
        spec = {
            "spec": {
                "source_table_full_name": f"{CATALOG}.serving.{t}",
                "branch": BRANCH,
                "postgres_database": "databricks_postgres",
                "primary_key_columns": TABLES[t],
                "scheduling_policy": "SNAPSHOT",
                "create_database_objects_if_missing": True,
                "new_pipeline_spec": {"storage_catalog": CATALOG, "storage_schema": "serving"},
            }
        }
        r = cli("postgres", "create-synced-table", f"{CATALOG}.geo.{t}", "--json", json.dumps(spec), "--no-wait")
        msg = r.stdout.strip() or r.stderr.strip()
        print(t, "->", "submitted" if r.returncode == 0 else msg[:300])
