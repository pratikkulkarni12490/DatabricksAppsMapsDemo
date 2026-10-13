"""Seed app.layer_catalog in Lakebase from backend/datasets.py CATALOG (the Data Catalog panel reads it)."""
import json
import sys

sys.path.insert(0, "scripts")
sys.path.insert(0, "app")
from backend.datasets import CATALOG  # noqa: E402
from pg import connect  # noqa: E402

conn = connect("primary")
cur = conn.cursor()
for c in CATALOG:
    cur.execute("""INSERT INTO app.layer_catalog (layer_key, solution, title, description, kind, dataset, default_metric, metrics,
                                                  default_style, group_name, sort_order)
                   VALUES (%s, %s, %s, %s, %s, %s, %s, %s::jsonb, %s::jsonb, %s, %s)
                   ON CONFLICT (layer_key) DO UPDATE SET solution = EXCLUDED.solution, title = EXCLUDED.title,
                     description = EXCLUDED.description, kind = EXCLUDED.kind, dataset = EXCLUDED.dataset,
                     default_metric = EXCLUDED.default_metric, metrics = EXCLUDED.metrics, default_style = EXCLUDED.default_style,
                     group_name = EXCLUDED.group_name, sort_order = EXCLUDED.sort_order""",
                (c["layer_key"], c["solution"], c["title"], c["description"], c["kind"], c["dataset"], c["default_metric"],
                 json.dumps(c["metrics"]), json.dumps(c["default_style"]), c["group_name"], c["sort_order"]))
cur.execute("SELECT app.bump_dataset('catalog')")
conn.commit()
print("seeded", len(CATALOG))
