"""Local Lakebase helper: python3 scripts/pg.py "SQL" [--replica] | python3 scripts/pg.py -f file.sql"""
import json
import os
import subprocess
import sys

import psycopg2

PROFILE = os.environ.get("DATABRICKS_PROFILE", "DEFAULT")
BRANCH = "projects/geo-retail-serving/branches/production"
HOSTS = {
    "primary": os.environ.get("PG_PRIMARY_HOST", ""),
    "replica": os.environ.get("PG_REPLICA_HOST", ""),
}
ENV = {**os.environ, "DATABRICKS_AUTH_STORAGE": "plaintext"}


def connect(which: str = "primary"):
    ep = f"{BRANCH}/endpoints/{'primary' if which == 'primary' else 'replica-1'}"
    out = subprocess.run(["databricks", "postgres", "generate-database-credential", ep, "--profile", PROFILE, "-o", "json"],
                         capture_output=True, text=True, check=True, env=ENV)
    token = json.loads(out.stdout)["token"]
    user = json.loads(subprocess.run(["databricks", "current-user", "me", "--profile", PROFILE, "-o", "json"],
                                     capture_output=True, text=True, check=True, env=ENV).stdout)["userName"]
    return psycopg2.connect(host=HOSTS[which], dbname="databricks_postgres", user=user, password=token, sslmode="require",
                            connect_timeout=15)


def run(conn, sql: str):
    with conn.cursor() as cur:
        cur.execute(sql)
        if cur.description:
            cols = [d[0] for d in cur.description]
            print(" | ".join(cols))
            for r in cur.fetchmany(50):
                print(" | ".join(str(x) for x in r))
    conn.commit()


if __name__ == "__main__":
    which = "replica" if "--replica" in sys.argv else "primary"
    conn = connect(which)
    if sys.argv[1] == "-f":
        run(conn, open(sys.argv[2]).read().replace("${app_sp_client_id}", os.environ.get("APP_SP_CLIENT_ID", "")))
    else:
        run(conn, sys.argv[1])
