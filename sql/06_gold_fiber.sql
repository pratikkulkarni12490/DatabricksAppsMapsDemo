-- Gold (Jio Fiber): hex health rollups res 5-9 per day, coverage profile, OLT capacity/status, KPIs, incidents, field force
-- Network Health Score (0-100) = 100 - penalties for downtime, low optical power, latency, packet loss, throughput shortfall, ticket rate

CREATE OR REPLACE FUNCTION ${catalog}.gold.fiber_health_score(uptime DOUBLE, low_power_pct DOUBLE, latency_ms DOUBLE, loss_pct DOUBLE,
                                                               tput_ratio DOUBLE, tickets_per_1k DOUBLE)
RETURNS DOUBLE
COMMENT 'Jio Fiber Network Health Score 0-100. Penalties: downtime (10 pts per 1% lost, max 40), low optical power (0.5 per %, max 20), latency above 8 ms (1.5 per ms, max 10), packet loss (10 per %, max 10), throughput shortfall vs plan (50 x shortfall, max 10), tickets per 1k subs per day (2 each, max 10).'
RETURN round(greatest(0, 100
  - least(40, (100 - uptime) * 10)
  - least(20, low_power_pct * 0.5)
  - least(10, greatest(0, latency_ms - 8) * 1.5)
  - least(10, loss_pct * 10)
  - least(10, greatest(0, 1 - tput_ratio) * 50)
  - least(10, tickets_per_1k * 2)), 1);

CREATE OR REPLACE TABLE ${catalog}.gold.fiber_hex_daily
CLUSTER BY (res, tile_h3, day)
COMMENT 'Daily network experience per H3 cell rolled up res 5-9 (subscriber-weighted). Grain: h3 (any res) x day. Source: silver.fiber_hex_daily + silver.fiber_incidents. Refreshed hourly in production.'
AS
WITH b AS (
  SELECT h3, metro_code, region, day, subscribers AS s,
         avg_rx_power_dbm * subscribers AS rx_w, pct_ont_low_power * subscribers AS lowp_w, avg_latency_ms * subscribers AS lat_w,
         packet_loss_pct * subscribers AS loss_w, throughput_vs_plan * subscribers AS tput_w, uptime_pct * subscribers AS up_w, tickets
  FROM ${catalog}.silver.fiber_hex_daily
),
r AS (SELECT b.*, res FROM b LATERAL VIEW explode(array(5, 6, 7, 8, 9)) t AS res),
a AS (
  SELECT h3_toparent(h3, res) AS h3, res, h3_toparent(h3, res - 3) AS tile_h3, metro_code, region, day,
         sum(s) AS subscribers, sum(rx_w) / sum(s) AS rx, sum(lowp_w) / sum(s) AS lowp, sum(lat_w) / sum(s) AS lat,
         sum(loss_w) / sum(s) AS loss, sum(tput_w) / sum(s) AS tput, sum(up_w) / sum(s) AS up, sum(tickets) AS tickets
  FROM r GROUP BY h3_toparent(h3, res), res, h3_toparent(h3, res - 3), metro_code, region, day
),
inc AS (
  SELECT h3_toparent(h3_r9, res) AS h3, cast(start_ts AS DATE) AS day, count(*) AS incidents,
         sum(IF(severity = 'P1', 1, 0)) AS p1_incidents, sum(homes_impacted) AS homes_impacted
  FROM ${catalog}.silver.fiber_incidents LATERAL VIEW explode(array(5, 6, 7, 8, 9)) t AS res
  GROUP BY 1, 2
)
SELECT a.h3, a.res, a.tile_h3, a.metro_code, a.region, a.day, a.subscribers,
       round(a.rx, 2) AS avg_rx_power_dbm, round(a.lowp, 2) AS pct_ont_low_power, round(a.lat, 1) AS avg_latency_ms,
       round(a.loss, 3) AS packet_loss_pct, round(a.tput, 3) AS throughput_vs_plan, round(a.up, 3) AS uptime_pct,
       a.tickets, round(1000.0 * a.tickets / a.subscribers, 2) AS tickets_per_1k,
       coalesce(i.incidents, 0) AS incidents, coalesce(i.p1_incidents, 0) AS p1_incidents, coalesce(i.homes_impacted, 0) AS homes_impacted,
       ${catalog}.gold.fiber_health_score(a.up, a.lowp, a.lat, a.loss, a.tput, 1000.0 * a.tickets / a.subscribers) AS health_score
FROM a LEFT JOIN inc i ON i.h3 = a.h3 AND i.day = a.day;

CREATE OR REPLACE TABLE ${catalog}.gold.fiber_hex_profile
CLUSTER BY (res, tile_h3)
COMMENT 'Coverage and commercial profile per H3 cell res 5-9: households, homes passed, homes connected, penetration, unconnected homes passed (sales opportunity), homes not yet passed (build-out opportunity), plan mix, 7-day health, Reliance Retail customers not on Jio Fiber (cross-sell). Grain: h3 (any res). Refreshed daily.'
AS
WITH sub AS (
  SELECT home_h3_r9 AS h3, count(*) AS subs, sum(IF(plan = '1 Gbps', 1, 0)) AS gbps, sum(IF(plan IN ('300 Mbps', '1 Gbps'), 1, 0)) AS premium,
         avg(months_between(DATE'2026-10-10', activation_date)) AS tenure
  FROM ${catalog}.silver.fiber_subscribers GROUP BY 1
),
h7 AS (
  SELECT h3, avg(health_score) AS health_7d, avg(uptime_pct) AS uptime_7d, sum(tickets) AS tickets_7d
  FROM ${catalog}.gold.fiber_hex_daily WHERE res = 9 AND day >= DATE'2026-10-03' GROUP BY 1
),
rc AS (SELECT home_h3_r9 AS h3, count(*) AS retail_customers FROM ${catalog}.silver.customers GROUP BY 1),
b AS (
  SELECT c.h3, c.metro_code, c.region, c.households, c.homes_passed, c.homes_connected, c.olt_id, c.fdh_id,
         coalesce(s.gbps, 0) AS gbps, coalesce(s.premium, 0) AS premium, coalesce(s.tenure, 0) * c.homes_connected AS tenure_w,
         coalesce(h.health_7d, 100) * c.homes_connected AS health_w, coalesce(h.uptime_7d, 100) * c.homes_connected AS up_w,
         coalesce(h.tickets_7d, 0) AS tickets_7d, coalesce(r.retail_customers, 0) AS retail_customers,
         c.penetration
  FROM ${catalog}.silver.fiber_coverage c LEFT JOIN sub s USING (h3) LEFT JOIN h7 h USING (h3) LEFT JOIN rc r USING (h3)
),
r AS (SELECT b.*, res FROM b LATERAL VIEW explode(array(5, 6, 7, 8, 9)) t AS res)
SELECT h3_toparent(h3, res) AS h3, res, h3_toparent(h3, res - 3) AS tile_h3, metro_code, region,
       sum(households) AS households, sum(homes_passed) AS homes_passed, sum(homes_connected) AS homes_connected,
       round(100.0 * sum(homes_connected) / greatest(sum(homes_passed), 1), 2) AS penetration_pct,
       round(100.0 * sum(homes_passed) / greatest(sum(households), 1), 2) AS coverage_pct,
       sum(homes_passed) - sum(homes_connected) AS unconnected_homes_passed,
       sum(households) - sum(homes_passed) AS homes_not_passed,
       count(DISTINCT olt_id) AS olts, count(DISTINCT fdh_id) AS fdhs,
       round(100.0 * sum(gbps) / greatest(sum(homes_connected), 1), 2) AS gbps_share_pct,
       round(100.0 * sum(premium) / greatest(sum(homes_connected), 1), 2) AS premium_plan_pct,
       round(sum(tenure_w) / greatest(sum(homes_connected), 1), 1) AS avg_tenure_months,
       round(sum(health_w) / greatest(sum(homes_connected), 1), 1) AS health_7d,
       round(sum(up_w) / greatest(sum(homes_connected), 1), 3) AS uptime_7d,
       sum(tickets_7d) AS tickets_7d,
       sum(retail_customers) AS retail_customers,
       cast(round(sum(retail_customers * (1 - penetration))) AS INT) AS cross_sell_prospects
FROM r GROUP BY h3_toparent(h3, res), res, h3_toparent(h3, res - 3), metro_code, region;

CREATE OR REPLACE TABLE ${catalog}.gold.fiber_olts
COMMENT 'OLT status and capacity as of 2026-10-10 05:00 UTC. Grain: OLT. pon_fill_pct = homes connected / (PON ports x 32). capacity_status: Exhausted (>=90%), Augment <6m, Healthy. months_to_exhaustion assumes 2.5% monthly net adds. Refreshed every 5 min in production.'
AS
WITH last AS (
  SELECT olt_id, max_by(status, hour_ts) AS current_status, max_by(pon_util_pct, hour_ts) AS util_now
  FROM ${catalog}.silver.fiber_olt_hourly GROUP BY olt_id
),
w7 AS (
  SELECT olt_id, max(pon_util_pct) AS peak_util_7d, max(uplink_util_pct) AS peak_uplink_7d, sum(alarms) AS alarms_7d,
         sum(IF(status <> 'Up', 1, 0)) AS impaired_hours_7d
  FROM ${catalog}.silver.fiber_olt_hourly WHERE hour_ts >= TIMESTAMP'2026-10-03 05:00:00' GROUP BY olt_id
),
inc AS (
  SELECT olt_id, sum(IF(status = 'Open', 1, 0)) AS open_incidents, sum(IF(status = 'Open', homes_impacted, 0)) AS homes_impacted_now,
         count(*) AS incidents_30d
  FROM ${catalog}.silver.fiber_incidents GROUP BY olt_id
),
hx AS (
  SELECT olt_id, sum(tickets) AS tickets_7d,
         sum(subscribers * gold_score) / sum(subscribers) AS health_7d
  FROM (SELECT d.*, ${catalog}.gold.fiber_health_score(uptime_pct, pct_ont_low_power, avg_latency_ms, packet_loss_pct, throughput_vs_plan,
                                                         1000.0 * tickets / subscribers) AS gold_score
        FROM ${catalog}.silver.fiber_hex_daily d WHERE day >= DATE'2026-10-03')
  GROUP BY olt_id
)
SELECT o.olt_id, o.olt_name, o.metro_code, o.region, o.locality, o.latitude, o.longitude, o.h3_r9, o.agg_node_id, o.vendor_model,
       o.pon_ports, o.split_ratio, o.homes_connected, o.homes_passed, o.commissioned_year,
       round(100.0 * o.homes_connected / (o.pon_ports * 32), 1) AS pon_fill_pct,
       CASE WHEN o.homes_connected / (o.pon_ports * 32.0) >= 0.9 THEN 0
            ELSE round(ln(0.9 / (o.homes_connected / (o.pon_ports * 32.0))) / ln(1.025), 1) END AS months_to_exhaustion,
       CASE WHEN o.homes_connected / (o.pon_ports * 32.0) >= 0.9 THEN 'Exhausted'
            WHEN ln(0.9 / (o.homes_connected / (o.pon_ports * 32.0))) / ln(1.025) < 6 THEN 'Augment <6m' ELSE 'Healthy' END AS capacity_status,
       l.current_status, l.util_now, w.peak_util_7d, w.peak_uplink_7d, w.alarms_7d, w.impaired_hours_7d,
       coalesce(i.open_incidents, 0) AS open_incidents, coalesce(i.homes_impacted_now, 0) AS homes_impacted_now,
       coalesce(i.incidents_30d, 0) AS incidents_30d, coalesce(h.tickets_7d, 0) AS tickets_7d, round(h.health_7d, 1) AS health_7d
FROM ${catalog}.silver.fiber_olts o
LEFT JOIN last l USING (olt_id) LEFT JOIN w7 w USING (olt_id) LEFT JOIN inc i USING (olt_id) LEFT JOIN hx h USING (olt_id);

CREATE OR REPLACE TABLE ${catalog}.gold.fiber_olt_hourly
CLUSTER BY (olt_id)
COMMENT 'Hourly OLT performance for drill-down charts. Grain: OLT x hour (UTC). Source: silver.fiber_olt_hourly.'
AS SELECT * FROM ${catalog}.silver.fiber_olt_hourly;

CREATE OR REPLACE TABLE ${catalog}.gold.fiber_fdh
COMMENT 'FDH (splitter cabinet) status. Grain: FDH. health_7d subscriber-weighted. Refreshed daily.'
AS
WITH h AS (
  SELECT fdh_id, round(avg(${catalog}.gold.fiber_health_score(uptime_pct, pct_ont_low_power, avg_latency_ms, packet_loss_pct, throughput_vs_plan,
                                                                1000.0 * tickets / subscribers)), 1) AS health_7d,
         round(avg(pct_ont_low_power), 2) AS pct_ont_low_power_7d
  FROM ${catalog}.silver.fiber_hex_daily WHERE day >= DATE'2026-10-03' GROUP BY fdh_id
),
i AS (SELECT fdh_id, sum(IF(status = 'Open', 1, 0)) AS open_incidents, count(*) AS incidents_30d FROM ${catalog}.silver.fiber_incidents WHERE fdh_id IS NOT NULL GROUP BY 1)
SELECT f.*, h.health_7d, h.pct_ont_low_power_7d, coalesce(i.open_incidents, 0) AS open_incidents, coalesce(i.incidents_30d, 0) AS incidents_30d
FROM ${catalog}.silver.fiber_fdh f LEFT JOIN h USING (fdh_id) LEFT JOIN i USING (fdh_id);

CREATE OR REPLACE TABLE ${catalog}.gold.fiber_incidents
CLUSTER BY (metro_code)
COMMENT 'Network incidents with SLA and age. Grain: incident. age_min = minutes open as of 2026-10-10 06:00 UTC (open incidents only).'
AS
SELECT concat('INC-', date_format(start_ts, 'yyMMdd'), '-',
              lpad(cast(row_number() OVER (PARTITION BY cast(start_ts AS DATE) ORDER BY start_ts, olt_id, fdh_id) AS STRING), 5, '0')) AS incident_id,
       i.* EXCEPT (incident_id),
       IF(status = 'Open', cast((unix_timestamp(TIMESTAMP'2026-10-10 06:00:00') - unix_timestamp(start_ts)) / 60 AS INT), NULL) AS age_min,
       CASE severity WHEN 'P1' THEN 240 WHEN 'P2' THEN 480 WHEN 'P3' THEN 1440 ELSE 2880 END AS sla_min
FROM ${catalog}.silver.fiber_incidents i;

CREATE OR REPLACE TABLE ${catalog}.gold.fiber_kpi_daily
COMMENT 'Control-centre KPIs by region, metro and day. Grain: metro x day. uptime subscriber-weighted; mttr_min over resolved incidents started that day.'
AS
WITH h AS (
  SELECT metro_code, region, day, sum(subscribers) AS subscribers,
         round(sum(uptime_pct * subscribers) / sum(subscribers), 3) AS uptime_pct,
         round(sum(health_score * subscribers) / sum(subscribers), 1) AS health_score,
         sum(tickets) AS tickets
  FROM ${catalog}.gold.fiber_hex_daily WHERE res = 9 GROUP BY 1, 2, 3
),
i AS (
  SELECT metro_code, cast(start_ts AS DATE) AS day, count(*) AS incidents, sum(IF(severity = 'P1', 1, 0)) AS p1_incidents,
         sum(IF(sla_breached, 1, 0)) AS sla_breaches, sum(homes_impacted) AS homes_impacted,
         round(avg(IF(status = 'Resolved', outage_min, NULL)), 0) AS mttr_min
  FROM ${catalog}.silver.fiber_incidents GROUP BY 1, 2
)
SELECT h.*, coalesce(i.incidents, 0) AS incidents, coalesce(i.p1_incidents, 0) AS p1_incidents, coalesce(i.sla_breaches, 0) AS sla_breaches,
       coalesce(i.homes_impacted, 0) AS homes_impacted, i.mttr_min
FROM h LEFT JOIN i USING (metro_code, day);

CREATE OR REPLACE TABLE ${catalog}.gold.fiber_technicians
COMMENT 'Field technicians with position and status. Grain: technician. Live (GPS) in production.'
AS SELECT * FROM ${catalog}.silver.fiber_technicians;

CREATE OR REPLACE TABLE ${catalog}.gold.fiber_routes
COMMENT 'Fiber routes (feeder and distribution) with cuts in last 30 days. Grain: route segment. LINESTRING geometry SRID 4326.'
AS SELECT * FROM ${catalog}.silver.fiber_routes;

CREATE OR REPLACE TABLE ${catalog}.gold.fiber_open_tickets
COMMENT 'Open customer trouble tickets. Grain: ticket. Source: silver.fiber_tickets where status = Open.'
AS SELECT * FROM ${catalog}.silver.fiber_tickets WHERE status = 'Open';
