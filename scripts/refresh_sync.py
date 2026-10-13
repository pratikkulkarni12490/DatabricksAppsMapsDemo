"""Trigger Lakebase synced-table refreshes (serving.* -> geo.*). Usage: python3 scripts/refresh_sync.py [table ...] (default all).
The app's leader notices the new synced Delta version within ~30 s, bumps app.dataset_version, and every open map refetches
only the affected layers over SSE: no reload needed."""
import json
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(__file__))
from create_synced_tables import CATALOG, TABLES  # noqa: E402

ENV = {**os.environ, "DATABRICKS_AUTH_STORAGE": "plaintext"}


def cli(*args):
    r = subprocess.run(["databricks", *args, "--profile", "DEFAULT", "-o", "json"], capture_output=True, text=True, env=ENV)
    return json.loads(r.stdout) if r.returncode == 0 and r.stdout.strip() else {"error": r.stderr.strip()[:200]}


for t in sys.argv[1:] or list(TABLES):
    st = cli("postgres", "get-synced-table", f"synced_tables/{CATALOG}.geo.{t}")
    pid = st.get("status", {}).get("pipeline_id")
    if not pid:
        print(t, "no pipeline", st.get("error", ""))
        continue
    r = cli("pipelines", "start-update", pid)
    print(t, "->", r.get("update_id") or r.get("error"))
