-- Gold (Retail): H3 rollups res 5-9 with tile keys, store KPIs, catchments, plot site-selection scores
-- tile_h3 = parent at (res - 3): the app fetches hexes one tile at a time so responses are cacheable and shared across users

CREATE OR REPLACE TABLE ${catalog}.gold.retail_hex_monthly
CLUSTER BY (res, tile_h3)
COMMENT 'Customer demand by home H3 cell and month, rolled up to res 5-9. Grain: h3 (any res) x month. Source: silver.orders. Refreshed daily. revenue columns in INR.'
AS
WITH b AS (
  SELECT home_h3_r9 AS h3, metro_code, region, order_month AS month,
         count(*) AS orders, sum(amount_inr) AS revenue,
         sum(IF(category = 'Grocery', amount_inr, 0)) AS rev_grocery,
         sum(IF(category = 'Fresh', amount_inr, 0)) AS rev_fresh,
         sum(IF(category = 'Fashion', amount_inr, 0)) AS rev_fashion,
         sum(IF(category = 'Home', amount_inr, 0)) AS rev_home,
         sum(IF(category = 'Beauty', amount_inr, 0)) AS rev_beauty,
         sum(IF(category = 'Electronics', amount_inr, 0)) AS rev_electronics,
         sum(IF(category = 'Jewellery', amount_inr, 0)) AS rev_jewellery,
         sum(IF(channel = 'JioMart', amount_inr, 0)) AS rev_jiomart,
         count(DISTINCT customer_id) AS active_customers
  FROM ${catalog}.silver.orders
  GROUP BY home_h3_r9, metro_code, region, order_month
),
r AS (SELECT b.*, res FROM b LATERAL VIEW explode(array(5, 6, 7, 8, 9)) t AS res)
SELECT h3_toparent(h3, res) AS h3, res, h3_toparent(h3, res - 3) AS tile_h3, metro_code, region, month,
       sum(orders) AS orders, round(sum(revenue), 0) AS revenue,
       round(sum(rev_grocery), 0) AS rev_grocery, round(sum(rev_fresh), 0) AS rev_fresh, round(sum(rev_fashion), 0) AS rev_fashion,
       round(sum(rev_home), 0) AS rev_home, round(sum(rev_beauty), 0) AS rev_beauty, round(sum(rev_electronics), 0) AS rev_electronics,
       round(sum(rev_jewellery), 0) AS rev_jewellery, round(sum(rev_jiomart), 0) AS rev_jiomart,
       sum(active_customers) AS active_customers
FROM r
GROUP BY h3_toparent(h3, res), res, h3_toparent(h3, res - 3), metro_code, region, month;

CREATE OR REPLACE TABLE ${catalog}.gold.retail_hex_profile
CLUSTER BY (res, tile_h3)
COMMENT 'Static market profile per H3 cell, res 5-9: population, households, affluence, Reliance customers and penetration, 12-month revenue, store and competitor counts, white-space score (0-100, higher = more untapped demand). Grain: h3 (any res). Refreshed daily.'
AS
WITH cust AS (SELECT home_h3_r9 AS h3, count(*) AS customers FROM ${catalog}.silver.customers GROUP BY 1),
rev AS (SELECT home_h3_r9 AS h3, sum(amount_inr) AS revenue_12m, count(*) AS orders_12m FROM ${catalog}.silver.orders GROUP BY 1),
st AS (SELECT h3_r9 AS h3, count(*) AS stores FROM ${catalog}.silver.stores GROUP BY 1),
cp AS (SELECT h3_r9 AS h3, count(*) AS competitors FROM ${catalog}.silver.competitors GROUP BY 1),
b AS (
  SELECT d.h3, d.metro_code, d.region, d.population, d.households, d.affluence_index, d.median_hh_income_lakh,
         coalesce(c.customers, 0) AS customers, coalesce(r.revenue_12m, 0) AS revenue_12m, coalesce(r.orders_12m, 0) AS orders_12m,
         coalesce(s.stores, 0) AS stores, coalesce(p.competitors, 0) AS competitors
  FROM ${catalog}.silver.hex_demographics d
  LEFT JOIN cust c ON c.h3 = d.h3 LEFT JOIN rev r ON r.h3 = d.h3 LEFT JOIN st s ON s.h3 = d.h3 LEFT JOIN cp p ON p.h3 = d.h3
),
r AS (SELECT b.*, res FROM b LATERAL VIEW explode(array(5, 6, 7, 8, 9)) t AS res),
a AS (
  SELECT h3_toparent(h3, res) AS h3, res, h3_toparent(h3, res - 3) AS tile_h3, metro_code, region,
         sum(population) AS population, sum(households) AS households,
         round(sum(affluence_index * population) / greatest(sum(population), 1), 3) AS affluence_index,
         round(sum(median_hh_income_lakh * households) / greatest(sum(households), 1), 1) AS median_hh_income_lakh,
         sum(customers) AS customers, round(sum(revenue_12m), 0) AS revenue_12m, sum(orders_12m) AS orders_12m,
         sum(stores) AS stores, sum(competitors) AS competitors
  FROM r GROUP BY h3_toparent(h3, res), res, h3_toparent(h3, res - 3), metro_code, region
)
SELECT *,
       round(100.0 * customers / greatest(households, 1), 2) AS penetration_pct,
       round(revenue_12m / greatest(households, 1), 0) AS revenue_per_hh,
       cast(round(100 * percent_rank() OVER (PARTITION BY res, metro_code
             ORDER BY households * (0.4 + affluence_index) * (1 - least(customers / greatest(households, 1) / 0.45, 1.0)) / (1 + stores + 0.5 * competitors))) AS INT) AS whitespace_score
FROM a;

CREATE OR REPLACE TABLE ${catalog}.gold.retail_stores
COMMENT 'Store performance, trailing 12 months (Oct 2025 to Sep 2026). Grain: store. Source: silver.stores + silver.orders. Refreshed daily. Revenue in INR; perf_band Top/Core/Watch by revenue per sqft vs format average.'
AS
WITH o AS (
  SELECT store_code, sum(amount_inr) AS revenue_12m, count(*) AS orders_12m, count(DISTINCT customer_id) AS customers_12m,
         sum(IF(channel = 'JioMart', amount_inr, 0)) / sum(amount_inr) AS jiomart_share,
         sum(IF(order_month >= DATE'2026-07-01', amount_inr, 0)) AS rev_l3m,
         sum(IF(order_month BETWEEN DATE'2026-04-01' AND DATE'2026-06-01', amount_inr, 0)) AS rev_p3m
  FROM ${catalog}.silver.orders GROUP BY store_code
),
cat AS (
  SELECT store_code, max_by(category, rev) AS top_category FROM (
    SELECT store_code, category, sum(amount_inr) AS rev FROM ${catalog}.silver.orders GROUP BY 1, 2) GROUP BY 1
),
j AS (
  SELECT s.store_code, s.store_name, s.format, s.metro_code, s.region, s.locality, s.latitude, s.longitude, s.h3_r9, s.h3_r8,
         s.carpet_area_sqft, s.open_date, s.store_status,
         round(coalesce(o.revenue_12m, 0), 0) AS revenue_12m, coalesce(o.orders_12m, 0) AS orders_12m,
         coalesce(o.customers_12m, 0) AS customers_12m, round(coalesce(o.jiomart_share, 0), 4) AS jiomart_share,
         round(100 * (o.rev_l3m / nullif(o.rev_p3m, 0) - 1), 1) AS growth_3m_pct, c.top_category,
         round(coalesce(o.revenue_12m, 0) / s.carpet_area_sqft, 0) AS revenue_per_sqft
  FROM ${catalog}.silver.stores s LEFT JOIN o USING (store_code) LEFT JOIN cat c USING (store_code)
)
SELECT *,
       rank() OVER (PARTITION BY metro_code, format ORDER BY revenue_12m DESC) AS rank_in_metro_format,
       round(revenue_per_sqft / avg(revenue_per_sqft) OVER (PARTITION BY format), 3) AS perf_index,
       CASE WHEN percent_rank() OVER (PARTITION BY format ORDER BY revenue_per_sqft) >= 0.80 THEN 'Top'
            WHEN percent_rank() OVER (PARTITION BY format ORDER BY revenue_per_sqft) >= 0.20 THEN 'Core' ELSE 'Watch' END AS perf_band
FROM j;

CREATE OR REPLACE TABLE ${catalog}.gold.retail_store_monthly
CLUSTER BY (store_code)
COMMENT 'Store revenue by month and category. Grain: store x month x category. Source: silver.orders. Refreshed daily.'
AS
SELECT o.store_code, s.metro_code, s.region, o.order_month AS month, o.category,
       round(sum(o.amount_inr), 0) AS revenue, count(*) AS orders, count(DISTINCT o.customer_id) AS customers,
       round(sum(IF(o.channel = 'JioMart', o.amount_inr, 0)), 0) AS rev_jiomart
FROM ${catalog}.silver.orders o JOIN ${catalog}.silver.stores s USING (store_code)
GROUP BY o.store_code, s.metro_code, s.region, o.order_month, o.category;

CREATE OR REPLACE TABLE ${catalog}.gold.retail_store_catchment
CLUSTER BY (store_code)
COMMENT 'Where each store''s customers live: revenue by customer home H3 res-8 cell. Grain: store x h3 res 8. Source: silver.orders. Refreshed daily. share_pct = share of store revenue.'
AS
WITH a AS (
  SELECT o.store_code, o.home_h3_r8 AS h3, s.metro_code, s.region, s.h3_r8 AS store_r8,
         sum(o.amount_inr) AS revenue, count(*) AS orders, count(DISTINCT o.customer_id) AS customers
  FROM ${catalog}.silver.orders o JOIN ${catalog}.silver.stores s USING (store_code)
  GROUP BY o.store_code, o.home_h3_r8, s.metro_code, s.region, s.h3_r8
)
SELECT store_code, h3, metro_code, region, round(revenue, 0) AS revenue, orders, customers,
       round(100 * revenue / sum(revenue) OVER (PARTITION BY store_code), 3) AS share_pct,
       h3_distance(h3, store_r8) AS ring_distance
FROM a;

CREATE OR REPLACE TABLE ${catalog}.gold.retail_competitors
COMMENT 'Competitor outlets for map overlays. Grain: outlet. Source: silver.competitors. Refreshed quarterly.'
AS SELECT outlet_id, brand, category_group, metro_code, region, locality, latitude, longitude, h3_r9, h3_r8 FROM ${catalog}.silver.competitors;

CREATE OR REPLACE TABLE ${catalog}.gold.retail_plot_scores
COMMENT 'Site-selection scores per candidate plot. Grain: plot. Scores 0-100 per format group from 3 km demand, affluence, competition, distance to nearest Reliance store (cannibalisation), road access and size fit. est_annual_revenue_cr in INR crore. Refreshed weekly.'
AS
WITH p AS (SELECT * FROM ${catalog}.silver.plots),
cells AS (SELECT p.plot_id, cell FROM p LATERAL VIEW explode(h3_kring(p.h3_r8, 4)) t AS cell),
ring AS (
  SELECT c.plot_id, h.households, h.population, h.affluence_index, h.revenue_12m, h.customers
  FROM cells c JOIN ${catalog}.gold.retail_hex_profile h ON h.h3 = c.cell AND h.res = 8
),
dem AS (
  SELECT plot_id, sum(households) AS households_3km, sum(population) AS population_3km,
         round(sum(affluence_index * population) / greatest(sum(population), 1), 3) AS affluence_3km,
         round(sum(revenue_12m), 0) AS reliance_revenue_3km, sum(customers) AS reliance_customers_3km
  FROM ring GROUP BY plot_id
),
comp AS (
  SELECT p.plot_id,
         sum(IF(c.category_group = 'Grocery', 1, 0)) AS comp_grocery_3km,
         sum(IF(c.category_group = 'Fashion', 1, 0)) AS comp_fashion_3km,
         sum(IF(c.category_group = 'Electronics', 1, 0)) AS comp_electronics_3km
  FROM p JOIN ${catalog}.silver.competitors c
    ON c.metro_code = p.metro_code AND st_distancesphere(st_point(p.centroid_lon, p.centroid_lat, 4326), c.geom) < 3000
  GROUP BY p.plot_id
),
near AS (
  SELECT p.plot_id,
         min(IF(s.format IN ('Smart Bazaar', 'Smart Point', 'Fresh Signature'), st_distancesphere(st_point(p.centroid_lon, p.centroid_lat, 4326), s.geom), NULL)) / 1000 AS near_grocery_km,
         min(IF(s.format IN ('Trends', 'Azorte', 'Centro'), st_distancesphere(st_point(p.centroid_lon, p.centroid_lat, 4326), s.geom), NULL)) / 1000 AS near_fashion_km,
         min(IF(s.format = 'Reliance Digital', st_distancesphere(st_point(p.centroid_lon, p.centroid_lat, 4326), s.geom), NULL)) / 1000 AS near_electronics_km
  FROM p JOIN ${catalog}.silver.stores s ON s.metro_code = p.metro_code
  GROUP BY p.plot_id
),
f AS (
  SELECT p.*, d.households_3km, d.population_3km, d.affluence_3km, d.reliance_revenue_3km, d.reliance_customers_3km,
         coalesce(c.comp_grocery_3km, 0) AS comp_grocery_3km, coalesce(c.comp_fashion_3km, 0) AS comp_fashion_3km,
         coalesce(c.comp_electronics_3km, 0) AS comp_electronics_3km,
         round(coalesce(n.near_grocery_km, 9), 2) AS near_grocery_km, round(coalesce(n.near_fashion_km, 9), 2) AS near_fashion_km,
         round(coalesce(n.near_electronics_km, 9), 2) AS near_electronics_km,
         percent_rank() OVER (PARTITION BY p.metro_code ORDER BY d.households_3km) AS demand_pr,
         CASE p.road_access WHEN 'Arterial road' THEN 1.0 WHEN 'Main road' THEN 0.7 ELSE 0.4 END AS access
  FROM p LEFT JOIN dem d USING (plot_id) LEFT JOIN comp c USING (plot_id) LEFT JOIN near n USING (plot_id)
),
s AS (
  SELECT *,
    round(100 * (0.35 * demand_pr + 0.15 * affluence_3km + 0.20 * (1 - percent_rank() OVER (PARTITION BY metro_code ORDER BY comp_grocery_3km))
                 + 0.20 * least(near_grocery_km, 4) / 4 + 0.10 * access) * IF(area_sqm >= 2500, 1.0, 0.75), 1) AS score_grocery,
    round(100 * (0.25 * demand_pr + 0.35 * affluence_3km + 0.15 * (1 - percent_rank() OVER (PARTITION BY metro_code ORDER BY comp_fashion_3km))
                 + 0.15 * least(near_fashion_km, 4) / 4 + 0.10 * access) * IF(area_sqm BETWEEN 1500 AND 9000, 1.0, 0.8), 1) AS score_fashion,
    round(100 * (0.30 * demand_pr + 0.25 * affluence_3km + 0.20 * (1 - percent_rank() OVER (PARTITION BY metro_code ORDER BY comp_electronics_3km))
                 + 0.15 * least(near_electronics_km, 4) / 4 + 0.10 * access) * IF(area_sqm BETWEEN 1000 AND 6000, 1.0, 0.8), 1) AS score_electronics
  FROM f
),
b AS (
  SELECT *,
    greatest(score_grocery, score_fashion, score_electronics) AS best_score,
    CASE WHEN score_grocery >= greatest(score_fashion, score_electronics) THEN IF(area_sqm >= 4000, 'Smart Bazaar', 'Smart Point')
         WHEN score_fashion >= score_electronics THEN 'Trends' ELSE 'Reliance Digital' END AS recommended_format
  FROM s
),
bench AS (
  SELECT metro_code, format, percentile_approx(revenue_12m, 0.5) AS median_rev FROM ${catalog}.gold.retail_stores GROUP BY 1, 2
)
SELECT b.plot_id, b.metro_code, b.region, b.locality, b.area_sqm, b.zoning, b.ask_price_inr_per_sqft, b.frontage_m, b.road_access,
       b.transaction_type, b.plot_status, b.centroid_lat, b.centroid_lon, b.h3_r9, b.h3_r8,
       b.households_3km, b.population_3km, b.affluence_3km, b.reliance_revenue_3km, b.reliance_customers_3km,
       b.comp_grocery_3km, b.comp_fashion_3km, b.comp_electronics_3km, b.near_grocery_km, b.near_fashion_km, b.near_electronics_km,
       b.score_grocery, b.score_fashion, b.score_electronics, b.best_score, b.recommended_format,
       round(coalesce(bn.median_rev, 0) * (0.6 + 0.8 * b.best_score / 100) / 1e7, 2) AS est_annual_revenue_cr,
       round(least(60, 60 * exp(-CASE WHEN b.recommended_format IN ('Smart Bazaar', 'Smart Point') THEN b.near_grocery_km
                                       WHEN b.recommended_format = 'Trends' THEN b.near_fashion_km ELSE b.near_electronics_km END / 1.5)), 1) AS cannibalisation_risk_pct,
       round(b.area_sqm * 10.764 * b.ask_price_inr_per_sqft / 1e7, 2) AS est_land_value_cr,
       b.geom
FROM b LEFT JOIN bench bn ON bn.metro_code = b.metro_code AND bn.format = b.recommended_format;
