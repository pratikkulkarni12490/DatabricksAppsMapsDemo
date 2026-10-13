#!/usr/bin/env bash
# Sync app source to the workspace and deploy the geolens Databricks App (set DATABRICKS_PROFILE and WORKSPACE_PATH).
set -euo pipefail
export DATABRICKS_AUTH_STORAGE=plaintext
WS=${WORKSPACE_PATH:?set WORKSPACE_PATH, e.g. /Workspace/Users/<you>/geolens}
cd "$(dirname "$0")/../app"
databricks sync . "$WS" --profile "${DATABRICKS_PROFILE:-DEFAULT}" --exclude node_modules --exclude dist --exclude __pycache__ | tail -1
databricks apps deploy geolens --source-code-path "$WS" --profile "${DATABRICKS_PROFILE:-DEFAULT}" -o json | python3 -c "import json,sys;print(json.load(sys.stdin).get('status'))"
