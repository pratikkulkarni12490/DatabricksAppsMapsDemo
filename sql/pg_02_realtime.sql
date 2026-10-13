-- Realtime: per-dataset versions + NOTIFY on every change so the app can push updates to browsers (SSE).
CREATE TABLE IF NOT EXISTS app.dataset_version (
  dataset text PRIMARY KEY,
  version bigint NOT NULL DEFAULT 1,
  changed_at timestamptz NOT NULL DEFAULT now(),
  stat_signature text
);

INSERT INTO app.dataset_version (dataset) VALUES
  ('retail_demand'), ('retail_market'), ('fiber_health'), ('fiber_coverage'),
  ('stores'), ('competitors'), ('plots'), ('olts'), ('fdh'), ('incidents_30d'), ('routes'),
  ('fiber_kpis'), ('retail_kpis'), ('scope'), ('catalog')
ON CONFLICT (dataset) DO NOTHING;

CREATE OR REPLACE FUNCTION app.bump_dataset(p_dataset text) RETURNS bigint
LANGUAGE sql AS $$
  UPDATE app.dataset_version SET version = version + 1, changed_at = now() WHERE dataset = p_dataset RETURNING version
$$;

CREATE OR REPLACE FUNCTION app.notify_dataset() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.version IS DISTINCT FROM OLD.version THEN
    PERFORM pg_notify('geolens', json_build_object('kind', 'dataset', 'dataset', NEW.dataset, 'version', NEW.version)::text);
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS dataset_version_notify ON app.dataset_version;
CREATE TRIGGER dataset_version_notify AFTER UPDATE ON app.dataset_version
  FOR EACH ROW EXECUTE FUNCTION app.notify_dataset();

-- Statement-level triggers: one notification per simulator tick / user action, not per row
CREATE OR REPLACE FUNCTION app.notify_live() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM pg_notify('geolens', json_build_object('kind', 'live', 'table', TG_TABLE_NAME, 'ts', now())::text);
  RETURN NULL;
END $$;

DROP TRIGGER IF EXISTS live_incidents_notify ON app.live_incidents;
CREATE TRIGGER live_incidents_notify AFTER INSERT OR UPDATE OR DELETE ON app.live_incidents
  FOR EACH STATEMENT EXECUTE FUNCTION app.notify_live();

DROP TRIGGER IF EXISTS live_technicians_notify ON app.live_technicians;
CREATE TRIGGER live_technicians_notify AFTER INSERT OR UPDATE OR DELETE ON app.live_technicians
  FOR EACH STATEMENT EXECUTE FUNCTION app.notify_live();

CREATE OR REPLACE FUNCTION app.notify_shortlist() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM pg_notify('geolens', json_build_object('kind', 'shortlist', 'ts', now())::text);
  RETURN NULL;
END $$;

DROP TRIGGER IF EXISTS plot_shortlist_notify ON app.plot_shortlist;
CREATE TRIGGER plot_shortlist_notify AFTER INSERT OR UPDATE OR DELETE ON app.plot_shortlist
  FOR EACH STATEMENT EXECUTE FUNCTION app.notify_shortlist();

-- Change signature of each synced table, from the primary's stats counters (synced pipelines write to the primary).
-- The app's watcher compares signatures and bumps app.dataset_version when a sync lands.
CREATE OR REPLACE FUNCTION app.synced_table_signatures() RETURNS TABLE (table_name text, signature text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog AS $$
  SELECT coalesce(parent.relname, c.relname)::text,
         sum(s.n_tup_ins + s.n_tup_upd + s.n_tup_del)::text || ':' || sum(s.n_live_tup)::text
  FROM pg_stat_all_tables s
  JOIN pg_class c ON c.oid = s.relid
  LEFT JOIN pg_inherits i ON i.inhrelid = c.oid
  LEFT JOIN pg_class parent ON parent.oid = i.inhparent
  WHERE s.schemaname = 'geo'
  GROUP BY 1
$$;
