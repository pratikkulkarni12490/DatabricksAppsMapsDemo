-- Lakebase (Postgres 17 + PostGIS) serving setup. Idempotent: re-run after each synced-table snapshot refresh.
-- geo.*    : synced tables (owned by the sync pipeline, read-only)
-- secure.* : security_barrier views = row-level security over synced tables, scoped by geo.user_region_scope
-- app.*    : native tables written by the app, protected with ENABLE + FORCE ROW LEVEL SECURITY
CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE SCHEMA IF NOT EXISTS app;
CREATE SCHEMA IF NOT EXISTS secure;

-- Tile + lookup indexes on synced tables
CREATE INDEX IF NOT EXISTS retail_hex_monthly_tile_idx ON geo.retail_hex_monthly (res, tile_h3, month);
CREATE INDEX IF NOT EXISTS retail_hex_profile_tile_idx ON geo.retail_hex_profile (res, tile_h3);
CREATE INDEX IF NOT EXISTS fiber_hex_daily_tile_idx ON geo.fiber_hex_daily (res, tile_h3, day);
CREATE INDEX IF NOT EXISTS fiber_hex_profile_tile_idx ON geo.fiber_hex_profile (res, tile_h3);
CREATE INDEX IF NOT EXISTS fiber_incidents_status_idx ON geo.fiber_incidents (status, start_ts);
CREATE INDEX IF NOT EXISTS fiber_incidents_olt_idx ON geo.fiber_incidents (olt_id);
CREATE INDEX IF NOT EXISTS fiber_fdh_olt_idx ON geo.fiber_fdh (olt_id);
CREATE INDEX IF NOT EXISTS fiber_kpi_daily_day_idx ON geo.fiber_kpi_daily (day);
CREATE INDEX IF NOT EXISTS retail_plots_geom_idx ON geo.retail_plots USING gist (ST_GeomFromEWKB(geom_ewkb));
CREATE INDEX IF NOT EXISTS fiber_routes_geom_idx ON geo.fiber_routes USING gist (ST_GeomFromEWKB(geom_ewkb));

-- Scope resolution. The app sets app.principal (authenticated user email from the Databricks Apps proxy) and optionally
-- app.persona per transaction. A persona is honoured only if the real principal holds a non-demo NATIONAL scope (presenter).
CREATE OR REPLACE FUNCTION app.effective_principal() RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, geo AS $$
  SELECT CASE
    WHEN nullif(current_setting('app.persona', true), '') IS NOT NULL
         AND EXISTS (SELECT 1 FROM geo.user_region_scope s
                     WHERE s.principal = current_setting('app.principal', true)
                       AND s.scope_level = 'NATIONAL' AND NOT s.is_demo_persona)
    THEN current_setting('app.persona', true)
    ELSE nullif(current_setting('app.principal', true), '')
  END
$$;

CREATE OR REPLACE FUNCTION app.scope_national() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, geo, app AS $$
  SELECT EXISTS (SELECT 1 FROM geo.user_region_scope WHERE principal = app.effective_principal() AND scope_level = 'NATIONAL')
$$;

CREATE OR REPLACE FUNCTION app.scope_regions() RETURNS text[]
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, geo, app AS $$
  SELECT coalesce(array_agg(scope_value), '{}') FROM geo.user_region_scope WHERE principal = app.effective_principal() AND scope_level = 'REGION'
$$;

CREATE OR REPLACE FUNCTION app.scope_metros() RETURNS text[]
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, geo, app AS $$
  SELECT coalesce(array_agg(scope_value), '{}') FROM geo.user_region_scope WHERE principal = app.effective_principal() AND scope_level = 'METRO'
$$;

CREATE OR REPLACE FUNCTION app.can_see(p_region text, p_metro text) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, geo, app AS $$
  SELECT app.scope_national() OR p_region = ANY (app.scope_regions()) OR p_metro = ANY (app.scope_metros())
$$;

CREATE OR REPLACE FUNCTION app.my_scope() RETURNS TABLE (principal text, scope_level text, scope_value text, persona text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, geo, app AS $$
  SELECT principal, scope_level, scope_value, persona FROM geo.user_region_scope WHERE principal = app.effective_principal()
$$;

CREATE OR REPLACE FUNCTION app.demo_personas() RETURNS TABLE (principal text, persona text, scopes text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, geo, app AS $$
  SELECT principal, min(persona), string_agg(scope_level || ':' || scope_value, ', ' ORDER BY scope_level, scope_value)
  FROM geo.user_region_scope WHERE is_demo_persona GROUP BY principal ORDER BY min(persona)
$$;

-- Row-level security over synced tables: one security_barrier view per table. Uncorrelated scalar subqueries become
-- InitPlans, so scope is resolved once per query and the tile indexes stay usable.
DO $$
DECLARE t text;
BEGIN
  FOR t IN SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
           WHERE n.nspname = 'geo' AND c.relkind IN ('p', 'r') AND c.relname <> 'user_region_scope'
             AND NOT c.relispartition
  LOOP
    EXECUTE format(
      'CREATE OR REPLACE VIEW secure.%I WITH (security_barrier = true) AS SELECT * FROM geo.%I '
      'WHERE ((SELECT app.scope_national()) OR region = ANY ((SELECT app.scope_regions())::text[]) OR metro_code = ANY ((SELECT app.scope_metros())::text[]))',
      t, t);
  END LOOP;
END $$;

-- Native app tables (write path on the primary) with true Postgres RLS
CREATE TABLE IF NOT EXISTS app.saved_maps (
  map_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  owner text NOT NULL DEFAULT app.effective_principal(),
  solution text NOT NULL,
  name text NOT NULL,
  config jsonb NOT NULL,
  shared boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE app.saved_maps ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.saved_maps FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS saved_maps_read ON app.saved_maps;
CREATE POLICY saved_maps_read ON app.saved_maps FOR SELECT USING (shared OR owner = app.effective_principal());
DROP POLICY IF EXISTS saved_maps_write ON app.saved_maps;
CREATE POLICY saved_maps_write ON app.saved_maps FOR ALL USING (owner = app.effective_principal()) WITH CHECK (owner = app.effective_principal());

CREATE TABLE IF NOT EXISTS app.plot_shortlist (
  plot_id text NOT NULL,
  principal text NOT NULL DEFAULT app.effective_principal(),
  region text NOT NULL,
  metro_code text NOT NULL,
  note text,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (plot_id, principal)
);
ALTER TABLE app.plot_shortlist ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.plot_shortlist FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS plot_shortlist_scope ON app.plot_shortlist;
CREATE POLICY plot_shortlist_scope ON app.plot_shortlist FOR ALL
  USING (app.can_see(region, metro_code)) WITH CHECK (app.can_see(region, metro_code) AND principal = app.effective_principal());

CREATE TABLE IF NOT EXISTS app.live_incidents (
  incident_id text PRIMARY KEY,
  incident_type text, severity text, network_level text, olt_id text, fdh_id text,
  metro_code text NOT NULL, region text NOT NULL, locality text,
  latitude double precision, longitude double precision, homes_impacted int,
  start_ts timestamptz NOT NULL DEFAULT now(), end_ts timestamptz, status text NOT NULL DEFAULT 'Open',
  root_cause text, assigned_technician text, updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS live_incidents_updated_idx ON app.live_incidents (updated_at);
ALTER TABLE app.live_incidents ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.live_incidents FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS live_incidents_scope ON app.live_incidents;
CREATE POLICY live_incidents_scope ON app.live_incidents FOR ALL
  USING (app.can_see(region, metro_code)) WITH CHECK (app.can_see(region, metro_code));

CREATE TABLE IF NOT EXISTS app.live_technicians (
  technician_id text PRIMARY KEY,
  metro_code text NOT NULL, region text NOT NULL, locality text, skill text, status text,
  latitude double precision, longitude double precision,
  target_lat double precision, target_lon double precision, assigned_incident text,
  updated_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE app.live_technicians ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.live_technicians FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS live_technicians_scope ON app.live_technicians;
CREATE POLICY live_technicians_scope ON app.live_technicians FOR ALL
  USING (app.can_see(region, metro_code)) WITH CHECK (app.can_see(region, metro_code));

CREATE TABLE IF NOT EXISTS app.data_version (id int PRIMARY KEY DEFAULT 1, version text NOT NULL, refreshed_at timestamptz NOT NULL DEFAULT now());
INSERT INTO app.data_version (id, version) VALUES (1, to_char(now(), 'YYYYMMDDHH24MI'))
  ON CONFLICT (id) DO UPDATE SET version = EXCLUDED.version, refreshed_at = now();

CREATE TABLE IF NOT EXISTS app.layer_catalog (
  layer_key text PRIMARY KEY,
  solution text NOT NULL,
  title text NOT NULL,
  description text,
  kind text NOT NULL,
  dataset text NOT NULL,
  default_metric text,
  metrics jsonb NOT NULL DEFAULT '[]',
  default_style jsonb NOT NULL DEFAULT '{}',
  group_name text,
  sort_order int DEFAULT 100
);
