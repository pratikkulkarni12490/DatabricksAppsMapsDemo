-- Jio Fiber Home: synthetic network topology, subscribers, 30-day telemetry, incidents, tickets, field force
-- Window: 2026-09-10 00:00 UTC to as-of 2026-10-10 06:00 UTC (11:30 IST). Same metros / regions as retail.

CREATE OR REPLACE TABLE ${catalog}.silver.fiber_coverage
CLUSTER BY (metro_code)
COMMENT 'Jio Fiber coverage per H3 res-9 cell: homes passed, homes connected, serving OLT and FDH. Grain: h3 res 9. Source: synthetic network inventory. Refreshed daily.'
AS
WITH d AS (
  SELECT h3, h3_r8, h3_r7, h3_toparent(h3, 6) AS h3_r6, metro_code, region, locality, lat, lon, households,
         affluence_index, digital_adoption_index,
         ${catalog}.ref.unif(concat(h3, 'cov')) AS u1, ${catalog}.ref.unif(concat(h3, 'pen')) AS u2,
         ${catalog}.ref.unif(concat(h3, 'vin')) AS u3
  FROM ${catalog}.silver.hex_demographics
),
c AS (
  SELECT *,
         cast(round(households * least(0.97, 0.45 + 0.40 * digital_adoption_index + 0.10 * u1)) AS INT) AS homes_passed,
         least(0.75, 0.12 + 0.45 * digital_adoption_index * (0.6 + 0.8 * u2)) AS pen
  FROM d
),
s AS (SELECT *, cast(round(homes_passed * pen) AS INT) AS homes_connected FROM c WHERE households > 0),
o AS (
  SELECT *, greatest(1, cast(ceil(sum(homes_connected) OVER (PARTITION BY h3_r7) / 2000.0) AS INT)) AS n_olt FROM s
)
SELECT h3, h3_r8, h3_r7, h3_r6, metro_code, region, locality, lat, lon, households, homes_passed, homes_connected,
       round(homes_connected / greatest(homes_passed, 1), 4) AS penetration,
       concat('OLT-', metro_code, '-', h3_h3tostring(h3_r7), '-', cast(pmod(xxhash64(h3, 'olt'), n_olt) + 1 AS STRING)) AS olt_id,
       concat('FDH-', h3_h3tostring(h3_r8)) AS fdh_id,
       -- network was rolled out area by area: vintage follows the OLT area (res 7), with a little cell-level variation
       least(2025, 2016 + cast(${catalog}.ref.unif(concat(h3_r7, 'vin')) * 9 AS INT) + IF(u3 > 0.85, 1, 0)) AS fiber_vintage_year,
       affluence_index, digital_adoption_index
FROM o;

CREATE OR REPLACE TABLE ${catalog}.silver.fiber_olts
COMMENT 'Optical Line Terminals. Grain: OLT. Source: synthetic network inventory (NMS). Refreshed daily.'
AS
WITH a AS (
  SELECT olt_id, metro_code, region, max_by(locality, homes_connected) AS locality, h3_r7, h3_r6,
         sum(homes_connected) AS homes_connected, sum(homes_passed) AS homes_passed,
         sum(lat * homes_connected) / greatest(sum(homes_connected), 1) AS w_lat,
         sum(lon * homes_connected) / greatest(sum(homes_connected), 1) AS w_lon,
         min(fiber_vintage_year) AS vintage
  FROM ${catalog}.silver.fiber_coverage GROUP BY olt_id, metro_code, region, h3_r7, h3_r6
),
b AS (
  SELECT *, ${catalog}.ref.unif(concat(olt_id, 'cap')) AS uc, ${catalog}.ref.unif(concat(olt_id, 'v')) AS uv FROM a
  WHERE homes_connected > 0
)
SELECT olt_id,
       concat(locality, ' OLT ', substr(olt_id, -1)) AS olt_name,
       metro_code, region, locality,
       round(w_lat, 6) AS latitude, round(w_lon, 6) AS longitude,
       h3_longlatash3(w_lon, w_lat, 9) AS h3_r9,
       concat('AGG-', metro_code, '-', h3_h3tostring(h3_r6)) AS agg_node_id,
       CASE WHEN uv < 0.5 THEN 'Huawei MA5800' WHEN uv < 0.8 THEN 'Nokia Lightspan' ELSE 'ZTE C600' END AS vendor_model,
       -- capacity normally sized at ~70% fill; ~12% of OLTs are growth pockets running hot
       cast(ceil(homes_connected / 32.0 / IF(uc < 0.12, 0.93 + 0.05 * uc / 0.12, 0.60 + 0.25 * uc) / 8) * 8 AS INT) AS pon_ports,
       32 AS split_ratio,
       homes_connected, homes_passed,
       vintage AS commissioned_year
FROM b;

CREATE OR REPLACE TABLE ${catalog}.silver.fiber_fdh
COMMENT 'Fibre Distribution Hubs (splitter cabinets). Grain: FDH (one per H3 res-8 cell with coverage). Source: synthetic network inventory. Refreshed daily.'
AS
SELECT fdh_id, max_by(olt_id, homes_connected) AS olt_id, metro_code, region, max_by(locality, homes_connected) AS locality,
       h3_r8,
       round(st_y(st_geomfromwkt(h3_centeraswkt(h3_r8))), 6) AS latitude,
       round(st_x(st_geomfromwkt(h3_centeraswkt(h3_r8))), 6) AS longitude,
       sum(homes_connected) AS homes_connected, sum(homes_passed) AS homes_passed,
       min(fiber_vintage_year) AS fiber_vintage_year
FROM ${catalog}.silver.fiber_coverage
GROUP BY fdh_id, metro_code, region, h3_r8
HAVING sum(homes_connected) > 0;

CREATE OR REPLACE TABLE ${catalog}.silver.fiber_subscribers
CLUSTER BY (metro_code)
COMMENT 'Jio Fiber home subscribers (one ONT per home), located to home H3 res-9 cell. Grain: subscriber. Source: synthetic BSS/OSS. Refreshed daily.'
AS
WITH e AS (
  SELECT c.*, k FROM ${catalog}.silver.fiber_coverage c
  LATERAL VIEW explode(sequence(1, homes_connected)) t AS k
  WHERE homes_connected > 0
),
u AS (
  SELECT *, xxhash64(h3, k, 'sub') AS subscriber_id,
         pmod(xxhash64(h3, k, 'pl'), 1000003) / 1000003.0 AS up,
         pmod(xxhash64(h3, k, 'act'), 1000003) / 1000003.0 AS ua,
         pmod(xxhash64(h3, k, 'ont'), 1000003) / 1000003.0 AS uo
  FROM e
)
SELECT subscriber_id, h3 AS home_h3_r9, h3_r8 AS home_h3_r8, metro_code, region, olt_id, fdh_id,
       CASE WHEN up + 0.35 * affluence_index > 1.10 THEN '1 Gbps' WHEN up + 0.35 * affluence_index > 0.85 THEN '300 Mbps'
            WHEN up + 0.35 * affluence_index > 0.45 THEN '100 Mbps' ELSE '30 Mbps' END AS plan,
       date_add(DATE'2019-09-05', cast(ua * 2550 AS INT)) AS activation_date,
       CASE WHEN uo < 0.45 THEN 'JioFiber ONT G2' WHEN uo < 0.8 THEN 'JioFiber ONT G3 (Wi-Fi 6)' ELSE 'JioFiber ONT G1 (legacy)' END AS ont_model
FROM u;

CREATE OR REPLACE TABLE ${catalog}.silver.fiber_incidents
CLUSTER BY (metro_code)
COMMENT 'Network incidents (outages and degradations) 2026-09-10 to 2026-10-10. Grain: incident. Source: synthetic NOC fault management. Includes a cyclone event in Chennai (2026-10-03) and a construction fiber-cut cluster in Gurugram.'
AS
WITH olt_day AS (
  SELECT o.olt_id, NULL AS fdh_id, o.metro_code, o.region, o.locality, o.latitude, o.longitude, o.homes_connected,
         o.commissioned_year, d.day, 'OLT' AS lvl,
         pmod(xxhash64(o.olt_id, d.day, 'h'), 1000003) / 1000003.0 AS uh,
         pmod(xxhash64(o.olt_id, d.day, 't'), 1000003) / 1000003.0 AS ut,
         pmod(xxhash64(o.olt_id, d.day, 's'), 1000003) / 1000003.0 AS us,
         pmod(xxhash64(o.olt_id, d.day, 'd'), 1000003) / 1000003.0 AS ud
  FROM ${catalog}.silver.fiber_olts o CROSS JOIN (SELECT explode(sequence(0, 30)) AS day) d
),
fdh_day AS (
  SELECT f.olt_id, f.fdh_id, f.metro_code, f.region, f.locality, f.latitude, f.longitude, f.homes_connected,
         f.fiber_vintage_year AS commissioned_year, d.day, 'FDH' AS lvl,
         pmod(xxhash64(f.fdh_id, d.day, 'h'), 1000003) / 1000003.0 AS uh,
         pmod(xxhash64(f.fdh_id, d.day, 't'), 1000003) / 1000003.0 AS ut,
         pmod(xxhash64(f.fdh_id, d.day, 's'), 1000003) / 1000003.0 AS us,
         pmod(xxhash64(f.fdh_id, d.day, 'd'), 1000003) / 1000003.0 AS ud
  FROM ${catalog}.silver.fiber_fdh f CROSS JOIN (SELECT explode(sequence(0, 30)) AS day) d
),
cand AS (SELECT * FROM olt_day UNION ALL SELECT * FROM fdh_day),
hz AS (
  SELECT *,
    (IF(lvl = 'OLT', 0.014, 0.018)
     * (1 + 0.06 * (2025 - commissioned_year))
     * IF(metro_code IN ('MUM', 'KOL', 'CHE'), 1.3, 1.0)
     * IF(metro_code = 'CHE' AND day BETWEEN 23 AND 25, 9.0, 1.0)
     * IF(metro_code = 'DEL' AND locality = 'Gurugram' AND day >= 18, 4.0, 1.0)) AS hazard
  FROM cand
),
ev AS (
  SELECT *,
    CASE WHEN lvl = 'OLT' THEN
           CASE WHEN ut < 0.45 THEN 'Power failure' WHEN ut < 0.65 THEN 'OLT card failure'
                WHEN ut < 0.90 THEN 'Feeder fiber cut' ELSE 'Planned maintenance' END
         ELSE
           CASE WHEN ut < 0.50 THEN 'Distribution fiber cut' WHEN ut < 0.65 THEN 'FDH damage' ELSE 'LOS alarm cluster' END
    END AS incident_type
  FROM hz WHERE uh < hazard
),
dur AS (
  SELECT *,
    cast(CASE incident_type
      WHEN 'Power failure' THEN 30 + 270 * ud * ud WHEN 'OLT card failure' THEN 60 + 180 * ud
      WHEN 'Feeder fiber cut' THEN 120 + 600 * ud * ud WHEN 'Planned maintenance' THEN 60 + 180 * ud
      WHEN 'Distribution fiber cut' THEN 90 + 390 * ud * ud WHEN 'FDH damage' THEN 60 + 300 * ud
      ELSE 30 + 150 * ud END
      * IF(metro_code = 'CHE' AND day BETWEEN 23 AND 25, 2.5, 1.0) AS INT) AS duration_min,
    cast(homes_connected * CASE incident_type WHEN 'OLT card failure' THEN 0.125 WHEN 'LOS alarm cluster' THEN 0.1 + 0.3 * us
                                              WHEN 'FDH damage' THEN 0.5 ELSE 1.0 END AS INT) AS homes_impacted,
    timestampadd(SECOND, cast(us * IF(day = 30, 21600, 86400) AS INT), timestampadd(DAY, day, TIMESTAMP'2026-09-10 00:00:00')) AS start_ts
  FROM ev
),
sev AS (
  SELECT *,
    CASE WHEN incident_type = 'Planned maintenance' THEN 'P4'
         WHEN homes_impacted > 1000 THEN 'P1' WHEN homes_impacted > 300 THEN 'P2' WHEN homes_impacted > 50 THEN 'P3' ELSE 'P4' END AS severity,
    timestampadd(MINUTE, duration_min, start_ts) AS end_ts
  FROM dur
)
SELECT
  concat('INC-', date_format(start_ts, 'yyMMdd'), '-', lpad(cast(pmod(xxhash64(coalesce(fdh_id, olt_id), day), 1000000) AS STRING), 6, '0')) AS incident_id,
  incident_type, severity, lvl AS network_level, olt_id, fdh_id, metro_code, region, locality,
  round(latitude + (us - 0.5) * 0.004, 6) AS latitude, round(longitude + (ud - 0.5) * 0.004, 6) AS longitude,
  h3_longlatash3(longitude, latitude, 9) AS h3_r9,
  homes_impacted, start_ts,
  IF(end_ts > TIMESTAMP'2026-10-10 06:00:00', NULL, end_ts) AS end_ts,
  IF(end_ts > TIMESTAMP'2026-10-10 06:00:00', 'Open', 'Resolved') AS status,
  duration_min AS outage_min,
  CASE WHEN incident_type LIKE '%fiber cut%' THEN
         CASE WHEN metro_code = 'DEL' AND locality = 'Gurugram' AND day >= 18 THEN 'Civil works (metro construction)'
              WHEN metro_code = 'CHE' AND day BETWEEN 23 AND 25 THEN 'Cyclone damage'
              WHEN ut < 0.3 THEN 'Civil works (third party)' WHEN ut < 0.5 THEN 'Rodent damage'
              WHEN ut < 0.7 THEN 'Waterlogging' WHEN ut < 0.85 THEN 'Vehicle hit pole' ELSE 'Vandalism' END
       WHEN incident_type = 'Power failure' THEN IF(us < 0.6, 'Grid outage, battery exhausted', 'DG set failure')
       WHEN incident_type = 'OLT card failure' THEN 'Line card hardware fault'
       WHEN incident_type = 'FDH damage' THEN IF(metro_code = 'CHE' AND day BETWEEN 23 AND 25, 'Cyclone damage', 'Cabinet damage')
       WHEN incident_type = 'LOS alarm cluster' THEN 'Macro-bend / connector degradation'
       ELSE 'Scheduled software upgrade' END AS root_cause,
  duration_min > CASE severity WHEN 'P1' THEN 240 WHEN 'P2' THEN 480 WHEN 'P3' THEN 1440 ELSE 2880 END AS sla_breached
FROM sev;

CREATE OR REPLACE TABLE ${catalog}.silver.fiber_hex_daily
CLUSTER BY (metro_code, day)
COMMENT 'Daily network experience per H3 res-9 cell: ONT optical power, latency, packet loss, throughput vs plan, uptime, tickets. Grain: h3 res 9 x day. Source: synthetic ONT telemetry (TR-069 / NMS) aggregated. Refreshed hourly in production.'
AS
WITH base AS (
  SELECT c.h3, c.h3_r8, c.metro_code, c.region, c.olt_id, c.fdh_id, c.homes_connected, c.fiber_vintage_year,
         o.pon_ports, o.homes_connected AS olt_homes,
         sqrt(power((c.lon - o.longitude) * 111.32 * cos(radians(c.lat)), 2) + power((c.lat - o.latitude) * 110.57, 2)) AS dist_km
  FROM ${catalog}.silver.fiber_coverage c JOIN ${catalog}.silver.fiber_olts o USING (olt_id)
  WHERE c.homes_connected > 0
),
days AS (SELECT explode(sequence(DATE'2026-09-10', DATE'2026-10-09')) AS day),
bd AS (
  SELECT b.*, d.day,
         0.35 * pmod(xxhash64(b.h3, d.day), 1000003) / 1000003.0 + 0.65 * pmod(xxhash64(b.olt_id, d.day), 1000003) / 1000003.0 AS un,
         pmod(xxhash64(b.h3, d.day, 'k'), 1000003) / 1000003.0 AS uk,
         olt_homes / (pon_ports * 32.0) AS fill
  FROM base b CROSS JOIN days d
),
outage AS (
  SELECT h.h3, cast(i.start_ts AS DATE) AS day,
         sum(least(i.outage_min, 1440) * IF(i.incident_type IN ('OLT card failure', 'LOS alarm cluster', 'FDH damage'), 0.35, 1.0)) AS down_min,
         count(*) AS incidents
  FROM ${catalog}.silver.fiber_incidents i
  JOIN ${catalog}.silver.fiber_coverage h
    ON (i.network_level = 'OLT' AND h.olt_id = i.olt_id) OR (i.network_level = 'FDH' AND h.fdh_id = i.fdh_id)
  GROUP BY h.h3, cast(i.start_ts AS DATE)
)
SELECT bd.h3, bd.h3_r8, bd.metro_code, bd.region, bd.olt_id, bd.fdh_id, bd.day,
       bd.homes_connected AS subscribers,
       round(-17.5 - 0.9 * bd.dist_km - 0.35 * (2025 - bd.fiber_vintage_year) - 2.5 * bd.un, 2) AS avg_rx_power_dbm,
       round(least(60, 100 * power(greatest(0, (0.9 * bd.dist_km + 0.35 * (2025 - bd.fiber_vintage_year) + 2.5 * bd.un - 3.2) / 4.0), 2)), 2) AS pct_ont_low_power,
       round(5 + 3 * bd.un + 22 * power(greatest(0, bd.fill - 0.75), 1) * 4, 1) AS avg_latency_ms,
       round(0.05 + 0.25 * bd.un * bd.uk + 2.5 * greatest(0, bd.fill - 0.85), 3) AS packet_loss_pct,
       round(least(1.0, 0.97 - 0.9 * greatest(0, bd.fill - 0.80) - 0.04 * bd.uk), 3) AS throughput_vs_plan,
       round(100 * (1 - least(1440, coalesce(o.down_min, 0)) / 1440.0), 3) AS uptime_pct,
       coalesce(o.incidents, 0) AS incidents,
       cast(floor(bd.homes_connected * (0.0012 + 0.0009 * bd.un + 0.012 * coalesce(o.down_min, 0) / 1440.0
                  + 0.0015 * greatest(0, bd.fill - 0.85) * 10) + bd.uk) AS INT) AS tickets
FROM bd LEFT JOIN outage o ON o.h3 = bd.h3 AND o.day = bd.day;

CREATE OR REPLACE TABLE ${catalog}.silver.fiber_olt_hourly
CLUSTER BY (metro_code, hour_ts)
COMMENT 'Hourly OLT performance: PON and uplink utilisation, active ONTs, alarms, CPU, temperature, status. Grain: OLT x hour (UTC). Source: synthetic NMS polling. Refreshed every 5 min in production.'
AS
WITH h AS (SELECT explode(sequence(TIMESTAMP'2026-09-10 00:00:00', TIMESTAMP'2026-10-10 05:00:00', INTERVAL 1 HOUR)) AS hour_ts),
b AS (
  SELECT o.olt_id, o.metro_code, o.region, o.homes_connected, o.pon_ports,
         o.homes_connected / (o.pon_ports * 32.0) AS fill, h.hour_ts,
         (hour(h.hour_ts) + 5.5) % 24 AS ist_h,
         pmod(xxhash64(o.olt_id, h.hour_ts), 1000003) / 1000003.0 AS un
  FROM ${catalog}.silver.fiber_olts o CROSS JOIN h
),
down AS (
  SELECT b.olt_id, b.hour_ts, max(IF(i.incident_type IN ('Power failure', 'Feeder fiber cut', 'Planned maintenance'), 1.0, 0.125)) AS frac_down,
         count(*) AS alarms
  FROM b JOIN ${catalog}.silver.fiber_incidents i
    ON i.network_level = 'OLT' AND i.olt_id = b.olt_id
   AND b.hour_ts >= date_trunc('HOUR', i.start_ts)
   AND b.hour_ts < coalesce(i.end_ts, TIMESTAMP'2026-10-10 06:00:00')
  GROUP BY b.olt_id, b.hour_ts
)
SELECT b.olt_id, b.metro_code, b.region, b.hour_ts,
       round(least(100, 100 * b.fill * 1.05 * (0.30 + 0.70 * exp(-power(b.ist_h - 21.5, 2) / 18.0) + 0.15 * exp(-power(b.ist_h - 13, 2) / 8.0))
             * (0.92 + 0.16 * b.un) * (1 - coalesce(d.frac_down, 0))), 1) AS pon_util_pct,
       round(least(100, 100 * b.fill * 0.95 * (0.25 + 0.75 * exp(-power(b.ist_h - 21.5, 2) / 18.0)) * (0.9 + 0.2 * b.un)
             * (1 - coalesce(d.frac_down, 0))), 1) AS uplink_util_pct,
       cast(b.homes_connected * (1 - coalesce(d.frac_down, 0)) * (0.82 + 0.12 * exp(-power(b.ist_h - 21.5, 2) / 18.0)) AS INT) AS active_onts,
       coalesce(d.alarms, 0) + cast(b.un * 1.6 AS INT) AS alarms,
       round(18 + 45 * b.fill * (0.4 + 0.6 * exp(-power(b.ist_h - 21.5, 2) / 18.0)) + 8 * b.un, 1) AS cpu_pct,
       round(38 + 8 * b.un + 6 * exp(-power(b.ist_h - 15, 2) / 12.0), 1) AS temp_c,
       CASE WHEN d.frac_down >= 1 THEN 'Down' WHEN d.frac_down > 0 THEN 'Degraded' ELSE 'Up' END AS status
FROM b LEFT JOIN down d ON d.olt_id = b.olt_id AND d.hour_ts = b.hour_ts;

CREATE OR REPLACE TABLE ${catalog}.silver.fiber_tickets
CLUSTER BY (metro_code)
COMMENT 'Customer trouble tickets. Grain: ticket. Source: synthetic CRM (expanded from fiber_hex_daily ticket counts). Refreshed every 15 min in production.'
AS
WITH e AS (
  SELECT d.h3, d.metro_code, d.region, d.olt_id, d.fdh_id, d.day, d.incidents, k
  FROM ${catalog}.silver.fiber_hex_daily d LATERAL VIEW explode(sequence(1, d.tickets)) t AS k
  WHERE d.tickets > 0
),
u AS (
  SELECT *, xxhash64(h3, day, k, 'tk') AS tk,
         pmod(xxhash64(h3, day, k, 'c'), 1000003) / 1000003.0 AS uc,
         pmod(xxhash64(h3, day, k, 'r'), 1000003) / 1000003.0 AS ur,
         pmod(xxhash64(h3, day, k, 's'), 1000003) / 1000003.0 AS us
  FROM e
)
SELECT concat('TKT-', lpad(cast(pmod(tk, 10000000000) AS STRING), 10, '0')) AS ticket_id,
       h3 AS home_h3_r9, metro_code, region, olt_id, fdh_id,
       timestampadd(SECOND, cast(us * 86400 AS INT), cast(day AS TIMESTAMP)) AS created_ts,
       CASE WHEN incidents > 0 AND uc < 0.6 THEN 'No internet'
            WHEN uc < 0.25 THEN 'No internet' WHEN uc < 0.50 THEN 'Slow speed' WHEN uc < 0.68 THEN 'Wi-Fi coverage'
            WHEN uc < 0.80 THEN 'JioTV+ / IPTV' WHEN uc < 0.92 THEN 'Billing' ELSE 'Relocation' END AS ticket_type,
       CASE WHEN day >= DATE'2026-10-08' AND ur < 0.35 THEN 'Open' WHEN day >= DATE'2026-10-03' AND ur < 0.06 THEN 'Open' ELSE 'Resolved' END AS status,
       round(1.5 + 30 * ur * ur + IF(incidents > 0, 6, 0), 1) AS resolution_hours,
       ur > 0.22 AS first_time_fix
FROM u;

CREATE OR REPLACE TABLE ${catalog}.silver.fiber_technicians
COMMENT 'Field technicians with current position and status (as of 2026-10-10 06:00 UTC). Grain: technician. Source: synthetic workforce management (WFM) GPS feed. Live in production.'
AS
WITH o AS (
  SELECT olt_id, metro_code, region, locality, latitude, longitude,
         greatest(1, cast(round(homes_connected / 1300.0) AS INT)) AS n
  FROM ${catalog}.silver.fiber_olts
),
e AS (SELECT o.*, k FROM o LATERAL VIEW explode(sequence(1, n)) t AS k),
u AS (
  SELECT *, pmod(xxhash64(olt_id, k, 'a'), 1000003) / 1000003.0 AS ua,
         pmod(xxhash64(olt_id, k, 'b'), 1000003) / 1000003.0 AS ub,
         pmod(xxhash64(olt_id, k, 'c'), 1000003) / 1000003.0 AS uc
  FROM e
)
SELECT concat('TECH-', metro_code, '-', lpad(cast(row_number() OVER (PARTITION BY metro_code ORDER BY olt_id, k) AS STRING), 4, '0')) AS technician_id,
       metro_code, region, locality, olt_id AS home_olt_id,
       CASE WHEN ua < 0.40 THEN 'CPE / Wi-Fi' WHEN ua < 0.75 THEN 'Fiber splicing' WHEN ua < 0.92 THEN 'Outside plant' ELSE 'OLT / Active equipment' END AS skill,
       CASE WHEN ub < 0.38 THEN 'Available' WHEN ub < 0.60 THEN 'En route' WHEN ub < 0.90 THEN 'On job' ELSE 'Off shift' END AS status,
       round(latitude + (uc - 0.5) * 0.05, 6) AS latitude,
       round(longitude + (ua - 0.5) * 0.05, 6) AS longitude
FROM u;

CREATE OR REPLACE TABLE ${catalog}.silver.fiber_routes
COMMENT 'Fiber cable routes: feeder (aggregation node to OLT) and distribution (OLT to FDH) as LINESTRING geometry. Grain: route segment. Source: synthetic GIS network inventory. Refreshed weekly.'
AS
WITH agg AS (
  SELECT agg_node_id, metro_code, avg(latitude) AS lat, avg(longitude) AS lon FROM ${catalog}.silver.fiber_olts GROUP BY agg_node_id, metro_code
),
feeder AS (
  SELECT concat('FDR-', o.olt_id) AS route_id, 'Feeder' AS route_type, o.agg_node_id AS from_node, o.olt_id AS to_node,
         o.metro_code, o.region, o.olt_id, a.lon AS x1, a.lat AS y1, o.longitude AS x2, o.latitude AS y2, o.commissioned_year AS vintage
  FROM ${catalog}.silver.fiber_olts o JOIN agg a USING (agg_node_id)
),
dist AS (
  SELECT concat('DST-', f.fdh_id) AS route_id, 'Distribution' AS route_type, f.olt_id AS from_node, f.fdh_id AS to_node,
         f.metro_code, f.region, f.olt_id, o.longitude AS x1, o.latitude AS y1, f.longitude AS x2, f.latitude AS y2, f.fiber_vintage_year AS vintage
  FROM ${catalog}.silver.fiber_fdh f JOIN ${catalog}.silver.fiber_olts o USING (olt_id)
),
r AS (SELECT * FROM feeder UNION ALL SELECT * FROM dist),
cuts AS (
  SELECT coalesce(concat('DST-', fdh_id), concat('FDR-', olt_id)) AS route_id, count(*) AS cuts_30d
  FROM ${catalog}.silver.fiber_incidents WHERE incident_type LIKE '%fiber cut%' GROUP BY 1
)
SELECT r.route_id, route_type, from_node, to_node, metro_code, region, olt_id, vintage AS laid_year,
       round(st_distancesphere(st_point(x1, y1), st_point(x2, y2)) / 1000 * 1.3, 3) AS route_km,
       coalesce(c.cuts_30d, 0) AS cuts_30d,
       st_geomfromwkt(format_string('LINESTRING(%.6f %.6f, %.6f %.6f)', x1, y1, x2, y2), 4326) AS geom
FROM r LEFT JOIN cuts c USING (route_id)
WHERE x1 IS NOT NULL;
