-- Silver: typed entities with H3 + GEOMETRY, customers, Huff store choice, ~65M orders
CREATE OR REPLACE TABLE ${catalog}.ref.format_category (
  format STRING NOT NULL COMMENT 'Reliance Retail store format',
  category STRING NOT NULL COMMENT 'Merchandise category the format sells: Grocery, Fresh, Fashion, Home, Beauty, Electronics, Jewellery',
  weight DOUBLE COMMENT 'Relative attractiveness of the format for this category (0-1)',
  CONSTRAINT format_category_pk PRIMARY KEY (format, category) RELY
) COMMENT 'Which categories each store format sells. Grain: format x category. Static. Drives the Huff store-choice model.';

INSERT INTO ${catalog}.ref.format_category VALUES
  ('Smart Bazaar','Grocery',1.0),('Smart Bazaar','Fresh',0.8),('Smart Bazaar','Home',0.9),('Smart Bazaar','Beauty',0.4),
  ('Smart Bazaar','Fashion',0.3),('Smart Bazaar','Electronics',0.2),
  ('Smart Point','Grocery',0.7),('Smart Point','Fresh',0.6),
  ('Fresh Signature','Fresh',1.0),('Fresh Signature','Grocery',0.6),
  ('Trends','Fashion',1.0),('Trends','Beauty',0.3),('Trends','Home',0.2),
  ('Azorte','Fashion',0.8),('Centro','Fashion',0.9),('Centro','Home',0.5),('Centro','Beauty',0.4),
  ('Reliance Digital','Electronics',1.0),('Reliance Jewels','Jewellery',1.0),('Tira','Beauty',1.0);

CREATE OR REPLACE TABLE ${catalog}.silver.stores (
  store_code STRING NOT NULL COMMENT 'Store code RR-<metro>-<seq>',
  store_name STRING COMMENT 'Store display name: format + locality',
  format STRING COMMENT 'Format: Smart Bazaar, Smart Point, Fresh Signature, Trends, Azorte, Centro, Reliance Digital, Reliance Jewels, Tira',
  metro_code STRING COMMENT 'FK to ref.metros',
  region STRING COMMENT 'Sales region: West, North, South, East',
  locality STRING COMMENT 'Locality name',
  latitude DOUBLE COMMENT 'Latitude WGS84',
  longitude DOUBLE COMMENT 'Longitude WGS84',
  h3_r9 BIGINT COMMENT 'H3 res-9 cell of the store',
  h3_r8 BIGINT COMMENT 'H3 res-8 cell of the store',
  geom GEOMETRY(4326) COMMENT 'Store location as point geometry, SRID 4326',
  carpet_area_sqft INT COMMENT 'Carpet area in sq ft',
  open_date DATE COMMENT 'Store opening date',
  store_status STRING COMMENT 'Operational / Closed',
  CONSTRAINT stores_pk PRIMARY KEY (store_code) RELY,
  CONSTRAINT stores_metro_fk FOREIGN KEY (metro_code) REFERENCES ${catalog}.ref.metros (metro_code) NOT ENFORCED RELY
) CLUSTER BY (metro_code)
COMMENT 'Reliance Retail stores, H3 indexed. Grain: store. Source: bronze.store_master. Refreshed daily.';

INSERT OVERWRITE ${catalog}.silver.stores
SELECT store_code, store_name, format, metro_code, region, locality, latitude, longitude,
       h3_longlatash3(longitude, latitude, 9), h3_longlatash3(longitude, latitude, 8),
       st_point(longitude, latitude, 4326), carpet_area_sqft, open_date, store_status
FROM ${catalog}.bronze.store_master;

CREATE OR REPLACE TABLE ${catalog}.silver.competitors (
  outlet_id STRING NOT NULL COMMENT 'Competitor outlet id',
  brand STRING COMMENT 'Competitor brand, e.g. DMart, Zudio, Croma, Blinkit Dark Store',
  category_group STRING COMMENT 'Grocery, Fashion, Electronics, Jewellery, Beauty',
  metro_code STRING COMMENT 'FK to ref.metros',
  region STRING COMMENT 'Sales region',
  locality STRING COMMENT 'Locality name',
  latitude DOUBLE COMMENT 'Latitude WGS84',
  longitude DOUBLE COMMENT 'Longitude WGS84',
  h3_r9 BIGINT COMMENT 'H3 res-9 cell',
  h3_r8 BIGINT COMMENT 'H3 res-8 cell',
  geom GEOMETRY(4326) COMMENT 'Outlet location point, SRID 4326',
  CONSTRAINT competitors_pk PRIMARY KEY (outlet_id) RELY
) CLUSTER BY (metro_code)
COMMENT 'Competitor outlets, H3 indexed. Grain: outlet. Source: bronze.competitor_outlets. Refreshed quarterly.';

INSERT OVERWRITE ${catalog}.silver.competitors
SELECT outlet_id, brand, category_group, metro_code, region, locality, latitude, longitude,
       h3_longlatash3(longitude, latitude, 9), h3_longlatash3(longitude, latitude, 8),
       st_point(longitude, latitude, 4326)
FROM ${catalog}.bronze.competitor_outlets;

CREATE OR REPLACE TABLE ${catalog}.silver.plots (
  plot_id STRING NOT NULL COMMENT 'Plot id PLT-<metro>-<seq>',
  metro_code STRING COMMENT 'FK to ref.metros',
  region STRING COMMENT 'Sales region',
  locality STRING COMMENT 'Locality name',
  area_sqm DOUBLE COMMENT 'Plot area in square metres',
  zoning STRING COMMENT 'Commercial, Mixed Use, Industrial, Residential (convertible)',
  ask_price_inr_per_sqft INT COMMENT 'Asking price, INR per sq ft',
  frontage_m INT COMMENT 'Road frontage in metres',
  road_access STRING COMMENT 'Arterial road, Main road, Internal road',
  transaction_type STRING COMMENT 'Lease or Outright purchase',
  plot_status STRING COMMENT 'Available, Under negotiation, Shortlisted',
  centroid_lat DOUBLE COMMENT 'Plot centroid latitude',
  centroid_lon DOUBLE COMMENT 'Plot centroid longitude',
  h3_r9 BIGINT COMMENT 'H3 res-9 cell of the centroid',
  h3_r8 BIGINT COMMENT 'H3 res-8 cell of the centroid',
  geom GEOMETRY(4326) COMMENT 'Plot boundary polygon, SRID 4326',
  CONSTRAINT plots_pk PRIMARY KEY (plot_id) RELY
) CLUSTER BY (metro_code)
COMMENT 'Candidate land plots with boundary geometry. Grain: plot. Source: bronze.land_bank_plots. Refreshed weekly.';

INSERT OVERWRITE ${catalog}.silver.plots
WITH g AS (SELECT *, st_geomfromwkt(boundary_wkt, 4326) AS geom FROM ${catalog}.bronze.land_bank_plots)
SELECT plot_id, metro_code, region, locality, area_sqm, zoning, ask_price_inr_per_sqft, frontage_m, road_access,
       transaction_type, plot_status,
       st_y(st_centroid(geom)), st_x(st_centroid(geom)),
       h3_longlatash3(st_x(st_centroid(geom)), st_y(st_centroid(geom)), 9),
       h3_longlatash3(st_x(st_centroid(geom)), st_y(st_centroid(geom)), 8),
       geom
FROM g;

CREATE OR REPLACE TABLE ${catalog}.silver.customers
CLUSTER BY (metro_code)
COMMENT 'Reliance One loyalty customers located to home H3 res-9 cell (no precise address kept). Grain: customer. Source: synthetic loyalty CRM. Refreshed daily.'
AS
WITH d AS (
  SELECT h3, h3_r8, metro_code, region, affluence_index,
         cast(round(population * 0.08 * (0.5 + affluence_index)) AS INT) AS n
  FROM ${catalog}.silver.hex_demographics
),
e AS (SELECT d.*, k FROM d LATERAL VIEW explode(sequence(1, n)) t AS k WHERE n > 0),
u AS (
  SELECT *, xxhash64(h3, k) AS customer_id,
         pmod(xxhash64(h3, k, 't'), 1000003) / 1000003.0 AS ut,
         pmod(xxhash64(h3, k, 'a'), 1000003) / 1000003.0 AS ua,
         pmod(xxhash64(h3, k, 'j'), 1000003) / 1000003.0 AS uj
  FROM e
)
SELECT customer_id,
       h3 AS home_h3_r9, h3_r8 AS home_h3_r8, metro_code, region,
       CASE WHEN ut + 0.3 * affluence_index > 1.05 THEN 'Platinum' WHEN ut + 0.3 * affluence_index > 0.85 THEN 'Gold'
            WHEN ut + 0.3 * affluence_index > 0.55 THEN 'Silver' ELSE 'Basic' END AS loyalty_tier,
       CASE WHEN ua < 0.15 THEN '18-24' WHEN ua < 0.45 THEN '25-34' WHEN ua < 0.70 THEN '35-44'
            WHEN ua < 0.87 THEN '45-54' ELSE '55+' END AS age_band,
       date_add(DATE'2016-01-01', cast(uj * 3700 AS INT)) AS join_date
FROM u;

ALTER TABLE ${catalog}.silver.customers ALTER COLUMN customer_id SET NOT NULL;

ALTER TABLE ${catalog}.silver.customers ADD CONSTRAINT customers_pk PRIMARY KEY (customer_id) RELY;

CREATE OR REPLACE TABLE ${catalog}.silver.huff_choice
COMMENT 'Huff gravity store-choice model: for each home res-8 cell and category, the top 8 reachable stores and cumulative choice probabilities. Grain: home_h3_r8 x category. Derived.'
AS
WITH st AS (
  SELECT store_code, format, carpet_area_sqft, h3_r8,
         IF(format IN ('Smart Bazaar', 'Centro', 'Reliance Digital'), 12, 7) AS ring
  FROM ${catalog}.silver.stores
),
r AS (SELECT st.*, explode(h3_kring(h3_r8, ring)) AS home_r8 FROM st),
homes AS (SELECT DISTINCT h3_r8 FROM ${catalog}.silver.hex_demographics),
p AS (
  SELECT r.home_r8, fc.category, r.store_code,
         fc.weight * sqrt(r.carpet_area_sqft / 1000.0) / power(0.5 + h3_distance(r.h3_r8, r.home_r8) * 0.8, 2) AS attr
  FROM r
  JOIN homes h ON h.h3_r8 = r.home_r8
  JOIN ${catalog}.ref.format_category fc ON fc.format = r.format
),
t AS (SELECT *, row_number() OVER (PARTITION BY home_r8, category ORDER BY attr DESC) AS rn FROM p),
a AS (
  SELECT home_r8, category, array_sort(collect_list(struct(rn, store_code, attr))) AS s
  FROM t WHERE rn <= 8 GROUP BY home_r8, category
)
SELECT home_r8 AS home_h3_r8, category,
       transform(s, x -> x.store_code) AS store_codes,
       transform(sequence(1, size(s)), i -> aggregate(slice(s, 1, i), 0D, (acc, x) -> acc + x.attr)
                                            / aggregate(s, 0D, (acc, x) -> acc + x.attr)) AS cum_probs
FROM a;

CREATE OR REPLACE TABLE ${catalog}.silver.orders (
  order_id BIGINT NOT NULL COMMENT 'Order line id',
  customer_id BIGINT COMMENT 'FK to silver.customers',
  store_code STRING COMMENT 'Fulfilling store, FK to silver.stores',
  order_date DATE COMMENT 'Order date',
  order_month DATE COMMENT 'First day of order month',
  channel STRING COMMENT 'Store (walk-in) or JioMart (online, delivered from store)',
  category STRING COMMENT 'Grocery, Fresh, Fashion, Home, Beauty, Electronics, Jewellery',
  items INT COMMENT 'Number of items in the basket line',
  amount_inr DOUBLE COMMENT 'Net sales value, INR',
  home_h3_r9 BIGINT COMMENT 'Customer home H3 res-9 cell (demand origin)',
  home_h3_r8 BIGINT COMMENT 'Customer home H3 res-8 cell',
  metro_code STRING COMMENT 'Customer metro',
  region STRING COMMENT 'Customer sales region',
  loyalty_tier STRING COMMENT 'Platinum, Gold, Silver, Basic',
  CONSTRAINT orders_pk PRIMARY KEY (order_id) RELY,
  CONSTRAINT orders_customer_fk FOREIGN KEY (customer_id) REFERENCES ${catalog}.silver.customers (customer_id) NOT ENFORCED RELY,
  CONSTRAINT orders_store_fk FOREIGN KEY (store_code) REFERENCES ${catalog}.silver.stores (store_code) NOT ENFORCED RELY
) CLUSTER BY (metro_code, order_month)
COMMENT 'Order lines by category, Oct 2025 to Sep 2026. Grain: order x category. Source: synthetic POS + JioMart. Refreshed daily.';

INSERT OVERWRITE ${catalog}.silver.orders
WITH c AS (
  SELECT c.customer_id, c.home_h3_r9, c.home_h3_r8, c.metro_code, c.region, c.loyalty_tier, d.affluence_index AS aff
  FROM ${catalog}.silver.customers c JOIN ${catalog}.silver.hex_demographics d ON c.home_h3_r9 = d.h3
),
o AS (
  SELECT c.*, k, xxhash64(customer_id, k) AS hk
  FROM c LATERAL VIEW explode(sequence(1, 2 + cast(pmod(xxhash64(customer_id, 'n'), 1000) / 1000.0 * 16 * (0.6 + aff) AS INT))) t AS k
),
u AS (
  SELECT *,
         pmod(hk, 1000003) / 1000003.0 AS uc,
         pmod(xxhash64(hk, 1), 1000003) / 1000003.0 AS ud,
         pmod(xxhash64(hk, 2), 1000003) / 1000003.0 AS us,
         pmod(xxhash64(hk, 3), 1000003) / 1000003.0 AS ua,
         pmod(xxhash64(hk, 4), 1000003) / 1000003.0 AS uch,
         pmod(xxhash64(hk, 5), 1000003) / 1000003.0 AS ui
  FROM o
),
cat AS (
  SELECT *,
    CASE WHEN uc < 0.40 THEN 'Grocery' WHEN uc < 0.56 THEN 'Fresh' WHEN uc < 0.71 THEN 'Fashion'
         WHEN uc < 0.79 THEN 'Home' WHEN uc < 0.87 THEN 'Beauty' WHEN uc < 0.97 - 0.02 * (1 - aff) THEN 'Electronics'
         ELSE 'Jewellery' END AS category,
    cast(ud * 365 AS INT) AS day
  FROM u
),
j AS (
  SELECT cat.*, h.store_codes[size(filter(h.cum_probs, p -> p < cat.us))] AS store_code
  FROM cat JOIN ${catalog}.silver.huff_choice h ON h.home_h3_r8 = cat.home_h3_r8 AND h.category = cat.category
)
SELECT
  hk AS order_id, customer_id, store_code,
  date_add(DATE'2025-10-01', day) AS order_date,
  trunc(date_add(DATE'2025-10-01', day), 'MM') AS order_month,
  IF(category IN ('Grocery','Fresh','Electronics','Beauty','Home') AND uch < 0.12 + 0.18 * day / 365, 'JioMart', 'Store') AS channel,
  category,
  cast(1 + ui * CASE category WHEN 'Grocery' THEN 24 WHEN 'Fresh' THEN 10 WHEN 'Fashion' THEN 5 WHEN 'Home' THEN 6
                              WHEN 'Beauty' THEN 5 ELSE 1 END AS INT) AS items,
  round(
    CASE category WHEN 'Grocery' THEN 1300 WHEN 'Fresh' THEN 520 WHEN 'Fashion' THEN 2300 WHEN 'Home' THEN 1900
                  WHEN 'Beauty' THEN 950 WHEN 'Electronics' THEN 8500 ELSE 16000 END
    * (0.35 + 1.65 * ua * ua) * (0.7 + 0.6 * aff)
    * IF(loyalty_tier = 'Platinum', 1.3, IF(loyalty_tier = 'Gold', 1.12, 1.0))
    * (0.92 + 0.16 * day / 365)
    * (0.75 + 0.5 * pmod(xxhash64(store_code), 1000) / 1000.0)
    * CASE WHEN category IN ('Fashion','Electronics','Jewellery') AND month(date_add(DATE'2025-10-01', day)) IN (10, 11, 8, 9) THEN 1.35
           WHEN category = 'Jewellery' AND month(date_add(DATE'2025-10-01', day)) = 4 THEN 1.5 ELSE 1.0 END
  , 2) AS amount_inr,
  home_h3_r9, home_h3_r8, metro_code, region, loyalty_tier
FROM j
WHERE store_code IS NOT NULL;
