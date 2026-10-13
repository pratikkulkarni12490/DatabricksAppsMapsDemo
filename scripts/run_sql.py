"""Run a .sql file statement-by-statement on a Databricks SQL warehouse.

Usage: python3 scripts/run_sql.py sql/01_setup.sql [--from N]
Statements are separated by a line ending in ';'. ${catalog} and ${presenter_email} are substituted
(env CATALOG, PRESENTER_EMAIL; WAREHOUSE_ID must be set).
"""
import json
import os
import re
import subprocess
import sys
import time

os.environ.setdefault("DATABRICKS_AUTH_STORAGE", "plaintext")
from databricks.sdk import WorkspaceClient
from databricks.sdk.service.sql import StatementState

PROFILE = os.environ.get("DATABRICKS_PROFILE", "DEFAULT")
WAREHOUSE_ID = os.environ.get("WAREHOUSE_ID", "")
CATALOG = os.environ.get("CATALOG", "geolens_demo")

def _client() -> WorkspaceClient:
    # SDK's databricks-cli auth can't disambiguate two profiles on one host, so mint the token via CLI
    out = subprocess.run(["databricks", "auth", "token", "--profile", PROFILE], capture_output=True, text=True, check=True)
    tok = json.loads(out.stdout)["access_token"]
    host = subprocess.run(["databricks", "auth", "env", "--profile", PROFILE], capture_output=True, text=True, check=True)
    host = json.loads(host.stdout)["env"]["DATABRICKS_HOST"]
    return WorkspaceClient(host=host, token=tok, auth_type="pat")


w = _client()


def split_statements(text: str) -> list[str]:
    text = "\n".join(l for l in text.splitlines() if not l.strip().startswith("--"))
    parts = re.split(r";\s*\n", text + "\n")
    return [p.strip() for p in parts if p.strip()]


def run(stmt: str, show_rows: int = 20):
    resp = w.statement_execution.execute_statement(
        warehouse_id=WAREHOUSE_ID, statement=stmt, wait_timeout="30s"
    )
    sid = resp.statement_id
    while resp.status.state in (StatementState.PENDING, StatementState.RUNNING):
        time.sleep(3)
        resp = w.statement_execution.get_statement(sid)
    if resp.status.state != StatementState.SUCCEEDED:
        raise RuntimeError(f"{resp.status.state}: {resp.status.error.message if resp.status.error else ''}")
    if resp.result and resp.result.data_array:
        cols = [c.name for c in resp.manifest.schema.columns]
        print("   ", " | ".join(cols))
        for r in resp.result.data_array[:show_rows]:
            print("   ", " | ".join(str(x) for x in r))
    return resp


if __name__ == "__main__":
    path = sys.argv[1]
    start = int(sys.argv[sys.argv.index("--from") + 1]) if "--from" in sys.argv else 1
    stmts = split_statements(open(path).read().replace("${catalog}", CATALOG).replace("${presenter_email}", os.environ.get("PRESENTER_EMAIL", "presenter@example.com")))
    for i, s in enumerate(stmts, 1):
        if i < start:
            continue
        head = " ".join(s.split())[:110]
        t0 = time.time()
        print(f"[{i}/{len(stmts)}] {head}", flush=True)
        try:
            run(s)
        except Exception as e:
            print(f"  FAILED at statement {i}: {e}")
            sys.exit(1)
        print(f"  ok {time.time() - t0:.0f}s", flush=True)
