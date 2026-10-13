-- Entitlements (single source of truth) + UC row filters on gold. The same table is synced to Lakebase and drives Postgres RLS.
CREATE OR REPLACE TABLE ${catalog}.access.user_region_scope (
  principal STRING NOT NULL COMMENT 'User email (Databricks identity) or demo persona id',
  scope_level STRING NOT NULL COMMENT 'NATIONAL, REGION or METRO',
  scope_value STRING NOT NULL COMMENT 'ALL for NATIONAL, region name (West/North/South/East) or metro code (MUM, DEL, ...)',
  persona STRING COMMENT 'Role label shown in the app, e.g. Regional Head West',
  is_demo_persona BOOLEAN COMMENT 'True for demo personas that presenters can impersonate in the app',
  CONSTRAINT user_region_scope_pk PRIMARY KEY (principal, scope_level, scope_value) RELY
) TBLPROPERTIES (delta.enableChangeDataFeed = true)
COMMENT 'Who can see which regions / metros. Grain: principal x scope. Managed by the business access team. Enforced by UC row filter access.can_see on gold tables and by Postgres RLS in Lakebase.';

INSERT INTO ${catalog}.access.user_region_scope VALUES
  ('${presenter_email}', 'NATIONAL', 'ALL', 'National view (presenter)', false),
  ('national.head@ril-demo.in', 'NATIONAL', 'ALL', 'Head of Strategy, National', true),
  ('west.head@ril-demo.in', 'REGION', 'West', 'Regional Head, West', true),
  ('north.head@ril-demo.in', 'REGION', 'North', 'Regional Head, North', true),
  ('south.head@ril-demo.in', 'REGION', 'South', 'Regional Head, South', true),
  ('east.head@ril-demo.in', 'REGION', 'East', 'Regional Head, East', true),
  ('mumbai.cluster@ril-demo.in', 'METRO', 'MUM', 'Cluster Manager, Mumbai MMR', true),
  ('bengaluru.cluster@ril-demo.in', 'METRO', 'BLR', 'Cluster Manager, Bengaluru', true),
  ('delhi.noc@ril-demo.in', 'METRO', 'DEL', 'NOC Lead, Delhi NCR', true),
  ('south.mumbai.ops@ril-demo.in', 'REGION', 'South', 'Ops Lead, South + Mumbai', true),
  ('south.mumbai.ops@ril-demo.in', 'METRO', 'MUM', 'Ops Lead, South + Mumbai', true);

CREATE OR REPLACE FUNCTION ${catalog}.access.can_see(p_region STRING, p_metro STRING)
RETURNS BOOLEAN
COMMENT 'Row filter: true if current_user() has NATIONAL scope, or REGION scope matching p_region, or METRO scope matching p_metro in access.user_region_scope.'
RETURN EXISTS (
  SELECT 1 FROM ${catalog}.access.user_region_scope s
  WHERE s.principal = current_user()
    AND (s.scope_level = 'NATIONAL'
         OR (s.scope_level = 'REGION' AND s.scope_value = p_region)
         OR (s.scope_level = 'METRO' AND s.scope_value = p_metro))
);

ALTER TABLE ${catalog}.gold.retail_hex_monthly SET ROW FILTER ${catalog}.access.can_see ON (region, metro_code);
ALTER TABLE ${catalog}.gold.retail_hex_profile SET ROW FILTER ${catalog}.access.can_see ON (region, metro_code);
ALTER TABLE ${catalog}.gold.retail_stores SET ROW FILTER ${catalog}.access.can_see ON (region, metro_code);
ALTER TABLE ${catalog}.gold.retail_store_monthly SET ROW FILTER ${catalog}.access.can_see ON (region, metro_code);
ALTER TABLE ${catalog}.gold.retail_store_catchment SET ROW FILTER ${catalog}.access.can_see ON (region, metro_code);
ALTER TABLE ${catalog}.gold.retail_competitors SET ROW FILTER ${catalog}.access.can_see ON (region, metro_code);
ALTER TABLE ${catalog}.gold.retail_plot_scores SET ROW FILTER ${catalog}.access.can_see ON (region, metro_code);
ALTER TABLE ${catalog}.gold.fiber_hex_daily SET ROW FILTER ${catalog}.access.can_see ON (region, metro_code);
ALTER TABLE ${catalog}.gold.fiber_hex_profile SET ROW FILTER ${catalog}.access.can_see ON (region, metro_code);
ALTER TABLE ${catalog}.gold.fiber_olts SET ROW FILTER ${catalog}.access.can_see ON (region, metro_code);
ALTER TABLE ${catalog}.gold.fiber_olt_hourly SET ROW FILTER ${catalog}.access.can_see ON (region, metro_code);
ALTER TABLE ${catalog}.gold.fiber_fdh SET ROW FILTER ${catalog}.access.can_see ON (region, metro_code);
ALTER TABLE ${catalog}.gold.fiber_incidents SET ROW FILTER ${catalog}.access.can_see ON (region, metro_code);
ALTER TABLE ${catalog}.gold.fiber_kpi_daily SET ROW FILTER ${catalog}.access.can_see ON (region, metro_code);
ALTER TABLE ${catalog}.gold.fiber_technicians SET ROW FILTER ${catalog}.access.can_see ON (region, metro_code);
ALTER TABLE ${catalog}.gold.fiber_routes SET ROW FILTER ${catalog}.access.can_see ON (region, metro_code);
ALTER TABLE ${catalog}.gold.fiber_open_tickets SET ROW FILTER ${catalog}.access.can_see ON (region, metro_code);
