import json
import os
import subprocess
from functools import lru_cache

from databricks.sdk import WorkspaceClient

IS_APP = bool(os.environ.get("DATABRICKS_APP_NAME"))

PROJECT_BRANCH = os.environ.get("LAKEBASE_BRANCH", "projects/geo-retail-serving/branches/production")
RW_ENDPOINT = f"{PROJECT_BRANCH}/endpoints/{os.environ.get('LAKEBASE_RW_ENDPOINT_ID', 'primary')}"
RO_ENDPOINT = f"{PROJECT_BRANCH}/endpoints/{os.environ.get('LAKEBASE_RO_ENDPOINT_ID', 'replica-1')}"
PG_RW_HOST = os.environ.get("PG_RW_HOST", "")
PG_RW_DIRECT_HOST = os.environ.get("PG_RW_DIRECT_HOST", "")
PG_RO_HOST = os.environ.get("PG_RO_HOST", "")
PG_DATABASE = os.environ.get("PGDATABASE", "databricks_postgres")
LLM_ENDPOINT = os.environ.get("LLM_ENDPOINT", "databricks-claude-sonnet-5-5")
WORKSPACE_ID = os.environ.get("DATABRICKS_WORKSPACE_ID", "")
GENIE_SPACE_RETAIL = os.environ.get("GENIE_SPACE_RETAIL", "")
GENIE_SPACE_FIBER = os.environ.get("GENIE_SPACE_FIBER", "")
LOCAL_USER = os.environ.get("LOCAL_USER", "")
UC_CATALOG = os.environ.get("UC_CATALOG", "geolens_demo")  # Unity Catalog catalog holding the serving and synced tables
SIMULATOR_ENABLED = os.environ.get("SIMULATOR_ENABLED", "true").lower() == "true"
SIMULATOR_PRINCIPAL = "system:simulator"


@lru_cache(maxsize=1)
def _local_client() -> WorkspaceClient:
    # The SDK's databricks-cli auth can't disambiguate two profiles on one host, so mint a token via the CLI
    env = {**os.environ, "DATABRICKS_AUTH_STORAGE": "plaintext"}
    profile = os.environ.get("DATABRICKS_PROFILE", "DEFAULT")
    tok = json.loads(subprocess.run(["databricks", "auth", "token", "--profile", profile], capture_output=True, text=True,
                                    check=True, env=env).stdout)["access_token"]
    host = json.loads(subprocess.run(["databricks", "auth", "env", "--profile", profile], capture_output=True, text=True,
                                     check=True, env=env).stdout)["env"]["DATABRICKS_HOST"]
    return WorkspaceClient(host=host, token=tok, auth_type="pat")


@lru_cache(maxsize=1)
def _app_client() -> WorkspaceClient:
    return WorkspaceClient()


def workspace_client() -> WorkspaceClient:
    return _app_client() if IS_APP else _local_client()


def workspace_host() -> str:
    host = workspace_client().config.host or ""
    return host if host.startswith("http") else f"https://{host}"


def pg_user() -> str:
    # In Databricks Apps the service principal's client id is its Postgres role name
    return os.environ["DATABRICKS_CLIENT_ID"] if IS_APP else LOCAL_USER


def bearer_token() -> str:
    headers = workspace_client().config.authenticate()
    return headers["Authorization"].removeprefix("Bearer ")
