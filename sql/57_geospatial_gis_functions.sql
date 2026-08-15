/*
======================================================================================
MODULE 57: GEOSPATIAL & GIS FUNCTIONS (GEOMETRY & GEOGRAPHY) — 20 SCENARIOS
======================================================================================
TARGET AUDIENCE: Application Developers & Senior Data Engineers
BUSINESS SCENARIO: 
Logistics route planning, store proximity search, delivery geofencing, 
and territorial polygons in spatial data warehousing.

THE GOAL:
Provide 20 runnable, production-grade geospatial queries in Amazon Redshift 
using native `GEOMETRY` and `GEOGRAPHY` types and Open Geospatial Consortium (OGC) spatial functions.
======================================================================================
*/

-- ===================================================================================
-- DATA GENERATION
-- ===================================================================================
DROP TABLE IF EXISTS demo_spatial_stores CASCADE;
CREATE TABLE demo_spatial_stores (
    store_id INT,
    store_name VARCHAR(100),
    latitude DOUBLE PRECISION,
    longitude DOUBLE PRECISION,
    geom GEOMETRY,
    geog GEOGRAPHY
);

INSERT INTO demo_spatial_stores (store_id, store_name, latitude, longitude, geom, geog) VALUES 
(1, 'Downtown NYC Flagship', 40.7128, -74.0060, 
    ST_Point(-74.0060, 40.7128), 
    ST_MakePoint(-74.0060, 40.7128)::GEOGRAPHY),
(2, 'Brooklyn Store', 40.6782, -73.9442, 
    ST_Point(-73.9442, 40.6782), 
    ST_MakePoint(-73.9442, 40.6782)::GEOGRAPHY),
(3, 'Los Angeles Outlet', 34.0522, -118.2437, 
    ST_Point(-118.2437, 34.0522), 
    ST_MakePoint(-118.2437, 34.0522)::GEOGRAPHY);

ANALYZE demo_spatial_stores;


-- ===================================================================================
-- 20 ENTERPRISE GEOSPATIAL (GIS) FUNCTIONS
-- ===================================================================================

-- 1. ST_Point / ST_MakePoint (Constructing point geometry from lon/lat)
SELECT store_id, store_name, ST_AsText(ST_Point(longitude, latitude)) AS point_wkt FROM demo_spatial_stores;

-- 2. ST_AsText (Converting binary geometry to Well-Known Text WKT format)
SELECT store_id, ST_AsText(geom) AS wkt_format FROM demo_spatial_stores;

-- 3. ST_AsGeoJSON (Exporting spatial objects directly to GeoJSON format)
SELECT store_id, ST_AsGeoJSON(geom) AS geojson_string FROM demo_spatial_stores;

-- 4. ST_GeomFromText (Parsing WKT string into GEOMETRY)
SELECT ST_GeomFromText('POLYGON((-74.1 40.7, -73.9 40.7, -73.9 40.8, -74.1 40.8, -74.1 40.7))') AS nyc_delivery_polygon;

-- 5. ST_Distance (Planar Euclidean distance in spatial units)
SELECT a.store_name AS store_a, b.store_name AS store_b, ST_Distance(a.geom, b.geom) AS planar_deg_distance
FROM demo_spatial_stores a, demo_spatial_stores b WHERE a.store_id = 1 AND b.store_id = 2;

-- 6. ST_DistanceSphere (Great-circle geodetic distance in METERS on Earth sphere)
SELECT a.store_name AS store_a, b.store_name AS store_b, 
       ROUND(ST_DistanceSphere(a.geom, b.geom), 2) AS distance_meters,
       ROUND(ST_DistanceSphere(a.geom, b.geom) / 1000.0, 2) AS distance_km
FROM demo_spatial_stores a, demo_spatial_stores b WHERE a.store_id = 1 AND b.store_id = 2;

-- 7. ST_Contains (Testing if a polygon encompasses a point — Geofencing)
SELECT store_id, store_name,
       ST_Contains(
           ST_GeomFromText('POLYGON((-74.05 40.65, -73.90 40.65, -73.90 40.75, -74.05 40.75, -74.05 40.65))'),
           geom
       ) AS is_inside_delivery_zone
FROM demo_spatial_stores;

-- 8. ST_Within (Inverse of ST_Contains: testing if point is within polygon)
SELECT store_id, store_name,
       ST_Within(
           geom,
           ST_GeomFromText('POLYGON((-74.05 40.65, -73.90 40.65, -73.90 40.75, -74.05 40.75, -74.05 40.65))')
       ) AS within_zone
FROM demo_spatial_stores;

-- 9. ST_Buffer (Creating a radial polygon buffer around a point)
SELECT store_id, ST_AsText(ST_Buffer(geom, 0.05)) AS buffer_zone_wkt FROM demo_spatial_stores WHERE store_id = 1;

-- 10. ST_Area (Calculating planar area of a polygon)
SELECT ST_Area(ST_GeomFromText('POLYGON((0 0, 10 0, 10 10, 0 10, 0 0))')) AS box_area;

-- 11. ST_Length (Calculating length of a LineString path)
SELECT ST_Length(ST_GeomFromText('LINESTRING(0 0, 3 4)')) AS line_length;

-- 12. ST_Centroid (Computing the geometric center point of a polygon)
SELECT ST_AsText(ST_Centroid(ST_GeomFromText('POLYGON((0 0, 10 0, 10 10, 0 10, 0 0))'))) AS centroid_pt;

-- 13. ST_Envelope (Calculating the Bounding Box / MBR of a geometry)
SELECT store_id, ST_AsText(ST_Envelope(ST_Buffer(geom, 0.05))) AS bounding_box FROM demo_spatial_stores WHERE store_id = 1;

-- 14. ST_Intersection (Extracting overlapping spatial region between geometries)
SELECT ST_AsText(ST_Intersection(
    ST_GeomFromText('POLYGON((0 0, 5 0, 5 5, 0 5, 0 0))'),
    ST_GeomFromText('POLYGON((3 3, 8 3, 8 8, 3 8, 3 3))')
)) AS overlap_geom;

-- 15. ST_Intersects (Fast boolean test for spatial overlap)
SELECT ST_Intersects(
    ST_GeomFromText('LINESTRING(0 0, 10 10)'),
    ST_GeomFromText('LINESTRING(0 10, 10 0)')
) AS lines_cross;

-- 16. ST_X & ST_Y (Extracting raw Coordinate values from a Point)
SELECT store_id, ST_X(geom) AS extracted_lon, ST_Y(geom) AS extracted_lat FROM demo_spatial_stores;

-- 17. ST_SRID & ST_SetSRID (Managing Spatial Reference System Identifiers — e.g. WGS84 = 4326)
SELECT store_id, ST_SRID(ST_SetSRID(geom, 4326)) AS srid_code FROM demo_spatial_stores;

-- 18. ST_IsValid (Validating polygon topology correctness)
SELECT ST_IsValid(ST_GeomFromText('POLYGON((0 0, 2 2, 0 2, 2 0, 0 0))')) AS is_bowtie_polygon_valid;

-- 19. ST_DWithin (Testing if two geometries are within a radius threshold)
SELECT a.store_name AS store_a, b.store_name AS store_b,
       ST_DWithin(a.geog, b.geog, 50000) AS within_50km_threshold
FROM demo_spatial_stores a, demo_spatial_stores b
WHERE a.store_id = 1 AND b.store_id = 2;

-- 20. K-Nearest Neighbors (KNN) Spatial Proximity Search
-- Find closest store to customer location (-73.9851, 40.7488 — Empire State Bldg):
SELECT store_id, store_name,
       ROUND(ST_DistanceSphere(geom, ST_Point(-73.9851, 40.7488)), 2) AS distance_meters
FROM demo_spatial_stores
ORDER BY geom <-> ST_Point(-73.9851, 40.7488)
LIMIT 1;
