/*
======================================================================================
MODULE 55: JSON & SUPER DATA TYPE (PARTIQL) — 20 ENTERPRISE SCENARIOS
======================================================================================
TARGET AUDIENCE: Application Developers & Senior Data Engineers
BUSINESS SCENARIO: 
Semi-structured JSON payloads from modern webhooks, NoSQL databases (DynamoDB/MongoDB), 
and Kafka clickstream topics landing directly into Amazon Redshift.

THE GOAL:
Provide 20 runnable, production-grade JSON and SUPER functions using native PartiQL, 
JSON shredding, array unnesting, dynamic object construction, and type casting.
======================================================================================
*/

-- ===================================================================================
-- DATA GENERATION
-- ===================================================================================
DROP TABLE IF EXISTS demo_super_events CASCADE;
CREATE TABLE demo_super_events (
    event_id BIGINT,
    raw_json_str VARCHAR(MAX),
    super_data SUPER
);

INSERT INTO demo_super_events VALUES 
(1, '{"user": {"id": 101, "name": "Alice", "tags": ["vip", "beta"]}, "orders": [{"id": "o1", "total": 150.00}, {"id": "o2", "total": 45.50}], "metadata": {"ip": "192.168.1.1", "device": "iOS"}}',
    JSON_PARSE('{"user": {"id": 101, "name": "Alice", "tags": ["vip", "beta"]}, "orders": [{"id": "o1", "total": 150.00}, {"id": "o2", "total": 45.50}], "metadata": {"ip": "192.168.1.1", "device": "iOS"}}')),
(2, '{"user": {"id": 102, "name": "Bob", "tags": ["standard"]}, "orders": [{"id": "o3", "total": 99.00}], "metadata": {"ip": "10.0.0.5", "device": "Android"}}',
    JSON_PARSE('{"user": {"id": 102, "name": "Bob", "tags": ["standard"]}, "orders": [{"id": "o3", "total": 99.00}], "metadata": {"ip": "10.0.0.5", "device": "Android"}}')),
(3, '{"user": {"id": 103, "name": "Charlie", "tags": []}, "orders": [], "metadata": {"device": "Web"}}',
    JSON_PARSE('{"user": {"id": 103, "name": "Charlie", "tags": []}, "orders": [], "metadata": {"device": "Web"}}'));

ANALYZE demo_super_events;


-- ===================================================================================
-- 20 ENTERPRISE JSON & SUPER FUNCTIONS
-- ===================================================================================

-- 1. JSON_PARSE (Converting raw JSON string into native SUPER binary type)
SELECT event_id, JSON_PARSE(raw_json_str) AS parsed_super FROM demo_super_events;

-- 2. JSON_SERIALIZE (Converting native SUPER binary type back into formatted JSON string)
SELECT event_id, JSON_SERIALIZE(super_data.user) AS user_json_string FROM demo_super_events;

-- 3. Dot-Notation Object Navigation (Case-sensitive and case-insensitive dot syntax)
SELECT event_id, super_data.user.name AS user_name, super_data.metadata.device AS client_device FROM demo_super_events;

-- 4. Bracket-Notation for Keys with Special Characters
SELECT event_id, super_data['user']['id'] AS user_id FROM demo_super_events;

-- 5. Explicit Type Casting from SUPER to SQL Types (Scalars)
SELECT event_id, 
       (super_data.user.id)::BIGINT AS user_id,
       (super_data.user.name)::VARCHAR(50) AS user_name
FROM demo_super_events;

-- 6. Array Index Access (0-Indexed)
SELECT event_id, super_data.user.tags[0] AS primary_tag FROM demo_super_events;

-- 7. JSON_TYPEOF (Inspecting dynamic data type of a SUPER node)
SELECT event_id, 
       JSON_TYPEOF(super_data.user.tags) AS tags_type,
       JSON_TYPEOF(super_data.user.id) AS id_type
FROM demo_super_events;

-- 8. GET_ARRAY_LENGTH (Measuring length of nested array)
SELECT event_id, GET_ARRAY_LENGTH(super_data.orders) AS order_count FROM demo_super_events;

-- 9. PartiQL Array Unnesting (Shredding orders array to rows)
SELECT e.event_id, 
       (o.id)::VARCHAR(32) AS order_id, 
       (o.total)::DECIMAL(10,2) AS order_total
FROM demo_super_events e, e.super_data.orders AS o;

-- 10. PartiQL Scalar Array Unnesting (Shredding tags array to rows)
SELECT e.event_id, (t)::VARCHAR(30) AS user_tag
FROM demo_super_events e, e.super_data.user.tags AS t;

-- 11. PartiQL Array Index Iteration (AT index clause)
SELECT e.event_id, idx, (t)::VARCHAR(30) AS tag_value
FROM demo_super_events e, e.super_data.user.tags AS t AT idx;

-- 12. UNPIVOT Object Key-Value Pairs to Rows
SELECT e.event_id, k AS attribute_name, JSON_SERIALIZE(v) AS attribute_val
FROM demo_super_events e, UNPIVOT e.super_data.metadata AS v AT k;

-- 13. Dynamic JSON Object Construction: OBJECT() function
SELECT OBJECT('account_id', 501, 'status', 'ACTIVE', 'score', 98.5) AS constructed_super_obj;

-- 14. Dynamic JSON Array Construction: ARRAY() function
SELECT ARRAY('AMER', 'EMEA', 'APAC') AS constructed_super_arr;

-- 15. IS_ARRAY & IS_OBJECT Predicates
SELECT event_id,
       IS_ARRAY(super_data.orders) AS has_orders_array,
       IS_OBJECT(super_data.metadata) AS has_metadata_object
FROM demo_super_events;

-- 16. JSON_EXTRACT_PATH_TEXT (Legacy string extraction for comparison)
SELECT event_id, JSON_EXTRACT_PATH_TEXT(raw_json_str, 'user', 'name') AS legacy_user_name FROM demo_super_events;

-- 17. JSON_EXTRACT_ARRAY_ELEMENT_TEXT (Legacy array element extraction)
SELECT event_id, JSON_EXTRACT_ARRAY_ELEMENT_TEXT(JSON_EXTRACT_PATH_TEXT(raw_json_str, 'user', 'tags'), 0) AS legacy_first_tag FROM demo_super_events;

-- 18. Filtering on Nested SUPER Attributes in WHERE clause
SELECT event_id, (super_data.user.name)::VARCHAR AS user_name
FROM demo_super_events
WHERE (super_data.user.id)::INT = 101;

-- 19. Aggregating Nested SUPER Totals across Unnested Rows
SELECT (super_data.user.name)::VARCHAR AS user_name,
       SUM((o.total)::DECIMAL(10,2)) AS user_total_spend
FROM demo_super_events e, e.super_data.orders AS o
GROUP BY 1;

-- 20. Checking Key Existence with IS NOT NULL on SUPER Paths
SELECT event_id, 
       CASE WHEN super_data.metadata.ip IS NOT NULL THEN 'IP_PRESENT' ELSE 'ANONYMOUS' END AS ip_tracking_status
FROM demo_super_events;
