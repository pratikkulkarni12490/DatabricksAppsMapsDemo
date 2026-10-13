"""'Ask the map' agent: Foundation Model (via AI Gateway) with whitelisted, scope-enforced tools over Lakebase.
It answers in text and returns map actions (add layers, change metric, fly to, highlight cells, select entities)."""
import json
import logging

import requests

from . import config
from .datasets import CATALOG, H3_DATASETS, METROS

log = logging.getLogger("geolens.agent")

ENTITY_SQL = {
    "stores": ("secure.retail_stores", "store_code AS id, store_name AS name, format, metro_code, locality, revenue_12m, growth_3m_pct, perf_band, revenue_per_sqft, latitude, longitude",
               {"revenue_12m", "growth_3m_pct", "revenue_per_sqft", "perf_index", "jiomart_share"}),
    "plots": ("secure.retail_plots", "plot_id AS id, locality AS name, metro_code, recommended_format, best_score, est_annual_revenue_cr, cannibalisation_risk_pct, area_sqm, plot_status, centroid_lat AS latitude, centroid_lon AS longitude",
              {"best_score", "score_grocery", "score_fashion", "score_electronics", "est_annual_revenue_cr", "households_3km"}),
    "olts": ("secure.fiber_olts", "olt_id AS id, olt_name AS name, metro_code, pon_fill_pct, capacity_status, current_status, health_7d, open_incidents, homes_connected, peak_util_7d, latitude, longitude",
             {"pon_fill_pct", "health_7d", "open_incidents", "peak_util_7d", "homes_impacted_now", "tickets_7d", "incidents_30d"}),
    "incidents": ("secure.fiber_incidents", "incident_id AS id, incident_type AS name, severity, status, metro_code, locality, homes_impacted, outage_min, root_cause, sla_breached, latitude, longitude",
                  {"homes_impacted", "outage_min", "start_ts"}),
}

TOOLS = [
    {"type": "function", "function": {
        "name": "top_cells",
        "description": "Top or bottom H3 cells for a dataset metric (aggregated over the default period), optionally within one metro. Returns hex ids and values.",
        "parameters": {"type": "object", "properties": {
            "dataset": {"type": "string", "enum": list(H3_DATASETS)},
            "metric": {"type": "string"},
            "metro": {"type": "string", "enum": [m["code"] for m in METROS]},
            "res": {"type": "integer", "enum": [7, 8]},
            "order": {"type": "string", "enum": ["desc", "asc"]},
            "n": {"type": "integer", "minimum": 1, "maximum": 20}},
            "required": ["dataset", "metric"]}}},
    {"type": "function", "function": {
        "name": "top_entities",
        "description": "Rank stores, candidate plots, OLTs or incidents by a numeric column, optionally filtered by metro and a text column value.",
        "parameters": {"type": "object", "properties": {
            "entity": {"type": "string", "enum": list(ENTITY_SQL)},
            "sort_by": {"type": "string"},
            "order": {"type": "string", "enum": ["desc", "asc"]},
            "metro": {"type": "string", "enum": [m["code"] for m in METROS]},
            "filter_column": {"type": "string", "enum": ["format", "recommended_format", "capacity_status", "current_status", "severity", "status", "incident_type", "perf_band"]},
            "filter_value": {"type": "string"},
            "n": {"type": "integer", "minimum": 1, "maximum": 20}},
            "required": ["entity", "sort_by"]}}},
    {"type": "function", "function": {
        "name": "respond",
        "description": "Final answer. Always call this last. 'answer' is 2-5 sentences for an executive, with specific numbers. 'actions' update the map.",
        "parameters": {"type": "object", "properties": {
            "answer": {"type": "string"},
            "actions": {"type": "array", "items": {"type": "object", "properties": {
                "type": {"type": "string", "enum": ["add_layer", "remove_layer", "set_metric", "fly_to", "highlight_cells", "select_entity"]},
                "layer_key": {"type": "string"}, "metric": {"type": "string"}, "metro": {"type": "string"},
                "lat": {"type": "number"}, "lon": {"type": "number"}, "zoom": {"type": "number"},
                "h3": {"type": "array", "items": {"type": "string"}},
                "entity": {"type": "string", "enum": ["store", "plot", "olt", "incident"]}, "id": {"type": "string"}},
                "required": ["type"]}}},
            "required": ["answer", "actions"]}}},
]


def _system_prompt(solution: str, state: dict) -> str:
    cat = [{"layer_key": c["layer_key"], "title": c["title"], "kind": c["kind"], "dataset": c["dataset"], "default_metric": c["default_metric"]}
           for c in CATALOG if c["solution"] == solution]
    metrics = {k: {mk: mv["label"] for mk, mv in v["metrics"].items()} for k, v in H3_DATASETS.items()}
    persona = "Reliance Retail store-network and expansion team" if solution == "retail" else "Jio Fiber Home network operations centre (NOC)"
    return f"""You are GeoLens, a geospatial analyst for the {persona}. You control an interactive H3 map.
Data is synthetic demo data for 8 Indian metros; retail covers Oct 2025 to Sep 2026, fiber covers 2026-09-10 to 2026-10-10.
The user only sees regions their entitlements allow; tools are already scope-filtered, never speculate about hidden regions.
Metros: {json.dumps([{k: m[k] for k in ('code', 'name', 'region')} for m in METROS])}
Layer catalog (use layer_key in actions): {json.dumps(cat)}
H3 metrics per dataset: {json.dumps(metrics)}
Current map state: {json.dumps(state)[:1500]}
Rules: if state.focus_metro is set, the user is looking at that metro only: always pass it as metro to tools and talk only about it.
Use tools to get facts before answering; cite numbers (INR in crore/lakh, % to 1 dp); prefer adding the most relevant
layer with set metric, fly_to the metro, and highlight_cells / select_entity for the top results. Finish with the respond tool."""


def _run_tool(name: str, args: dict, ctx) -> dict:
    if name == "top_cells":
        ds = H3_DATASETS.get(args.get("dataset"))
        metric = (ds or {}).get("metrics", {}).get(args.get("metric"))
        if not metric:
            return {"error": "unknown dataset/metric"}
        where, params = ["res = %s"], [int(args.get("res") or 8)]
        if args.get("metro"):
            where.append("metro_code = %s"); params.append(args["metro"])
        if ds["time"] == "day":
            where.append("day >= '2026-10-03'")
        order = "ASC" if args.get("order") == "asc" else "DESC"
        n = min(int(args.get("n") or 8), 20)
        rows = ctx.qd(f"""SELECT to_hex(h3) AS h3, max(metro_code) AS metro, ({metric['expr']})::float8 AS value
                         FROM {ds['view']} WHERE {' AND '.join(where)} GROUP BY h3
                         HAVING ({metric['expr']}) IS NOT NULL ORDER BY 3 {order} LIMIT {n}""", tuple(params))
        return {"metric": metric["label"], "unit": metric["unit"], "cells": rows}
    if name == "top_entities":
        spec = ENTITY_SQL.get(args.get("entity"))
        if not spec:
            return {"error": "unknown entity"}
        view, cols, sortable = spec
        sort = args.get("sort_by") if args.get("sort_by") in sortable else sorted(sortable)[0]
        where, params = ["true"], []
        if args.get("metro"):
            where.append("metro_code = %s"); params.append(args["metro"])
        fc = args.get("filter_column")
        if fc and args.get("filter_value") and fc in cols:
            where.append(f"{fc} = %s"); params.append(args["filter_value"])
        if args.get("entity") == "incidents":
            where.append("status = 'Open'")
        order = "ASC" if args.get("order") == "asc" else "DESC"
        n = min(int(args.get("n") or 8), 20)
        return {"rows": ctx.qd(f"SELECT {cols} FROM {view} WHERE {' AND '.join(where)} ORDER BY {sort} {order} NULLS LAST LIMIT {n}",
                               tuple(params))}
    return {"error": f"unknown tool {name}"}


def _chat(messages: list) -> dict:
    token = config.bearer_token()
    body = {"model": config.LLM_ENDPOINT, "messages": messages, "tools": TOOLS, "max_tokens": 1500}
    urls = [f"https://{config.WORKSPACE_ID}.ai-gateway.cloud.databricks.com/mlflow/v1/chat/completions",
            f"{config.workspace_host()}/serving-endpoints/chat/completions"]
    last_err = None
    for url in urls:
        try:
            r = requests.post(url, json=body, headers={"Authorization": f"Bearer {token}"}, timeout=90)
            if r.status_code == 200:
                return r.json()["choices"][0]["message"]
            last_err = f"{url} -> {r.status_code} {r.text[:300]}"
        except requests.RequestException as e:
            last_err = f"{url} -> {e}"
        log.warning("LLM call failed: %s", last_err)
    raise RuntimeError(last_err)


def run(question: str, solution: str, state: dict, ctx, history: list | None = None) -> dict:
    messages = [{"role": "system", "content": _system_prompt(solution, state)}]
    for h in (history or [])[-6:]:
        if h.get("role") in ("user", "assistant") and h.get("content"):
            messages.append({"role": h["role"], "content": str(h["content"])[:2000]})
    messages.append({"role": "user", "content": question})
    trace = []
    for _ in range(6):
        msg = _chat(messages)
        calls = msg.get("tool_calls") or []
        if not calls:
            return {"answer": msg.get("content") or "", "actions": [], "trace": trace}
        messages.append({"role": "assistant", "content": msg.get("content") or "", "tool_calls": calls})
        for call in calls:
            fn = call.get("function", {})
            try:
                args = json.loads(fn.get("arguments") or "{}")
            except ValueError:
                args = {}
            if fn.get("name") == "respond":
                return {"answer": args.get("answer", ""), "actions": args.get("actions", []), "trace": trace}
            try:
                result = _run_tool(fn.get("name"), args, ctx)
            except Exception as e:
                result = {"error": str(e)[:300]}
            trace.append({"tool": fn.get("name"), "args": args})
            messages.append({"role": "tool", "tool_call_id": call.get("id"), "content": json.dumps(result, default=str)[:6000]})
    return {"answer": "I couldn't complete that analysis; try narrowing to one metro.", "actions": [], "trace": trace}
