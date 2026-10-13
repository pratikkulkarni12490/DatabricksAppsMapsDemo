-- Serving copies of gold for Lakebase synced tables (synced tables cannot read row-filtered sources or GEOMETRY).
-- Built by the pipeline owner (NATIONAL scope), CDF on, geometry exported as EWKB. Not granted to end users.
CREATE OR REPLACE TABLE ${catalog}.serving.retail_hex_monthly TBLPROPERTIES (delta.enableChangeDataFeed = true)
COMMENT 'Serving copy of gold.retail_hex_monthly for Lakebase.' AS SELECT * FROM ${catalog}.gold.retail_hex_monthly;
CREATE OR REPLACE TABLE ${catalog}.serving.retail_hex_profile TBLPROPERTIES (delta.enableChangeDataFeed = true)
COMMENT 'Serving copy of gold.retail_hex_profile for Lakebase.' AS SELECT * FROM ${catalog}.gold.retail_hex_profile;
CREATE OR REPLACE TABLE ${catalog}.serving.retail_stores TBLPROPERTIES (delta.enableChangeDataFeed = true)
COMMENT 'Serving copy of gold.retail_stores for Lakebase.' AS SELECT * FROM ${catalog}.gold.retail_stores;
CREATE OR REPLACE TABLE ${catalog}.serving.retail_store_monthly TBLPROPERTIES (delta.enableChangeDataFeed = true)
COMMENT 'Serving copy of gold.retail_store_monthly for Lakebase.' AS SELECT * FROM ${catalog}.gold.retail_store_monthly;
CREATE OR REPLACE TABLE ${catalog}.serving.retail_store_catchment TBLPROPERTIES (delta.enableChangeDataFeed = true)
COMMENT 'Serving copy of gold.retail_store_catchment for Lakebase.' AS SELECT * FROM ${catalog}.gold.retail_store_catchment;
CREATE OR REPLACE TABLE ${catalog}.serving.retail_competitors TBLPROPERTIES (delta.enableChangeDataFeed = true)
COMMENT 'Serving copy of gold.retail_competitors for Lakebase.' AS SELECT * FROM ${catalog}.gold.retail_competitors;
CREATE OR REPLACE TABLE ${catalog}.serving.retail_plots TBLPROPERTIES (delta.enableChangeDataFeed = true)
COMMENT 'Serving copy of gold.retail_plot_scores for Lakebase; boundary as EWKB (BYTEA in Postgres, rebuilt with PostGIS).'
AS SELECT * EXCEPT (geom), st_asewkb(geom) AS geom_ewkb FROM ${catalog}.gold.retail_plot_scores;
CREATE OR REPLACE TABLE ${catalog}.serving.fiber_hex_daily TBLPROPERTIES (delta.enableChangeDataFeed = true)
COMMENT 'Serving copy of gold.fiber_hex_daily for Lakebase.' AS SELECT * FROM ${catalog}.gold.fiber_hex_daily;
CREATE OR REPLACE TABLE ${catalog}.serving.fiber_hex_profile TBLPROPERTIES (delta.enableChangeDataFeed = true)
COMMENT 'Serving copy of gold.fiber_hex_profile for Lakebase.' AS SELECT * FROM ${catalog}.gold.fiber_hex_profile;
CREATE OR REPLACE TABLE ${catalog}.serving.fiber_olts TBLPROPERTIES (delta.enableChangeDataFeed = true)
COMMENT 'Serving copy of gold.fiber_olts for Lakebase.' AS SELECT * FROM ${catalog}.gold.fiber_olts;
CREATE OR REPLACE TABLE ${catalog}.serving.fiber_olt_hourly TBLPROPERTIES (delta.enableChangeDataFeed = true)
COMMENT 'Serving copy of gold.fiber_olt_hourly for Lakebase.' AS SELECT * FROM ${catalog}.gold.fiber_olt_hourly;
CREATE OR REPLACE TABLE ${catalog}.serving.fiber_fdh TBLPROPERTIES (delta.enableChangeDataFeed = true)
COMMENT 'Serving copy of gold.fiber_fdh for Lakebase.' AS SELECT * FROM ${catalog}.gold.fiber_fdh;
CREATE OR REPLACE TABLE ${catalog}.serving.fiber_incidents TBLPROPERTIES (delta.enableChangeDataFeed = true)
COMMENT 'Serving copy of gold.fiber_incidents for Lakebase.' AS SELECT * FROM ${catalog}.gold.fiber_incidents;
CREATE OR REPLACE TABLE ${catalog}.serving.fiber_kpi_daily TBLPROPERTIES (delta.enableChangeDataFeed = true)
COMMENT 'Serving copy of gold.fiber_kpi_daily for Lakebase.' AS SELECT * FROM ${catalog}.gold.fiber_kpi_daily;
CREATE OR REPLACE TABLE ${catalog}.serving.fiber_technicians TBLPROPERTIES (delta.enableChangeDataFeed = true)
COMMENT 'Serving copy of gold.fiber_technicians for Lakebase.' AS SELECT * FROM ${catalog}.gold.fiber_technicians;
CREATE OR REPLACE TABLE ${catalog}.serving.fiber_routes TBLPROPERTIES (delta.enableChangeDataFeed = true)
COMMENT 'Serving copy of gold.fiber_routes for Lakebase; geometry as EWKB.'
AS SELECT * EXCEPT (geom), st_asewkb(geom) AS geom_ewkb FROM ${catalog}.gold.fiber_routes;
CREATE OR REPLACE TABLE ${catalog}.serving.fiber_open_tickets TBLPROPERTIES (delta.enableChangeDataFeed = true)
COMMENT 'Serving copy of gold.fiber_open_tickets for Lakebase.' AS SELECT * FROM ${catalog}.gold.fiber_open_tickets;
CREATE OR REPLACE TABLE ${catalog}.serving.user_region_scope TBLPROPERTIES (delta.enableChangeDataFeed = true)
COMMENT 'Serving copy of access.user_region_scope; drives Postgres RLS.' AS SELECT * FROM ${catalog}.access.user_region_scope;
