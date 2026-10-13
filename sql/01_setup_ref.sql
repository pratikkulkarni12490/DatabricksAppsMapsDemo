-- Catalog, schemas and reference data (metros + locality hotspots that drive the synthetic density surface)
CREATE CATALOG IF NOT EXISTS ${catalog} COMMENT 'Reliance Retail geospatial store intelligence demo (CARTO-style H3 analytics on Databricks). Synthetic data, 8 metros.';

CREATE SCHEMA IF NOT EXISTS ${catalog}.ref COMMENT 'Reference data: metros, regions, locality hotspots';
CREATE SCHEMA IF NOT EXISTS ${catalog}.bronze COMMENT 'Raw source extracts (lat/lon, WKT) as landed from store master, competitor survey, land bank';
CREATE SCHEMA IF NOT EXISTS ${catalog}.silver COMMENT 'Typed, H3-indexed, GEOMETRY-typed entities and facts';
CREATE SCHEMA IF NOT EXISTS ${catalog}.gold COMMENT 'H3 rollups and store/plot analytics. Row filtered by access.can_see (region/metro scope)';
CREATE SCHEMA IF NOT EXISTS ${catalog}.serving COMMENT 'CDF-enabled copies of gold that feed Lakebase synced tables. Not for direct user access';
CREATE SCHEMA IF NOT EXISTS ${catalog}.access COMMENT 'Entitlements: user to region/metro scope. Single source of truth for UC row filters and Postgres RLS';

CREATE OR REPLACE TABLE ${catalog}.ref.metros (
  metro_code STRING NOT NULL COMMENT 'Short metro code, e.g. MUM, DEL',
  metro_name STRING COMMENT 'Display name of the metro / urban agglomeration',
  region STRING COMMENT 'Reliance Retail sales region: West, North, South, East',
  center_lat DOUBLE COMMENT 'Metro centre latitude (WGS84)',
  center_lon DOUBLE COMMENT 'Metro centre longitude (WGS84)',
  radius_deg DOUBLE COMMENT 'Radius in degrees used to polyfill the metro with H3 cells',
  peak_density_km2 DOUBLE COMMENT 'Peak residential density, persons per km2',
  store_target INT COMMENT 'Approximate number of Reliance Retail stores generated',
  competitor_target INT COMMENT 'Approximate number of competitor outlets generated',
  plot_target INT COMMENT 'Approximate number of candidate land plots generated',
  CONSTRAINT metros_pk PRIMARY KEY (metro_code) RELY
) COMMENT 'One row per metro. Grain: metro. Source: synthetic reference. Static.';

INSERT INTO ${catalog}.ref.metros VALUES
  ('MUM','Mumbai MMR','West',19.10,72.92,0.30,32000,520,1500,260),
  ('PUN','Pune','West',18.54,73.84,0.22,16000,190,560,120),
  ('AMD','Ahmedabad','West',23.03,72.58,0.20,15000,170,500,110),
  ('DEL','Delhi NCR','North',28.60,77.20,0.38,26000,620,1900,300),
  ('BLR','Bengaluru','South',12.97,77.62,0.25,18000,360,1100,190),
  ('HYD','Hyderabad','South',17.41,78.46,0.24,17000,280,850,160),
  ('CHE','Chennai','South',13.03,80.20,0.22,22000,260,800,150),
  ('KOL','Kolkata','East',22.57,88.38,0.22,28000,300,900,150);

CREATE OR REPLACE TABLE ${catalog}.ref.hotspots (
  metro_code STRING NOT NULL COMMENT 'FK to ref.metros',
  locality STRING NOT NULL COMMENT 'Locality / sub-centre name used for store naming',
  lat DOUBLE COMMENT 'Hotspot latitude',
  lon DOUBLE COMMENT 'Hotspot longitude',
  weight DOUBLE COMMENT 'Relative density weight (0-1.2)',
  sigma_km DOUBLE COMMENT 'Gaussian spread of the density kernel, km',
  affluence DOUBLE COMMENT 'Affluence of the locality, 0 (mass) to 1 (premium)',
  CONSTRAINT hotspots_pk PRIMARY KEY (metro_code, locality) RELY,
  CONSTRAINT hotspots_metro_fk FOREIGN KEY (metro_code) REFERENCES ${catalog}.ref.metros (metro_code) NOT ENFORCED RELY
) COMMENT 'Locality sub-centres per metro. Grain: metro x locality. Drives synthetic population and affluence surfaces. Static.';

INSERT INTO ${catalog}.ref.hotspots VALUES
  ('MUM','Colaba-Fort',18.93,72.83,0.7,2.5,0.95),('MUM','Dadar',19.02,72.84,1.0,3.0,0.6),
  ('MUM','Bandra',19.06,72.84,0.8,2.5,0.9),('MUM','Andheri',19.12,72.85,1.1,3.5,0.65),
  ('MUM','Borivali',19.23,72.86,0.9,3.5,0.55),('MUM','Ghatkopar',19.09,72.91,1.0,3.0,0.5),
  ('MUM','Powai',19.12,72.91,0.6,2.0,0.85),('MUM','Thane',19.20,72.97,0.9,4.0,0.55),
  ('MUM','Navi Mumbai',19.04,73.02,0.7,4.5,0.6),('MUM','Kalyan-Dombivli',19.23,73.10,0.8,4.0,0.35),
  ('MUM','Mira-Bhayandar',19.29,72.87,0.6,3.0,0.4),
  ('PUN','Shivajinagar',18.53,73.85,1.0,3.0,0.7),('PUN','Kothrud',18.50,73.81,0.8,2.5,0.65),
  ('PUN','Hinjewadi',18.59,73.74,0.6,3.0,0.75),('PUN','Hadapsar',18.50,73.93,0.8,3.5,0.45),
  ('PUN','Pimpri-Chinchwad',18.63,73.80,0.9,4.0,0.45),('PUN','Kharadi-Viman Nagar',18.56,73.92,0.6,2.5,0.8),
  ('AMD','CG Road',23.03,72.56,0.9,2.5,0.75),('AMD','Maninagar',22.99,72.60,0.9,3.0,0.4),
  ('AMD','Bopal-SG Highway',23.03,72.50,0.6,3.0,0.85),('AMD','Naroda',23.07,72.66,0.8,3.0,0.3),
  ('AMD','Chandkheda',23.11,72.58,0.6,3.0,0.5),
  ('DEL','Connaught Place',28.63,77.22,0.8,3.0,0.85),('DEL','Karol Bagh',28.65,77.19,0.9,2.5,0.5),
  ('DEL','South Delhi',28.54,77.21,0.9,4.0,0.95),('DEL','Dwarka',28.59,77.05,0.8,3.5,0.6),
  ('DEL','Rohini',28.73,77.11,1.0,4.0,0.45),('DEL','Laxmi Nagar',28.63,77.28,1.1,3.0,0.4),
  ('DEL','Gurugram',28.46,77.03,0.8,5.0,0.9),('DEL','Noida',28.57,77.33,0.8,4.5,0.7),
  ('DEL','Ghaziabad',28.67,77.43,0.8,4.0,0.35),('DEL','Faridabad',28.40,77.31,0.7,4.0,0.35),
  ('BLR','MG Road',12.97,77.61,0.8,2.5,0.9),('BLR','Koramangala',12.93,77.62,0.9,2.5,0.85),
  ('BLR','Whitefield',12.97,77.75,0.8,3.5,0.8),('BLR','Electronic City',12.84,77.67,0.6,3.0,0.6),
  ('BLR','Rajajinagar',12.99,77.55,0.9,3.0,0.5),('BLR','Yelahanka',13.10,77.59,0.6,3.5,0.5),
  ('BLR','Jayanagar-BTM',12.92,77.59,1.0,3.0,0.6),
  ('HYD','Charminar',17.36,78.47,1.1,3.0,0.3),('HYD','HITEC City',17.45,78.38,0.7,3.0,0.9),
  ('HYD','Banjara Hills',17.41,78.44,0.6,2.0,0.95),('HYD','Secunderabad',17.44,78.50,0.9,3.0,0.5),
  ('HYD','LB Nagar',17.35,78.55,0.8,3.5,0.4),('HYD','Kukatpally',17.49,78.41,0.9,3.5,0.55),
  ('CHE','T Nagar',13.04,80.23,1.0,2.5,0.7),('CHE','Anna Nagar',13.09,80.21,0.9,3.0,0.7),
  ('CHE','OMR-Sholinganallur',12.90,80.23,0.6,3.5,0.8),('CHE','Tambaram',12.92,80.12,0.7,3.5,0.4),
  ('CHE','Ambattur',13.11,80.16,0.7,3.0,0.4),('CHE','Velachery',12.98,80.22,0.8,2.5,0.65),
  ('KOL','Park Street',22.55,88.35,0.9,2.5,0.85),('KOL','Salt Lake',22.58,88.41,0.7,2.5,0.75),
  ('KOL','Howrah',22.59,88.31,1.0,3.0,0.3),('KOL','New Town',22.58,88.47,0.5,3.0,0.7),
  ('KOL','Behala',22.50,88.31,0.9,3.0,0.4),('KOL','Dum Dum',22.63,88.42,0.9,3.0,0.4),
  ('KOL','Shyambazar',22.60,88.37,1.0,2.5,0.45);
