-- Synthetic source data: H3 demographics surface, store master, competitor survey, land bank plots
CREATE OR REPLACE FUNCTION ${catalog}.ref.unif(k STRING) RETURNS DOUBLE
COMMENT 'Deterministic pseudo-uniform [0,1) derived from a key. Used by the synthetic generators.'
RETURN pmod(xxhash64(k), 1000003) / 1000003.0;

CREATE OR REPLACE TABLE ${catalog}.silver.hex_demographics
CLUSTER BY (metro_code)
COMMENT 'Residential demographics per H3 res-9 cell (~0.1 km2). Grain: h3 res 9. Source: synthetic census-style surface from ref.hotspots. Static.'
AS
WITH cells AS (
  SELECT m.metro_code, m.region, m.peak_density_km2,
         explode(h3_polyfillash3(st_astext(st_buffer(st_point(m.center_lon, m.center_lat), m.radius_deg)), 9)) AS h3
  FROM ${catalog}.ref.metros m
),
xy AS (
  SELECT metro_code, region, peak_density_km2, h3,
         st_x(st_geomfromwkt(h3_centeraswkt(h3))) AS lon,
         st_y(st_geomfromwkt(h3_centeraswkt(h3))) AS lat
  FROM cells
),
k AS (
  SELECT x.*, h.locality, h.affluence AS h_aff,
         h.weight * exp(-(power((x.lon - h.lon) * 111.32 * cos(radians(x.lat)), 2) + power((x.lat - h.lat) * 110.57, 2))
                        / (2 * h.sigma_km * h.sigma_km)) AS kern
  FROM xy x JOIN ${catalog}.ref.hotspots h ON x.metro_code = h.metro_code
),
agg AS (
  SELECT metro_code, region, h3, lat, lon, peak_density_km2,
         sum(kern) AS dens_idx,
         sum(kern * h_aff) / greatest(sum(kern), 1e-9) AS aff_raw,
         max_by(locality, kern) AS locality
  FROM k
  GROUP BY metro_code, region, h3, lat, lon, peak_density_km2
),
land AS (
  SELECT * FROM agg
  WHERE NOT (metro_code = 'MUM' AND (lon < 72.80
                                     OR (lat < 19.04 AND lon > 72.87 AND lon < 72.99)
                                     OR (lat BETWEEN 19.04 AND 19.15 AND lon > 72.96 AND lon < 72.995)
                                     OR (lat < 18.90 AND lon < 72.97)))
    AND NOT (metro_code = 'CHE' AND lon > 80.285)
),
pop AS (
  SELECT *,
         cast(round(greatest(0,
              (peak_density_km2 * least(dens_idx, 1.25) * (0.55 + 0.9 * ${catalog}.ref.unif(concat(h3, 'd')))
               + 180 * ${catalog}.ref.unif(concat(h3, 'r'))) * 0.105)) AS INT) AS population,
         least(1.0, greatest(0.0, aff_raw + (${catalog}.ref.unif(concat(h3, 'a')) - 0.5) * 0.25)) AS aff
  FROM land
)
SELECT
  h3,
  h3_toparent(h3, 8) AS h3_r8,
  h3_toparent(h3, 7) AS h3_r7,
  metro_code, region, locality,
  round(lat, 6) AS lat, round(lon, 6) AS lon,
  population,
  cast(round(population / 4.3) AS INT) AS households,
  round(aff, 3) AS affluence_index,
  round(2.5 + 35 * power(aff, 1.7), 1) AS median_hh_income_lakh,
  round(0.24 + 0.14 * ${catalog}.ref.unif(concat(h3, 'y')), 3) AS pct_age_18_35,
  round(least(1.0, 0.35 + 0.5 * aff + 0.15 * ${catalog}.ref.unif(concat(h3, 'g'))), 3) AS digital_adoption_index
FROM pop
WHERE population >= 3;

CREATE OR REPLACE TABLE ${catalog}.bronze.store_master
COMMENT 'Reliance Retail store master extract. Grain: one row per store. Source: synthetic store master (lat/lon as captured by store ops). Refreshed daily in production.'
AS
WITH c AS (
  SELECT d.*, m.store_target,
         sum(d.population) OVER (PARTITION BY d.metro_code) AS metro_pop,
         ${catalog}.ref.unif(concat(d.h3, 'store')) AS u,
         ${catalog}.ref.unif(concat(d.h3, 'fmt')) AS fu,
         ${catalog}.ref.unif(concat(d.h3, 'sq')) AS su
  FROM ${catalog}.silver.hex_demographics d JOIN ${catalog}.ref.metros m USING (metro_code)
),
s AS (
  SELECT *,
    CASE
      WHEN fu < 0.18 THEN 'Smart Bazaar'
      WHEN fu < 0.46 THEN 'Smart Point'
      WHEN fu < 0.51 THEN IF(affluence_index > 0.55, 'Fresh Signature', 'Smart Point')
      WHEN fu < 0.68 THEN 'Trends'
      WHEN fu < 0.80 THEN 'Reliance Digital'
      WHEN fu < 0.85 THEN 'Reliance Jewels'
      WHEN fu < 0.90 THEN IF(affluence_index > 0.45, 'Tira', 'Trends')
      WHEN fu < 0.94 THEN IF(affluence_index > 0.50, 'Azorte', 'Trends')
      WHEN fu < 0.97 THEN 'Centro'
      ELSE 'Reliance Digital'
    END AS format
  FROM c
  WHERE u < store_target * population / metro_pop * (0.7 + 0.6 * affluence_index)
),
n AS (
  SELECT *,
         row_number() OVER (PARTITION BY metro_code ORDER BY h3) AS seq,
         row_number() OVER (PARTITION BY format, locality ORDER BY h3) AS dup
  FROM s
)
SELECT
  concat('RR-', metro_code, '-', lpad(cast(seq AS STRING), 4, '0')) AS store_code,
  concat(format, ' ', locality, IF(dup > 1, concat(' ', cast(dup AS STRING)), '')) AS store_name,
  format, metro_code, region, locality,
  round(lat + (${catalog}.ref.unif(concat(h3, 'jy')) - 0.5) * 0.002, 6) AS latitude,
  round(lon + (${catalog}.ref.unif(concat(h3, 'jx')) - 0.5) * 0.002, 6) AS longitude,
  cast(CASE format
    WHEN 'Smart Bazaar' THEN 25000 + su * 35000
    WHEN 'Smart Point' THEN 1800 + su * 3200
    WHEN 'Fresh Signature' THEN 7000 + su * 8000
    WHEN 'Trends' THEN 7000 + su * 13000
    WHEN 'Reliance Digital' THEN 4000 + su * 9000
    WHEN 'Reliance Jewels' THEN 1800 + su * 3200
    WHEN 'Tira' THEN 1500 + su * 2500
    WHEN 'Azorte' THEN 6000 + su * 6000
    WHEN 'Centro' THEN 25000 + su * 15000
  END AS INT) AS carpet_area_sqft,
  date_add(DATE'2010-01-01', cast(${catalog}.ref.unif(concat(h3, 'od')) * 5600 AS INT)) AS open_date,
  'Operational' AS store_status
FROM n;

CREATE OR REPLACE TABLE ${catalog}.bronze.competitor_outlets
COMMENT 'Competitor outlet survey. Grain: one row per competitor outlet. Source: synthetic field survey / POI feed. Refreshed quarterly.'
AS
WITH c AS (
  SELECT d.*, m.competitor_target,
         sum(d.population) OVER (PARTITION BY d.metro_code) AS metro_pop,
         ${catalog}.ref.unif(concat(d.h3, 'comp')) AS u,
         ${catalog}.ref.unif(concat(d.h3, 'brand')) AS bu
  FROM ${catalog}.silver.hex_demographics d JOIN ${catalog}.ref.metros m USING (metro_code)
),
s AS (
  SELECT *,
    CASE
      WHEN bu < 0.14 THEN 'DMart' WHEN bu < 0.24 THEN 'More Retail' WHEN bu < 0.30 THEN 'Spencer''s'
      WHEN bu < 0.34 THEN 'Star Bazaar' WHEN bu < 0.44 THEN 'Blinkit Dark Store' WHEN bu < 0.52 THEN 'Zepto Dark Store'
      WHEN bu < 0.62 THEN 'Zudio' WHEN bu < 0.68 THEN 'Westside' WHEN bu < 0.74 THEN 'Max Fashion'
      WHEN bu < 0.77 THEN 'Lifestyle' WHEN bu < 0.80 THEN 'Pantaloons' WHEN bu < 0.86 THEN 'Croma'
      WHEN bu < 0.90 THEN 'Vijay Sales' WHEN bu < 0.93 THEN 'Tanishq' WHEN bu < 0.95 THEN 'Kalyan Jewellers'
      WHEN bu < 0.98 THEN 'Nykaa Luxe' ELSE 'Health & Glow'
    END AS brand,
    round(lat + (${catalog}.ref.unif(concat(h3, 'cy')) - 0.5) * 0.002, 6) AS latitude,
    round(lon + (${catalog}.ref.unif(concat(h3, 'cx')) - 0.5) * 0.002, 6) AS longitude
  FROM c
  WHERE u < competitor_target * population / metro_pop
)
SELECT
  concat('CMP-', metro_code, '-', lpad(cast(row_number() OVER (PARTITION BY metro_code ORDER BY h3) AS STRING), 5, '0')) AS outlet_id,
  brand,
  CASE
    WHEN brand IN ('DMart','More Retail','Spencer''s','Star Bazaar','Blinkit Dark Store','Zepto Dark Store') THEN 'Grocery'
    WHEN brand IN ('Zudio','Westside','Max Fashion','Lifestyle','Pantaloons') THEN 'Fashion'
    WHEN brand IN ('Croma','Vijay Sales') THEN 'Electronics'
    WHEN brand IN ('Tanishq','Kalyan Jewellers') THEN 'Jewellery'
    ELSE 'Beauty'
  END AS category_group,
  metro_code, region, locality, latitude, longitude
FROM s;

CREATE OR REPLACE TABLE ${catalog}.bronze.land_bank_plots
COMMENT 'Candidate land plots from the real-estate land bank. Grain: one row per plot. Source: synthetic broker / development-authority feed, boundary as WKT. Refreshed weekly.'
AS
WITH c AS (
  SELECT d.*, m.plot_target,
         sum(sqrt(d.population)) OVER (PARTITION BY d.metro_code) AS metro_sqrt_pop,
         ${catalog}.ref.unif(concat(d.h3, 'plot')) AS u,
         ${catalog}.ref.unif(concat(d.h3, 'area')) AS au,
         ${catalog}.ref.unif(concat(d.h3, 'asp')) AS asp,
         ${catalog}.ref.unif(concat(d.h3, 'rot')) AS ru,
         ${catalog}.ref.unif(concat(d.h3, 'z')) AS zu,
         ${catalog}.ref.unif(concat(d.h3, 'p')) AS pu
  FROM ${catalog}.silver.hex_demographics d JOIN ${catalog}.ref.metros m USING (metro_code)
  WHERE d.population > 40
),
s AS (
  SELECT *,
         1500 + power(au, 2) * 28000 AS area_sqm,
         1.2 + asp * 1.3 AS aspect,
         ru * pi() AS t
  FROM c
  WHERE u < plot_target * sqrt(population) / metro_sqrt_pop
),
g AS (
  SELECT *,
         sqrt(area_sqm * aspect) / 2 AS hx,
         area_sqm / sqrt(area_sqm * aspect) / 2 AS hy
  FROM s
)
SELECT
  concat('PLT-', metro_code, '-', lpad(cast(row_number() OVER (PARTITION BY metro_code ORDER BY h3) AS STRING), 4, '0')) AS plot_id,
  metro_code, region, locality,
  round(area_sqm) AS area_sqm,
  CASE WHEN zu < 0.40 THEN 'Commercial' WHEN zu < 0.70 THEN 'Mixed Use' WHEN zu < 0.80 THEN 'Industrial' ELSE 'Residential (convertible)' END AS zoning,
  cast(round((2500 + 22000 * power(affluence_index, 1.5) * (0.7 + 0.6 * pu))
       * CASE metro_code WHEN 'MUM' THEN 1.8 WHEN 'DEL' THEN 1.4 WHEN 'BLR' THEN 1.2 ELSE 1.0 END, -1) AS INT) AS ask_price_inr_per_sqft,
  cast(round(sqrt(area_sqm) * (0.6 + 0.6 * asp)) AS INT) AS frontage_m,
  CASE WHEN pu < 0.25 THEN 'Arterial road' WHEN pu < 0.70 THEN 'Main road' ELSE 'Internal road' END AS road_access,
  IF(zu * 7 % 1 < 0.6, 'Lease', 'Outright purchase') AS transaction_type,
  CASE WHEN asp < 0.70 THEN 'Available' WHEN asp < 0.90 THEN 'Under negotiation' ELSE 'Shortlisted' END AS plot_status,
  concat('POLYGON((', array_join(transform(
    array(named_struct('x', hx, 'y', hy), named_struct('x', -hx, 'y', hy), named_struct('x', -hx, 'y', -hy),
          named_struct('x', hx, 'y', -hy), named_struct('x', hx, 'y', hy)),
    p -> format_string('%.7f %.7f',
           lon + (p.x * cos(t) - p.y * sin(t)) / (111320 * cos(radians(lat))),
           lat + (p.x * sin(t) + p.y * cos(t)) / 110570)), ', '), '))') AS boundary_wkt
FROM g;
