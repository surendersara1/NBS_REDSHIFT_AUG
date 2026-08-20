/*
======================================================================================
MODULE 62.1: PROGRAMMING & BUILDING BUSINESS REPORTS VIA CODE
             A RETAIL WAREHOUSE, MODELLED ON ORACLE RETAIL (RMS)
======================================================================================
TARGET AUDIENCE: Senior Data Engineers. This is the capstone.
                 Read module 62 first -- it teaches the 30 PL/pgSQL features in
                 isolation. This file USES them to build a real reporting layer.

WHAT MODULE 62 LEAVES OUT, AND THIS FILE SUPPLIES
  62 proves each language feature with a toy procedure against a two-column table.
  Nothing in it has a dimensional model, a fact table, a window function, a
  materialized view, or a business question. That gap is the whole point here:

      62    "here is how %ROWTYPE works"
      62.1  "here is a 15-dimension retail star schema, three fact tables, ten
             merchandising questions, ten materialized views and the procedures
             that build and refresh the whole thing"

THE MODEL — ORACLE RETAIL MERCHANDISING SYSTEM (RMS) SHAPE
Anyone who has worked on Oracle Retail will recognise this immediately. RMS has
two rigid five-level hierarchies, and almost every merchandising report in the
world is an aggregation somewhere on one of them.

  MERCHANDISE HIERARCHY              ORGANIZATIONAL HIERARCHY
  ────────────────────               ────────────────────────
  DIVISION      (Softlines)          CHAIN      (Full Line)
    └ GROUP     (Womenswear)           └ AREA     (Europe)
      └ DEPT    (Dresses)                └ REGION   (UK & Ireland)
        └ CLASS (Occasion)                 └ DISTRICT (London)
          └ SUBCLASS (Evening)               └ STORE    (Oxford Street)
            └ ITEM  (SKU)

  Plus: SUPPLIER (SUPS), PROMOTION, CUSTOMER, and a 4-5-4 RETAIL CALENDAR --
  which is the detail that marks out someone who has actually done retail.
  Retail does NOT use calendar months. It uses a 4-5-4 fiscal calendar: each
  quarter is a 4-week, 5-week, 4-week period, every week starts on the same
  weekday, and years are 52 or 53 weeks. It exists so that week-over-week and
  year-over-year comparisons line up on the same day of the week -- comparing a
  month containing five Saturdays with one containing four is meaningless in a
  business where Saturday is 30% of trade.

  15 DIMENSIONS   dim_calendar, division, group, department, class, subclass,
                  item, supplier, chain, area, region, district, store,
                  promotion, customer
  3 FACTS         fct_sales, fct_inventory, fct_receipts
  10 MATERIALIZED VIEWS   5 over sales, 5 over inventory
  10 BUSINESS QUESTIONS   answered with OLAP over those MVs

THE ARCHITECTURAL RULE THIS FILE FOLLOWS  (learned from module 77)
  ** MATERIALIZED VIEWS AGGREGATE. WINDOW FUNCTIONS GO ON TOP. **
  Every MV below is a plain SELECT / JOIN / GROUP BY / SUM / COUNT, which keeps
  it INCREMENTALLY refreshable. Not one contains a window function, a DISTINCT
  aggregate, an OUTER JOIN or a subquery -- all of which silently force a full
  recompute on every refresh. The OLAP lives in the report queries that read the
  MVs, where it costs nothing because it runs over a few thousand pre-aggregated
  rows instead of half a million fact rows.
  If you take one thing from this file into your own work, take that.

VERIFICATION NOTE: this file has NOT been run on a live cluster. Syntax follows
the Redshift Database Developer Guide; the retail model follows Oracle Retail
RMS conventions. Run the section-0 row-count checks before trusting any figure.
======================================================================================
*/


-- ============================================================================
-- SECTION 0: SCHEMA
-- ============================================================================
CREATE SCHEMA IF NOT EXISTS rms;      -- raw / dimensional model
CREATE SCHEMA IF NOT EXISTS rpt;      -- the reporting layer (MVs + report tables)


-- ############################################################################
-- SECTION 1: THE 15 DIMENSIONS
-- ############################################################################

-- ---------------------------------------------------------------------------
-- D1. dim_calendar — the 4-5-4 retail calendar, 2 fiscal years
-- ---------------------------------------------------------------------------
-- The single most important dimension in retail and the one most often built
-- wrong. Fiscal 2025 starts 2025-02-02 (a Sunday). Every fiscal week runs
-- Sunday-Saturday. 52 weeks x 7 days = 364 days per year.
DROP TABLE IF EXISTS rms.dim_calendar CASCADE;
CREATE TABLE rms.dim_calendar (
    day_key         INT          NOT NULL,   -- yyyymmdd
    calendar_date   DATE         NOT NULL,
    fiscal_year     INT          NOT NULL,
    fiscal_quarter  INT          NOT NULL,   -- 1..4
    fiscal_period   INT          NOT NULL,   -- 1..12  (the 4-5-4 "month")
    fiscal_week     INT          NOT NULL,   -- 1..52  within the year
    week_key        INT          NOT NULL,   -- fiscal_year*100 + fiscal_week
    day_of_week     INT          NOT NULL,   -- 1=Sunday .. 7=Saturday
    day_name        CHAR(3)      NOT NULL,
    is_weekend      BOOLEAN      NOT NULL,
    week_start_date DATE         NOT NULL
)
DISTSTYLE ALL
SORTKEY (calendar_date);

INSERT INTO rms.dim_calendar
SELECT
    (TO_CHAR(d.cal_date, 'YYYYMMDD'))::INT                      AS day_key,
    d.cal_date,
    2025 + (d.n / 364)                                          AS fiscal_year,
    ((d.n % 364) / 91) + 1                                      AS fiscal_quarter,
    -- 4-5-4: within each 91-day quarter, periods are 28 / 35 / 28 days
    (((d.n % 364) / 91) * 3)
      + CASE WHEN (d.n % 91) < 28 THEN 1
             WHEN (d.n % 91) < 63 THEN 2
             ELSE 3 END                                         AS fiscal_period,
    ((d.n % 364) / 7) + 1                                       AS fiscal_week,
    (2025 + (d.n / 364)) * 100 + (((d.n % 364) / 7) + 1)        AS week_key,
    (d.n % 7) + 1                                               AS day_of_week,
    CASE d.n % 7 WHEN 0 THEN 'Sun' WHEN 1 THEN 'Mon' WHEN 2 THEN 'Tue'
                 WHEN 3 THEN 'Wed' WHEN 4 THEN 'Thu' WHEN 5 THEN 'Fri'
                 ELSE 'Sat' END                                 AS day_name,
    CASE WHEN (d.n % 7) IN (0, 6) THEN TRUE ELSE FALSE END      AS is_weekend,
    DATEADD(day, -(d.n % 7), d.cal_date)                        AS week_start_date
FROM (
    SELECT s.n, DATEADD(day, s.n, '2025-02-02'::DATE) AS cal_date
    FROM (
        SELECT ROW_NUMBER() OVER () - 1 AS n
        FROM (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) a
        CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) b
        CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) c
        LIMIT 728
    ) s
) d;

-- ---------------------------------------------------------------------------
-- D2-D6. The MERCHANDISE HIERARCHY — division > group > dept > class > subclass
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS rms.dim_division CASCADE;
CREATE TABLE rms.dim_division (
    division_id   INT         NOT NULL,
    division_name VARCHAR(40) NOT NULL,
    buyer_name    VARCHAR(40) NOT NULL
) DISTSTYLE ALL;
INSERT INTO rms.dim_division VALUES
    (1,'Softlines','A. Whitfield'), (2,'Hardlines','R. Okafor'),
    (3,'Grocery','M. Lindqvist');

DROP TABLE IF EXISTS rms.dim_group CASCADE;
CREATE TABLE rms.dim_group (
    group_id    INT         NOT NULL,
    division_id INT         NOT NULL,
    group_name  VARCHAR(40) NOT NULL
) DISTSTYLE ALL;
INSERT INTO rms.dim_group VALUES
    (10,1,'Womenswear'), (11,1,'Menswear'),   (12,1,'Childrenswear'),
    (20,2,'Home & Garden'), (21,2,'Electricals'),
    (30,3,'Fresh Food'), (31,3,'Ambient Grocery');

DROP TABLE IF EXISTS rms.dim_department CASCADE;
CREATE TABLE rms.dim_department (
    dept_id   INT         NOT NULL,
    group_id  INT         NOT NULL,
    dept_name VARCHAR(40) NOT NULL,
    -- RMS carries the markup target on the department. It drives margin reporting.
    target_margin_pct DECIMAL(5,2) NOT NULL
) DISTSTYLE ALL;
INSERT INTO rms.dim_department VALUES
    (100,10,'Dresses',52.00),      (101,10,'Knitwear',48.00),
    (102,11,'Mens Shirts',50.00),  (103,11,'Mens Tailoring',55.00),
    (104,12,'Kids Tops',45.00),
    (200,20,'Cookware',42.00),     (201,20,'Bedding',46.00),
    (202,21,'Small Appliances',30.00),
    (300,30,'Produce',22.00),      (301,31,'Confectionery',35.00);

DROP TABLE IF EXISTS rms.dim_class CASCADE;
CREATE TABLE rms.dim_class (
    class_id   INT         NOT NULL,
    dept_id    INT         NOT NULL,
    class_name VARCHAR(40) NOT NULL
) DISTSTYLE ALL;
INSERT INTO rms.dim_class
SELECT 1000 + s.n,
       d.dept_id,
       'Class ' || (s.n % 3 + 1)::VARCHAR || ' - ' || d.dept_name
FROM rms.dim_department d
CROSS JOIN (SELECT 0 AS n UNION SELECT 1 UNION SELECT 2) s;   -- 3 classes per dept = 30

DROP TABLE IF EXISTS rms.dim_subclass CASCADE;
CREATE TABLE rms.dim_subclass (
    subclass_id   INT         NOT NULL,
    class_id      INT         NOT NULL,
    subclass_name VARCHAR(40) NOT NULL
) DISTSTYLE ALL;
INSERT INTO rms.dim_subclass
SELECT ROW_NUMBER() OVER (ORDER BY c.class_id, s.n) + 10000,
       c.class_id,
       'Subclass ' || (s.n + 1)::VARCHAR
FROM rms.dim_class c
CROSS JOIN (SELECT 0 AS n UNION SELECT 1) s;                   -- 2 subclasses per class = 60

-- ---------------------------------------------------------------------------
-- D7. dim_item — ITEM_MASTER. The leaf of the merchandise hierarchy.
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS rms.dim_item CASCADE;
CREATE TABLE rms.dim_item (
    item_id        INT           NOT NULL,
    item_desc      VARCHAR(80)   NOT NULL,
    subclass_id    INT           NOT NULL,
    class_id       INT           NOT NULL,
    dept_id        INT           NOT NULL,
    supplier_id    INT           NOT NULL,
    unit_cost      DECIMAL(10,2) NOT NULL,
    unit_retail    DECIMAL(10,2) NOT NULL,
    item_status    VARCHAR(10)   NOT NULL,   -- ACTIVE / DISCON
    launch_week    INT           NOT NULL
)
DISTSTYLE KEY DISTKEY (item_id)
SORTKEY (item_id);

INSERT INTO rms.dim_item
SELECT
    50000 + s.n                                              AS item_id,
    'ITEM ' || (50000 + s.n)::VARCHAR                        AS item_desc,
    sc.subclass_id,
    sc.class_id,
    c.dept_id,
    900 + (s.n % 12)                                         AS supplier_id,
    (4.00 + (s.n % 60))::DECIMAL(10,2)                       AS unit_cost,
    -- retail is cost marked up between ~1.6x and ~2.6x
    ((4.00 + (s.n % 60)) * (1.6 + ((s.n % 10) / 10.0)))::DECIMAL(10,2) AS unit_retail,
    CASE WHEN s.n % 25 = 0 THEN 'DISCON' ELSE 'ACTIVE' END   AS item_status,
    202501 + (s.n % 40)                                      AS launch_week
FROM (
    SELECT ROW_NUMBER() OVER () AS n
    FROM (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) a
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) b
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) c
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) d
    LIMIT 1200
) s
JOIN rms.dim_subclass sc ON sc.subclass_id = 10001 + (s.n % 60)
JOIN rms.dim_class    c  ON c.class_id      = sc.class_id;

-- ---------------------------------------------------------------------------
-- D8. dim_supplier — SUPS
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS rms.dim_supplier CASCADE;
CREATE TABLE rms.dim_supplier (
    supplier_id     INT         NOT NULL,
    supplier_name   VARCHAR(50) NOT NULL,
    country         CHAR(2)     NOT NULL,
    lead_time_days  INT         NOT NULL,
    otif_target_pct DECIMAL(5,2) NOT NULL
) DISTSTYLE ALL;
INSERT INTO rms.dim_supplier
SELECT 900 + s.n,
       'Supplier ' || CHR(65 + s.n),
       CASE s.n % 4 WHEN 0 THEN 'CN' WHEN 1 THEN 'IN' WHEN 2 THEN 'TR' ELSE 'PT' END,
       7 + (s.n % 5) * 7,
       95.00
FROM (SELECT 0 AS n UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5
      UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9 UNION SELECT 10 UNION SELECT 11) s;

-- ---------------------------------------------------------------------------
-- D9-D13. The ORGANIZATIONAL HIERARCHY — chain > area > region > district > store
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS rms.dim_chain CASCADE;
CREATE TABLE rms.dim_chain (
    chain_id INT NOT NULL, chain_name VARCHAR(40) NOT NULL
) DISTSTYLE ALL;
INSERT INTO rms.dim_chain VALUES (1,'Full Line'), (2,'Outlet');

DROP TABLE IF EXISTS rms.dim_area CASCADE;
CREATE TABLE rms.dim_area (
    area_id INT NOT NULL, chain_id INT NOT NULL, area_name VARCHAR(40) NOT NULL
) DISTSTYLE ALL;
INSERT INTO rms.dim_area VALUES
    (10,1,'UK & Ireland'), (11,1,'Western Europe'), (12,1,'Nordics'), (13,2,'Outlet Europe');

DROP TABLE IF EXISTS rms.dim_region CASCADE;
CREATE TABLE rms.dim_region (
    region_id INT NOT NULL, area_id INT NOT NULL, region_name VARCHAR(40) NOT NULL
) DISTSTYLE ALL;
INSERT INTO rms.dim_region VALUES
    (100,10,'England South'), (101,10,'England North'), (102,10,'Scotland & NI'),
    (110,11,'France'), (111,11,'Germany'), (112,11,'Iberia'),
    (120,12,'Sweden & Denmark'), (130,13,'Outlet North'), (131,13,'Outlet South');

DROP TABLE IF EXISTS rms.dim_district CASCADE;
CREATE TABLE rms.dim_district (
    district_id INT NOT NULL, region_id INT NOT NULL, district_name VARCHAR(40) NOT NULL
) DISTSTYLE ALL;
INSERT INTO rms.dim_district
SELECT 1000 + ROW_NUMBER() OVER (ORDER BY r.region_id, s.n),
       r.region_id,
       r.region_name || ' D' || (s.n + 1)::VARCHAR
FROM rms.dim_region r
CROSS JOIN (SELECT 0 AS n UNION SELECT 1) s;                   -- 2 districts per region = 18

DROP TABLE IF EXISTS rms.dim_store CASCADE;
CREATE TABLE rms.dim_store (
    store_id     INT           NOT NULL,
    store_name   VARCHAR(50)   NOT NULL,
    district_id  INT           NOT NULL,
    region_id    INT           NOT NULL,
    area_id      INT           NOT NULL,
    chain_id     INT           NOT NULL,
    store_format VARCHAR(20)   NOT NULL,   -- FLAGSHIP / HIGHSTREET / OUTLET
    selling_sqft INT           NOT NULL,
    open_week    INT           NOT NULL
)
DISTSTYLE ALL
SORTKEY (store_id);

INSERT INTO rms.dim_store
SELECT
    5000 + s.n,
    'Store ' || (5000 + s.n)::VARCHAR,
    d.district_id,
    d.region_id,
    r.area_id,
    a.chain_id,
    CASE WHEN s.n % 10 = 0 THEN 'FLAGSHIP'
         WHEN a.chain_id = 2 THEN 'OUTLET' ELSE 'HIGHSTREET' END,
    8000 + (s.n % 12) * 2500,
    202501
FROM (
    SELECT ROW_NUMBER() OVER () AS n
    FROM (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) a
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) b
    LIMIT 72
) s
JOIN rms.dim_district d ON d.district_id = 1001 + (s.n % 18)
JOIN rms.dim_region   r ON r.region_id   = d.region_id
JOIN rms.dim_area     a ON a.area_id     = r.area_id;

-- ---------------------------------------------------------------------------
-- D14. dim_promotion
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS rms.dim_promotion CASCADE;
CREATE TABLE rms.dim_promotion (
    promo_id       INT          NOT NULL,
    promo_name     VARCHAR(50)  NOT NULL,
    promo_type     VARCHAR(20)  NOT NULL,   -- MARKDOWN / MULTIBUY / NONE
    discount_pct   DECIMAL(5,2) NOT NULL,
    start_week_key INT          NOT NULL,
    end_week_key   INT          NOT NULL
) DISTSTYLE ALL;
INSERT INTO rms.dim_promotion VALUES
    (0,  'No Promotion',      'NONE',      0.00, 202501, 202652),
    (1,  'Spring Markdown',   'MARKDOWN', 20.00, 202510, 202514),
    (2,  'Summer Clearance',  'MARKDOWN', 35.00, 202522, 202528),
    (3,  'Back to School',    'MULTIBUY', 15.00, 202530, 202535),
    (4,  'Black Friday',      'MARKDOWN', 40.00, 202543, 202545),
    (5,  'Festive Multibuy',  'MULTIBUY', 25.00, 202546, 202552),
    (6,  'New Year Clear',    'MARKDOWN', 50.00, 202601, 202605);

-- ---------------------------------------------------------------------------
-- D15. dim_customer — loyalty base
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS rms.dim_customer CASCADE;
CREATE TABLE rms.dim_customer (
    customer_id   INT         NOT NULL,
    loyalty_tier  VARCHAR(10) NOT NULL,   -- BRONZE / SILVER / GOLD / NONE
    home_store_id INT         NOT NULL,
    signup_week   INT         NOT NULL
)
DISTSTYLE KEY DISTKEY (customer_id);

INSERT INTO rms.dim_customer
SELECT
    700000 + s.n,
    CASE s.n % 8 WHEN 0 THEN 'GOLD' WHEN 1 THEN 'SILVER'
                 WHEN 2 THEN 'SILVER' WHEN 3 THEN 'BRONZE' ELSE 'BRONZE' END,
    5001 + (s.n % 72),
    202501 + (s.n % 52)
FROM (
    SELECT ROW_NUMBER() OVER () AS n
    FROM (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) a
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) b
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) c
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) d
    LIMIT 5000
) s;


-- ############################################################################
-- SECTION 2: THE 3 FACT TABLES
-- ############################################################################
-- DISTKEY choice matters here and is not arbitrary. All three facts are
-- distributed on item_id, and dim_item is distributed on item_id too, so the
-- item join is COLLOCATED (module 28). Every dimension small enough to be
-- DISTSTYLE ALL is, so those joins move nothing at all (module 29).

-- ---------------------------------------------------------------------------
-- F1. fct_sales — POS sales. Grain: one row per item / store / day / promo.
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS rms.fct_sales CASCADE;
CREATE TABLE rms.fct_sales (
    day_key       INT           NOT NULL,
    week_key      INT           NOT NULL,
    item_id       INT           NOT NULL,
    store_id      INT           NOT NULL,
    promo_id      INT           NOT NULL,
    customer_id   INT           NOT NULL,
    sales_units   INT           NOT NULL,
    sales_retail  DECIMAL(12,2) NOT NULL,   -- what the customer actually paid
    sales_cost    DECIMAL(12,2) NOT NULL,   -- cost of goods sold
    markdown_amt  DECIMAL(12,2) NOT NULL    -- retail given away via promotion
)
DISTSTYLE KEY DISTKEY (item_id)
COMPOUND SORTKEY (week_key, item_id);

INSERT INTO rms.fct_sales
SELECT
    cal.day_key,
    cal.week_key,
    i.item_id,
    5001 + (s.n % 72)                                          AS store_id,
    NVL(p.promo_id, 0)                                         AS promo_id,
    700001 + (s.n % 5000)                                      AS customer_id,
    CASE WHEN s.n % 17 = 0 THEN 8 WHEN s.n % 11 = 0 THEN 5
         WHEN s.n %  5 = 0 THEN 3 WHEN s.n %  2 = 0 THEN 2 ELSE 1 END AS sales_units,
    ROUND((CASE WHEN s.n % 17 = 0 THEN 8 WHEN s.n % 11 = 0 THEN 5
                WHEN s.n %  5 = 0 THEN 3 WHEN s.n %  2 = 0 THEN 2 ELSE 1 END)
          * i.unit_retail
          * (1 - NVL(p.discount_pct, 0)/100.0)
          * CASE WHEN cal.is_weekend THEN 1.35 ELSE 1.00 END, 2) AS sales_retail,
    ROUND((CASE WHEN s.n % 17 = 0 THEN 8 WHEN s.n % 11 = 0 THEN 5
                WHEN s.n %  5 = 0 THEN 3 WHEN s.n %  2 = 0 THEN 2 ELSE 1 END)
          * i.unit_cost, 2)                                     AS sales_cost,
    ROUND((CASE WHEN s.n % 17 = 0 THEN 8 WHEN s.n % 11 = 0 THEN 5
                WHEN s.n %  5 = 0 THEN 3 WHEN s.n %  2 = 0 THEN 2 ELSE 1 END)
          * i.unit_retail * (NVL(p.discount_pct, 0)/100.0), 2)  AS markdown_amt
FROM (
    SELECT ROW_NUMBER() OVER () AS n
    FROM (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) a
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) b
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) c
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) d
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) e
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) f
    LIMIT 500000
) s
JOIN rms.dim_item i
  ON i.item_id = 50001 + (s.n % 1200)
JOIN rms.dim_calendar cal
  ON cal.calendar_date = DATEADD(day, (s.n % 700), '2025-02-02'::DATE)
LEFT JOIN rms.dim_promotion p
  ON p.promo_id > 0
 AND cal.week_key BETWEEN p.start_week_key AND p.end_week_key
 AND (s.n % 3) = 0;      -- only a third of lines participate in the live promo

-- ---------------------------------------------------------------------------
-- F2. fct_inventory — weekly stock snapshot. Grain: item / store / week.
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS rms.fct_inventory CASCADE;
CREATE TABLE rms.fct_inventory (
    week_key       INT           NOT NULL,
    item_id        INT           NOT NULL,
    store_id       INT           NOT NULL,
    soh_units      INT           NOT NULL,   -- stock on hand
    on_order_units INT           NOT NULL,
    soh_cost       DECIMAL(12,2) NOT NULL,
    soh_retail     DECIMAL(12,2) NOT NULL
)
DISTSTYLE KEY DISTKEY (item_id)
COMPOUND SORTKEY (week_key, item_id);

INSERT INTO rms.fct_inventory
SELECT
    202501 + (s.n % 104)                                     AS week_key,
    i.item_id,
    5001 + (s.n % 72)                                        AS store_id,
    GREATEST(0, 120 - (s.n % 130))                           AS soh_units,
    CASE WHEN s.n % 7 = 0 THEN 40 ELSE 0 END                 AS on_order_units,
    ROUND(GREATEST(0, 120 - (s.n % 130)) * i.unit_cost, 2)   AS soh_cost,
    ROUND(GREATEST(0, 120 - (s.n % 130)) * i.unit_retail, 2) AS soh_retail
FROM (
    SELECT ROW_NUMBER() OVER () AS n
    FROM (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) a
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) b
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) c
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) d
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) e
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2) f
    LIMIT 200000
) s
JOIN rms.dim_item i ON i.item_id = 50001 + (s.n % 1200);

-- ---------------------------------------------------------------------------
-- F3. fct_receipts — PO receipts, for supplier OTIF. Grain: item/store/week/PO.
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS rms.fct_receipts CASCADE;
CREATE TABLE rms.fct_receipts (
    week_key        INT           NOT NULL,
    item_id         INT           NOT NULL,
    store_id        INT           NOT NULL,
    supplier_id     INT           NOT NULL,
    po_number       INT           NOT NULL,
    ordered_units   INT           NOT NULL,
    received_units  INT           NOT NULL,
    days_late       INT           NOT NULL,   -- 0 = on time
    receipt_cost    DECIMAL(12,2) NOT NULL
)
DISTSTYLE KEY DISTKEY (item_id)
COMPOUND SORTKEY (week_key, supplier_id);

INSERT INTO rms.fct_receipts
SELECT
    202501 + (s.n % 104)                                       AS week_key,
    i.item_id,
    5001 + (s.n % 72)                                          AS store_id,
    i.supplier_id,
    800000 + s.n                                               AS po_number,
    100 + (s.n % 200)                                          AS ordered_units,
    -- short shipments cluster on a couple of suppliers, which is realistic and
    -- makes the OTIF question in Q9 produce an actual answer
    CASE WHEN i.supplier_id IN (903, 907) AND s.n % 3 = 0
         THEN (100 + (s.n % 200)) - (10 + (s.n % 30))
         ELSE 100 + (s.n % 200) END                            AS received_units,
    CASE WHEN i.supplier_id IN (903, 907) AND s.n % 4 = 0 THEN 3 + (s.n % 9)
         WHEN s.n % 23 = 0 THEN 1 + (s.n % 3)
         ELSE 0 END                                            AS days_late,
    ROUND((100 + (s.n % 200)) * i.unit_cost, 2)                AS receipt_cost
FROM (
    SELECT ROW_NUMBER() OVER () AS n
    FROM (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) a
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) b
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) c
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) d
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) e
    LIMIT 60000
) s
JOIN rms.dim_item i ON i.item_id = 50001 + (s.n % 1200);

ANALYZE rms.fct_sales;
ANALYZE rms.fct_inventory;
ANALYZE rms.fct_receipts;

-- ---------------------------------------------------------------------------
-- SANITY CHECK — run this before trusting a single number below
-- ---------------------------------------------------------------------------
SELECT 'dim_calendar' AS obj, COUNT(*) AS rows FROM rms.dim_calendar
UNION ALL SELECT 'dim_item',      COUNT(*) FROM rms.dim_item
UNION ALL SELECT 'dim_store',     COUNT(*) FROM rms.dim_store
UNION ALL SELECT 'dim_subclass',  COUNT(*) FROM rms.dim_subclass
UNION ALL SELECT 'dim_customer',  COUNT(*) FROM rms.dim_customer
UNION ALL SELECT 'fct_sales',     COUNT(*) FROM rms.fct_sales
UNION ALL SELECT 'fct_inventory', COUNT(*) FROM rms.fct_inventory
UNION ALL SELECT 'fct_receipts',  COUNT(*) FROM rms.fct_receipts
ORDER BY 1;
/* Expect roughly:
   dim_calendar 728 | dim_item 1200 | dim_store 72 | dim_subclass 60
   dim_customer 5000 | fct_sales 500000 | fct_inventory 200000 | fct_receipts 60000  */

-- Prove the 4-5-4 calendar is right — periods must run 4,5,4 weeks per quarter:
SELECT fiscal_year, fiscal_quarter, fiscal_period,
       COUNT(DISTINCT fiscal_week) AS weeks_in_period,
       COUNT(*) AS days_in_period
FROM rms.dim_calendar
WHERE fiscal_year = 2025
GROUP BY 1,2,3
ORDER BY 1,2,3;
-- Expect days_in_period to alternate 28 / 35 / 28 across each quarter.


-- ############################################################################
-- SECTION 3: THE REPORTING LAYER — 10 MATERIALIZED VIEWS
-- ############################################################################
-- READ THIS BEFORE THE DDL.
-- Every MV below is deliberately BORING: SELECT, INNER JOIN, GROUP BY, SUM,
-- COUNT. Nothing more. That is what keeps them INCREMENTALLY refreshable, so a
-- refresh touches only the changed rows instead of rebuilding half a million.
--
-- Not one contains a window function, COUNT(DISTINCT), an OUTER JOIN, a subquery
-- or ORDER BY. Every one of those silently forces a FULL RECOMPUTE (module 77),
-- and on a fact table this is exactly where a nightly refresh quietly becomes a
-- two-hour job that nobody can explain.
--
-- The OLAP lives in Section 5, on top of these. That is the whole architecture.

-- ===== SET A — FIVE MVs OVER fct_sales =====================================

-- A1. Item x week — the workhorse. Feeds Q1, Q2, Q4, Q5.
DROP MATERIALIZED VIEW IF EXISTS rpt.mv_sales_item_week;
CREATE MATERIALIZED VIEW rpt.mv_sales_item_week
DISTSTYLE KEY DISTKEY (item_id)
AUTO REFRESH YES
AS
SELECT
    f.week_key,
    f.item_id,
    i.dept_id,
    i.class_id,
    i.subclass_id,
    i.supplier_id,
    SUM(f.sales_units)  AS sales_units,
    SUM(f.sales_retail) AS sales_retail,
    SUM(f.sales_cost)   AS sales_cost,
    SUM(f.markdown_amt) AS markdown_amt,
    COUNT(*)            AS line_count
FROM rms.fct_sales f
JOIN rms.dim_item  i ON i.item_id = f.item_id
GROUP BY f.week_key, f.item_id, i.dept_id, i.class_id, i.subclass_id, i.supplier_id;

-- A2. Department x store x week — feeds Q1, Q6, Q7.
DROP MATERIALIZED VIEW IF EXISTS rpt.mv_sales_dept_store_week;
CREATE MATERIALIZED VIEW rpt.mv_sales_dept_store_week
AUTO REFRESH YES
AS
SELECT
    f.week_key,
    i.dept_id,
    f.store_id,
    st.district_id,
    st.region_id,
    st.area_id,
    SUM(f.sales_units)  AS sales_units,
    SUM(f.sales_retail) AS sales_retail,
    SUM(f.sales_cost)   AS sales_cost,
    SUM(f.markdown_amt) AS markdown_amt
FROM rms.fct_sales f
JOIN rms.dim_item  i  ON i.item_id  = f.item_id
JOIN rms.dim_store st ON st.store_id = f.store_id
GROUP BY f.week_key, i.dept_id, f.store_id, st.district_id, st.region_id, st.area_id;

-- A3. Class x week — the margin grain. Feeds Q6.
DROP MATERIALIZED VIEW IF EXISTS rpt.mv_sales_class_week;
CREATE MATERIALIZED VIEW rpt.mv_sales_class_week
AUTO REFRESH YES
AS
SELECT
    f.week_key,
    i.class_id,
    i.dept_id,
    SUM(f.sales_units)  AS sales_units,
    SUM(f.sales_retail) AS sales_retail,
    SUM(f.sales_cost)   AS sales_cost,
    SUM(f.markdown_amt) AS markdown_amt
FROM rms.fct_sales f
JOIN rms.dim_item i ON i.item_id = f.item_id
GROUP BY f.week_key, i.class_id, i.dept_id;

-- A4. Store x day — the trading-pattern grain. Feeds Q4 (day-of-week effects).
DROP MATERIALIZED VIEW IF EXISTS rpt.mv_sales_store_day;
CREATE MATERIALIZED VIEW rpt.mv_sales_store_day
AUTO REFRESH YES
AS
SELECT
    f.day_key,
    f.week_key,
    f.store_id,
    c.day_of_week,
    c.is_weekend,
    SUM(f.sales_units)  AS sales_units,
    SUM(f.sales_retail) AS sales_retail,
    COUNT(*)            AS line_count
FROM rms.fct_sales f
JOIN rms.dim_calendar c ON c.day_key = f.day_key
GROUP BY f.day_key, f.week_key, f.store_id, c.day_of_week, c.is_weekend;

-- A5. Promotion x item x week — feeds Q10 (promo lift).
DROP MATERIALIZED VIEW IF EXISTS rpt.mv_sales_promo_item_week;
CREATE MATERIALIZED VIEW rpt.mv_sales_promo_item_week
DISTSTYLE KEY DISTKEY (item_id)
AUTO REFRESH YES
AS
SELECT
    f.week_key,
    f.promo_id,
    f.item_id,
    i.dept_id,
    SUM(f.sales_units)  AS sales_units,
    SUM(f.sales_retail) AS sales_retail,
    SUM(f.markdown_amt) AS markdown_amt
FROM rms.fct_sales f
JOIN rms.dim_item i ON i.item_id = f.item_id
GROUP BY f.week_key, f.promo_id, f.item_id, i.dept_id;

-- ===== SET B — FIVE MVs OVER fct_inventory AND fct_receipts ================

-- B1. Inventory item x store x week — feeds Q3, Q8.
DROP MATERIALIZED VIEW IF EXISTS rpt.mv_inv_item_store_week;
CREATE MATERIALIZED VIEW rpt.mv_inv_item_store_week
DISTSTYLE KEY DISTKEY (item_id)
AUTO REFRESH YES
AS
SELECT
    v.week_key,
    v.item_id,
    v.store_id,
    i.dept_id,
    i.class_id,
    SUM(v.soh_units)      AS soh_units,
    SUM(v.on_order_units) AS on_order_units,
    SUM(v.soh_cost)       AS soh_cost,
    SUM(v.soh_retail)     AS soh_retail
FROM rms.fct_inventory v
JOIN rms.dim_item i ON i.item_id = v.item_id
GROUP BY v.week_key, v.item_id, v.store_id, i.dept_id, i.class_id;

-- B2. Inventory department x week — the stock-investment grain.
DROP MATERIALIZED VIEW IF EXISTS rpt.mv_inv_dept_week;
CREATE MATERIALIZED VIEW rpt.mv_inv_dept_week
AUTO REFRESH YES
AS
SELECT
    v.week_key,
    i.dept_id,
    SUM(v.soh_units)  AS soh_units,
    SUM(v.soh_cost)   AS soh_cost,
    SUM(v.soh_retail) AS soh_retail,
    COUNT(*)          AS sku_store_count
FROM rms.fct_inventory v
JOIN rms.dim_item i ON i.item_id = v.item_id
GROUP BY v.week_key, i.dept_id;

-- B3. Inventory class x store x week — feeds the space/productivity view.
DROP MATERIALIZED VIEW IF EXISTS rpt.mv_inv_class_store_week;
CREATE MATERIALIZED VIEW rpt.mv_inv_class_store_week
AUTO REFRESH YES
AS
SELECT
    v.week_key,
    i.class_id,
    v.store_id,
    st.region_id,
    SUM(v.soh_units)  AS soh_units,
    SUM(v.soh_cost)   AS soh_cost,
    SUM(v.soh_retail) AS soh_retail
FROM rms.fct_inventory v
JOIN rms.dim_item  i  ON i.item_id  = v.item_id
JOIN rms.dim_store st ON st.store_id = v.store_id
GROUP BY v.week_key, i.class_id, v.store_id, st.region_id;

-- B4. Receipts supplier x week — feeds Q9 (OTIF).
DROP MATERIALIZED VIEW IF EXISTS rpt.mv_receipts_supplier_week;
CREATE MATERIALIZED VIEW rpt.mv_receipts_supplier_week
AUTO REFRESH YES
AS
SELECT
    r.week_key,
    r.supplier_id,
    SUM(r.ordered_units)  AS ordered_units,
    SUM(r.received_units) AS received_units,
    SUM(r.receipt_cost)   AS receipt_cost,
    COUNT(*)              AS po_lines,
    -- SUM(CASE...) is incremental-safe. COUNT(DISTINCT ...) would NOT be.
    SUM(CASE WHEN r.days_late = 0 THEN 1 ELSE 0 END)                       AS on_time_lines,
    SUM(CASE WHEN r.received_units >= r.ordered_units THEN 1 ELSE 0 END)   AS in_full_lines,
    SUM(CASE WHEN r.days_late = 0
              AND r.received_units >= r.ordered_units THEN 1 ELSE 0 END)   AS otif_lines
FROM rms.fct_receipts r
GROUP BY r.week_key, r.supplier_id;

-- B5. Receipts item x week — feeds inbound-flow analysis.
DROP MATERIALIZED VIEW IF EXISTS rpt.mv_receipts_item_week;
CREATE MATERIALIZED VIEW rpt.mv_receipts_item_week
DISTSTYLE KEY DISTKEY (item_id)
AUTO REFRESH YES
AS
SELECT
    r.week_key,
    r.item_id,
    r.supplier_id,
    SUM(r.ordered_units)  AS ordered_units,
    SUM(r.received_units) AS received_units,
    SUM(r.receipt_cost)   AS receipt_cost
FROM rms.fct_receipts r
GROUP BY r.week_key, r.item_id, r.supplier_id;

-- ---------------------------------------------------------------------------
-- PROVE THE ARCHITECTURAL CLAIM. state = 1 means INCREMENTAL on every row.
-- ---------------------------------------------------------------------------
SELECT
    "schema", name, state,
    CASE state WHEN 1 THEN 'INCREMENTAL — cheap refresh'
               WHEN 0 THEN 'FULL RECOMPUTE — something in the SELECT blocked it'
               ELSE 'BROKEN by DDL on a base table' END AS refresh_method,
    autorefresh, is_stale
FROM stv_mv_info
WHERE "schema" = 'rpt'
ORDER BY name;
-- If ANY row reads 0, look at that MV's SELECT for a window function, a DISTINCT
-- aggregate, an OUTER JOIN or a subquery. That is the deal this file is making:
-- keep the MVs boring, and put the cleverness in Section 5.


-- ############################################################################
-- SECTION 4: THE CODE — PROCEDURES THAT BUILD AND MAINTAIN THE LAYER
-- ############################################################################
-- This is module 62's language features doing real work. Between them the three
-- procedures below use: %TYPE and %ROWTYPE anchoring, RECORD, a cursor FOR loop,
-- IF/ELSIF, WHILE, dynamic SQL with QUOTE_IDENT, SELECT INTO and INTO STRICT,
-- GET DIAGNOSTICS, IN/OUT/INOUT parameters, nested BEGIN...EXCEPTION blocks,
-- SQLSTATE/SQLERRM capture, RAISE at three severities, and persistent auditing.

-- ---------------------------------------------------------------------------
-- Control and audit tables
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS rpt.ctl_mv_refresh CASCADE;
CREATE TABLE rpt.ctl_mv_refresh (
    mv_name      VARCHAR(60) NOT NULL,
    mv_group     VARCHAR(20) NOT NULL,   -- SALES / SUPPLY
    run_order    INT         NOT NULL,
    is_active    BOOLEAN     NOT NULL
) DISTSTYLE ALL;

INSERT INTO rpt.ctl_mv_refresh VALUES
    ('mv_sales_item_week',        'SALES',  10, TRUE),
    ('mv_sales_dept_store_week',  'SALES',  20, TRUE),
    ('mv_sales_class_week',       'SALES',  30, TRUE),
    ('mv_sales_store_day',        'SALES',  40, TRUE),
    ('mv_sales_promo_item_week',  'SALES',  50, TRUE),
    ('mv_inv_item_store_week',    'SUPPLY', 60, TRUE),
    ('mv_inv_dept_week',          'SUPPLY', 70, TRUE),
    ('mv_inv_class_store_week',   'SUPPLY', 80, TRUE),
    ('mv_receipts_supplier_week', 'SUPPLY', 90, TRUE),
    ('mv_receipts_item_week',     'SUPPLY', 100, TRUE);

DROP TABLE IF EXISTS rpt.audit_report_build CASCADE;
CREATE TABLE rpt.audit_report_build (
    audit_id      BIGINT IDENTITY(1,1),
    proc_name     VARCHAR(60)   NOT NULL,
    step_name     VARCHAR(80)   NOT NULL,
    target_object VARCHAR(60),
    week_key      INT,
    start_time    TIMESTAMP     NOT NULL,
    end_time      TIMESTAMP     NOT NULL,
    duration_ms   BIGINT        NOT NULL,
    rows_affected BIGINT        NOT NULL,
    status        VARCHAR(12)   NOT NULL,
    sqlstate_code VARCHAR(10),
    error_message VARCHAR(1000)
) DISTSTYLE EVEN COMPOUND SORTKEY (start_time);

-- ===========================================================================
-- PROC 1 — sp_refresh_report_layer
-- ===========================================================================
-- Metadata-driven refresh of the whole MV layer, with per-step timing.
-- NOTE THE TIMING: GETDATE(), never SYSDATE. A procedure body is ONE
-- transaction and SYSDATE returns TRANSACTION start, so every duration would be
-- logged as 0. GETDATE() returns STATEMENT start. This is module 20's lesson and
-- it is the difference between an audit table and a table full of zeroes.
CREATE OR REPLACE PROCEDURE rpt.sp_refresh_report_layer(
    IN    p_mv_group    VARCHAR(20),
    IN    p_stop_on_err BOOLEAN,
    INOUT p_refreshed   INT
)
LANGUAGE plpgsql
AS $$
DECLARE
    c_proc_name   CONSTANT VARCHAR(60) := 'sp_refresh_report_layer';
    rec           RECORD;                                    -- Feature: RECORD
    v_mv          rpt.ctl_mv_refresh.mv_name%TYPE;           -- Feature: %TYPE
    v_sql         VARCHAR(MAX);
    v_step_start  TIMESTAMP;
    v_started     TIMESTAMP;
    v_failed      INT := 0;
    v_active_cnt  INT := 0;
    v_err_state   VARCHAR(10);
    v_err_msg     VARCHAR(1000);
BEGIN
    v_started    := GETDATE();
    p_refreshed  := 0;

    -- ---- validate, and fail early (module 19) ----------------------------
    IF p_mv_group IS NULL THEN
        RAISE EXCEPTION '[%] p_mv_group cannot be NULL. Use SALES, SUPPLY or ALL.', c_proc_name;
    END IF;

    SELECT COUNT(*) INTO v_active_cnt
    FROM rpt.ctl_mv_refresh
    WHERE is_active = TRUE
      AND (p_mv_group = 'ALL' OR mv_group = p_mv_group);

    IF v_active_cnt = 0 THEN
        RAISE WARNING '[%] no active MVs for group [%]. Nothing to do.', c_proc_name, p_mv_group;
        RETURN;
    END IF;

    RAISE INFO '[%] refreshing % materialized view(s) for group [%]...',
        c_proc_name, v_active_cnt, p_mv_group;

    -- ---- cursor FOR loop over the control table --------------------------
    FOR rec IN (
        SELECT mv_name, mv_group, run_order
        FROM rpt.ctl_mv_refresh
        WHERE is_active = TRUE
          AND (p_mv_group = 'ALL' OR mv_group = p_mv_group)
        ORDER BY run_order
    ) LOOP
        v_mv         := rec.mv_name;
        v_step_start := GETDATE();

        -- nested block so one failure does not abandon the rest of the run
        BEGIN
            -- dynamic SQL, identifier-sanitised (module 41)
            v_sql := 'REFRESH MATERIALIZED VIEW rpt.' || QUOTE_IDENT(v_mv) || ';';
            EXECUTE v_sql;

            p_refreshed := p_refreshed + 1;

            INSERT INTO rpt.audit_report_build
                (proc_name, step_name, target_object, start_time, end_time,
                 duration_ms, rows_affected, status)
            VALUES
                (c_proc_name, 'refresh ' || rec.mv_group, v_mv, v_step_start, GETDATE(),
                 DATEDIFF(ms, v_step_start, GETDATE()), 0, 'SUCCESS');

            RAISE INFO '   [ok] rpt.% refreshed in % ms',
                v_mv, DATEDIFF(ms, v_step_start, GETDATE());

        EXCEPTION WHEN OTHERS THEN
            v_err_state := SQLSTATE;
            v_err_msg   := SUBSTRING(SQLERRM, 1, 990);
            v_failed    := v_failed + 1;

            -- Statements in an exception block run in a NEW transaction that
            -- commits before the exception is re-thrown, so this row survives.
            INSERT INTO rpt.audit_report_build
                (proc_name, step_name, target_object, start_time, end_time,
                 duration_ms, rows_affected, status, sqlstate_code, error_message)
            VALUES
                (c_proc_name, 'refresh ' || rec.mv_group, v_mv, v_step_start, GETDATE(),
                 DATEDIFF(ms, v_step_start, GETDATE()), 0, 'FAILED', v_err_state, v_err_msg);

            IF p_stop_on_err THEN
                RAISE EXCEPTION '[%] aborted on [%] SQLSTATE [%]: %',
                    c_proc_name, v_mv, v_err_state, v_err_msg;
            ELSE
                RAISE WARNING '   [FAIL] rpt.% SQLSTATE [%]: %', v_mv, v_err_state, v_err_msg;
            END IF;
        END;
    END LOOP;

    RAISE INFO '[%] done in % ms. refreshed=% failed=%',
        c_proc_name, DATEDIFF(ms, v_started, GETDATE()), p_refreshed, v_failed;
END;
$$;

-- ===========================================================================
-- PROC 2 — sp_build_abc_classification
-- ===========================================================================
-- The Pareto / ABC engine. THIS is where the window functions live: in a
-- procedure writing to a plain table, NOT inside a materialized view.
-- A: top 80% of sales value.  B: next 15%.  C: the tail.
DROP TABLE IF EXISTS rpt.item_abc_class CASCADE;
CREATE TABLE rpt.item_abc_class (
    week_from      INT           NOT NULL,
    week_to        INT           NOT NULL,
    item_id        INT           NOT NULL,
    dept_id        INT           NOT NULL,
    sales_retail   DECIMAL(14,2) NOT NULL,
    cum_pct        DECIMAL(7,4)  NOT NULL,
    sales_rank     INT           NOT NULL,
    abc_class      CHAR(1)       NOT NULL,
    built_at       TIMESTAMP     NOT NULL
)
DISTSTYLE KEY DISTKEY (item_id)
COMPOUND SORTKEY (week_from, abc_class);

CREATE OR REPLACE PROCEDURE rpt.sp_build_abc_classification(
    IN  p_week_from INT,
    IN  p_week_to   INT,
    OUT p_a_count   INT,
    OUT p_b_count   INT,
    OUT p_c_count   INT
)
LANGUAGE plpgsql
AS $$
DECLARE
    c_proc_name  CONSTANT VARCHAR(60) := 'sp_build_abc_classification';
    v_step_start TIMESTAMP;
    v_total_val  DECIMAL(18,2);
    v_item_count INT;
    v_deleted    BIGINT := 0;
    v_inserted   BIGINT := 0;
    v_err_state  VARCHAR(10);
    v_err_msg    VARCHAR(1000);
BEGIN
    v_step_start := GETDATE();

    IF p_week_from IS NULL OR p_week_to IS NULL THEN
        RAISE EXCEPTION '[%] week range cannot be NULL.', c_proc_name;
    END IF;
    IF p_week_from > p_week_to THEN
        RAISE EXCEPTION '[%] week_from (%) is after week_to (%).',
            c_proc_name, p_week_from, p_week_to;
    END IF;

    -- how much are we classifying? INTO STRICT would throw if this returned
    -- zero or many rows; a plain aggregate always returns exactly one.
    SELECT SUM(sales_retail), COUNT(*)
      INTO v_total_val, v_item_count
    FROM rpt.mv_sales_item_week
    WHERE week_key BETWEEN p_week_from AND p_week_to;

    IF NVL(v_total_val, 0) = 0 THEN
        RAISE WARNING '[%] no sales between % and %. Nothing to classify.',
            c_proc_name, p_week_from, p_week_to;
        p_a_count := 0; p_b_count := 0; p_c_count := 0;
        RETURN;
    END IF;

    RAISE INFO '[%] classifying % item-weeks worth %.2f across weeks % to %',
        c_proc_name, v_item_count, v_total_val, p_week_from, p_week_to;

    -- idempotent: clear this window before rebuilding it (module 21)
    DELETE FROM rpt.item_abc_class
    WHERE week_from = p_week_from AND week_to = p_week_to;
    GET DIAGNOSTICS v_deleted = ROW_COUNT;

    INSERT INTO rpt.item_abc_class
        (week_from, week_to, item_id, dept_id, sales_retail,
         cum_pct, sales_rank, abc_class, built_at)
    WITH item_totals AS (
        SELECT item_id, MAX(dept_id) AS dept_id, SUM(sales_retail) AS sales_retail
        FROM rpt.mv_sales_item_week
        WHERE week_key BETWEEN p_week_from AND p_week_to
        GROUP BY item_id
    ),
    ranked AS (
        SELECT
            item_id,
            dept_id,
            sales_retail,
            -- running total of value, biggest sellers first
            SUM(sales_retail) OVER (ORDER BY sales_retail DESC, item_id
                                    ROWS UNBOUNDED PRECEDING) AS running_value,
            SUM(sales_retail) OVER ()                          AS grand_total,
            ROW_NUMBER()      OVER (ORDER BY sales_retail DESC, item_id) AS sales_rank
        FROM item_totals
    )
    SELECT
        p_week_from,
        p_week_to,
        item_id,
        dept_id,
        sales_retail,
        ROUND(running_value / grand_total, 4) AS cum_pct,
        sales_rank,
        CASE WHEN running_value / grand_total <= 0.80 THEN 'A'
             WHEN running_value / grand_total <= 0.95 THEN 'B'
             ELSE 'C' END                     AS abc_class,
        GETDATE()
    FROM ranked;
    GET DIAGNOSTICS v_inserted = ROW_COUNT;

    SELECT
        SUM(CASE WHEN abc_class = 'A' THEN 1 ELSE 0 END),
        SUM(CASE WHEN abc_class = 'B' THEN 1 ELSE 0 END),
        SUM(CASE WHEN abc_class = 'C' THEN 1 ELSE 0 END)
      INTO p_a_count, p_b_count, p_c_count
    FROM rpt.item_abc_class
    WHERE week_from = p_week_from AND week_to = p_week_to;

    INSERT INTO rpt.audit_report_build
        (proc_name, step_name, target_object, week_key, start_time, end_time,
         duration_ms, rows_affected, status)
    VALUES
        (c_proc_name, 'ABC classification', 'item_abc_class', p_week_from,
         v_step_start, GETDATE(), DATEDIFF(ms, v_step_start, GETDATE()),
         v_inserted, 'SUCCESS');

    RAISE INFO '[%] built. A=% B=% C=% (deleted % / inserted %)',
        c_proc_name, p_a_count, p_b_count, p_c_count, v_deleted, v_inserted;

EXCEPTION WHEN OTHERS THEN
    v_err_state := SQLSTATE;
    v_err_msg   := SUBSTRING(SQLERRM, 1, 990);
    INSERT INTO rpt.audit_report_build
        (proc_name, step_name, target_object, week_key, start_time, end_time,
         duration_ms, rows_affected, status, sqlstate_code, error_message)
    VALUES
        (c_proc_name, 'ABC classification', 'item_abc_class', p_week_from,
         v_step_start, GETDATE(), DATEDIFF(ms, v_step_start, GETDATE()),
         0, 'FAILED', v_err_state, v_err_msg);
    RAISE EXCEPTION '[%] failed for weeks %-% SQLSTATE [%]: %',
        c_proc_name, p_week_from, p_week_to, v_err_state, v_err_msg;
END;
$$;

-- ===========================================================================
-- PROC 3 — sp_weekly_kpi_snapshot
-- ===========================================================================
-- Walks a range of weeks with a WHILE loop and writes one KPI row per week.
-- Demonstrates %ROWTYPE, a scalar UDF, IF/ELSIF banding, and WHILE iteration.
DROP TABLE IF EXISTS rpt.kpi_weekly CASCADE;
CREATE TABLE rpt.kpi_weekly (
    week_key        INT           NOT NULL,
    sales_retail    DECIMAL(16,2) NOT NULL,
    sales_units     BIGINT        NOT NULL,
    gross_margin    DECIMAL(16,2) NOT NULL,
    margin_pct      DECIMAL(7,2)  NOT NULL,
    markdown_pct    DECIMAL(7,2)  NOT NULL,
    closing_stock   DECIMAL(16,2) NOT NULL,
    weeks_of_supply DECIMAL(7,2)  NOT NULL,
    health_band     VARCHAR(12)   NOT NULL,
    built_at        TIMESTAMP     NOT NULL
) DISTSTYLE ALL SORTKEY (week_key);

-- A scalar UDF, used inside the procedure below (module 62 feature 29)
CREATE OR REPLACE FUNCTION rpt.f_margin_pct(p_retail DECIMAL(16,2), p_cost DECIMAL(16,2))
RETURNS DECIMAL(7,2)
STABLE
AS $$
    SELECT CASE WHEN NVL(p_retail, 0) = 0 THEN 0
                ELSE ROUND((p_retail - p_cost) / p_retail * 100, 2) END;
$$ LANGUAGE sql;

CREATE OR REPLACE PROCEDURE rpt.sp_weekly_kpi_snapshot(
    IN p_week_from INT,
    IN p_week_to   INT
)
LANGUAGE plpgsql
AS $$
DECLARE
    c_proc_name  CONSTANT VARCHAR(60) := 'sp_weekly_kpi_snapshot';
    v_week       INT;
    v_kpi        rpt.kpi_weekly%ROWTYPE;      -- Feature: %ROWTYPE
    v_step_start TIMESTAMP;
    v_written    INT := 0;
BEGIN
    v_step_start := GETDATE();
    v_week       := p_week_from;

    DELETE FROM rpt.kpi_weekly WHERE week_key BETWEEN p_week_from AND p_week_to;

    -- WHILE loop over the week range (module 62 feature 8)
    WHILE v_week <= p_week_to LOOP

        SELECT
            v_week,
            NVL(SUM(s.sales_retail), 0),
            NVL(SUM(s.sales_units), 0),
            NVL(SUM(s.sales_retail - s.sales_cost), 0),
            0, 0, 0, 0, 'UNKNOWN', GETDATE()
          INTO v_kpi
        FROM rpt.mv_sales_item_week s
        WHERE s.week_key = v_week;

        -- markdown as a share of gross retail
        SELECT NVL(ROUND(SUM(markdown_amt)
                   / NULLIF(SUM(sales_retail + markdown_amt), 0) * 100, 2), 0)
          INTO v_kpi.markdown_pct
        FROM rpt.mv_sales_item_week WHERE week_key = v_week;

        SELECT NVL(SUM(soh_retail), 0)
          INTO v_kpi.closing_stock
        FROM rpt.mv_inv_dept_week WHERE week_key = v_week;

        v_kpi.margin_pct := rpt.f_margin_pct(v_kpi.sales_retail,
                                             v_kpi.sales_retail - v_kpi.gross_margin);

        v_kpi.weeks_of_supply := CASE WHEN v_kpi.sales_retail = 0 THEN 0
                                      ELSE ROUND(v_kpi.closing_stock / v_kpi.sales_retail, 2) END;

        -- IF / ELSIF banding (module 62 feature 5)
        IF v_kpi.sales_retail = 0 THEN
            v_kpi.health_band := 'NO TRADE';
        ELSIF v_kpi.margin_pct >= 45 AND v_kpi.weeks_of_supply BETWEEN 4 AND 12 THEN
            v_kpi.health_band := 'HEALTHY';
        ELSIF v_kpi.weeks_of_supply > 20 THEN
            v_kpi.health_band := 'OVERSTOCK';
        ELSIF v_kpi.weeks_of_supply < 2 THEN
            v_kpi.health_band := 'UNDERSTOCK';
        ELSE
            v_kpi.health_band := 'WATCH';
        END IF;

        INSERT INTO rpt.kpi_weekly VALUES (
            v_kpi.week_key, v_kpi.sales_retail, v_kpi.sales_units, v_kpi.gross_margin,
            v_kpi.margin_pct, v_kpi.markdown_pct, v_kpi.closing_stock,
            v_kpi.weeks_of_supply, v_kpi.health_band, GETDATE());

        v_written := v_written + 1;
        v_week    := v_week + 1;
    END LOOP;

    INSERT INTO rpt.audit_report_build
        (proc_name, step_name, target_object, week_key, start_time, end_time,
         duration_ms, rows_affected, status)
    VALUES
        (c_proc_name, 'weekly KPI snapshot', 'kpi_weekly', p_week_from,
         v_step_start, GETDATE(), DATEDIFF(ms, v_step_start, GETDATE()),
         v_written, 'SUCCESS');

    RAISE INFO '[%] wrote % KPI week(s) in % ms',
        c_proc_name, v_written, DATEDIFF(ms, v_step_start, GETDATE());
END;
$$;

-- ---------------------------------------------------------------------------
-- RUN THE WHOLE PIPELINE
-- ---------------------------------------------------------------------------
-- CALL rpt.sp_refresh_report_layer('ALL', FALSE, 0);
-- CALL rpt.sp_build_abc_classification(202501, 202552, 0, 0, 0);
-- CALL rpt.sp_weekly_kpi_snapshot(202501, 202552);
--
-- SELECT * FROM rpt.audit_report_build ORDER BY start_time DESC LIMIT 20;
-- SELECT * FROM rpt.kpi_weekly ORDER BY week_key;
--   Note duration_ms is a real number, not 0. That is GETDATE() rather than
--   SYSDATE doing its job.


-- ############################################################################
-- SECTION 5: THE 10 BUSINESS QUESTIONS
-- ############################################################################
-- Every one of these reads a materialized view, never the fact table, and does
-- its OLAP over a few thousand pre-aggregated rows. That is the payoff for
-- keeping the MVs boring.

-- ===========================================================================
-- Q1. "Give me the top 10 items in each department for a given week."
-- ===========================================================================
-- Window function + CTE, because you cannot filter on a window function in WHERE.
WITH ranked AS (
    SELECT
        s.week_key, s.dept_id, d.dept_name, s.item_id, i.item_desc,
        s.sales_units, s.sales_retail,
        DENSE_RANK() OVER (PARTITION BY s.dept_id ORDER BY s.sales_retail DESC) AS rnk
    FROM rpt.mv_sales_item_week s
    JOIN rms.dim_item       i ON i.item_id = s.item_id
    JOIN rms.dim_department d ON d.dept_id = s.dept_id
    WHERE s.week_key = 202520
)
SELECT dept_name, rnk, item_id, item_desc, sales_units, sales_retail
FROM ranked
WHERE rnk <= 10
ORDER BY dept_name, rnk;
-- DENSE_RANK not ROW_NUMBER: if two items tie on value you want both, and you
-- want the buyer told that "top 10" returned 11 rows rather than one being
-- dropped at random.

-- ===========================================================================
-- Q2. "What are comp sales — week on week, and against last year?"
-- ===========================================================================
-- The bread-and-butter retail metric. LAG(1) is last week; LAG(52) is the same
-- week last year, which is exactly why the 4-5-4 calendar exists.
WITH dept_week AS (
    SELECT week_key, dept_id, SUM(sales_retail) AS sales_retail
    FROM rpt.mv_sales_dept_store_week
    GROUP BY week_key, dept_id
)
SELECT
    d.dept_name,
    w.week_key,
    w.sales_retail,
    LAG(w.sales_retail, 1)  OVER (PARTITION BY w.dept_id ORDER BY w.week_key) AS last_week,
    LAG(w.sales_retail, 52) OVER (PARTITION BY w.dept_id ORDER BY w.week_key) AS same_week_ly,
    ROUND((w.sales_retail - LAG(w.sales_retail, 1) OVER (PARTITION BY w.dept_id ORDER BY w.week_key))
          / NULLIF(LAG(w.sales_retail, 1) OVER (PARTITION BY w.dept_id ORDER BY w.week_key), 0)
          * 100, 2) AS wow_pct,
    ROUND((w.sales_retail - LAG(w.sales_retail, 52) OVER (PARTITION BY w.dept_id ORDER BY w.week_key))
          / NULLIF(LAG(w.sales_retail, 52) OVER (PARTITION BY w.dept_id ORDER BY w.week_key), 0)
          * 100, 2) AS comp_ly_pct
FROM dept_week w
JOIN rms.dim_department d ON d.dept_id = w.dept_id
WHERE w.week_key BETWEEN 202601 AND 202612
ORDER BY d.dept_name, w.week_key;
-- NULLIF guards the divide-by-zero. sales_retail is DECIMAL so there is no
-- integer-division trap here -- but if you ever store it as INTEGER, cast
-- before dividing or every percentage comes back 0.

-- ===========================================================================
-- Q3. "What is sell-through, and how many weeks of supply do we have?"
-- ===========================================================================
-- sell-through % = units sold / (units sold + closing stock)
-- weeks of supply = closing stock / average weekly demand
WITH sales_tot AS (
    SELECT item_id,
           SUM(sales_units)           AS units_13wk,
           ROUND(AVG(sales_units), 2) AS avg_weekly_units
    FROM rpt.mv_sales_item_week
    WHERE week_key BETWEEN 202540 AND 202552
    GROUP BY item_id
),
stock AS (
    SELECT item_id, SUM(soh_units) AS closing_units
    FROM rpt.mv_inv_item_store_week
    WHERE week_key = 202552
    GROUP BY item_id
)
SELECT
    i.item_id, i.item_desc, dp.dept_name,
    t.units_13wk, t.avg_weekly_units, k.closing_units,
    ROUND(t.units_13wk * 100.0 / NULLIF(t.units_13wk + k.closing_units, 0), 2) AS sell_through_pct,
    ROUND(k.closing_units / NULLIF(t.avg_weekly_units, 0), 1)                  AS weeks_of_supply,
    CASE WHEN k.closing_units / NULLIF(t.avg_weekly_units, 0) > 20 THEN 'OVERSTOCK — markdown candidate'
         WHEN k.closing_units / NULLIF(t.avg_weekly_units, 0) <  2 THEN 'UNDERSTOCK — reorder now'
         ELSE 'OK' END AS action
FROM sales_tot t
JOIN stock k          ON k.item_id = t.item_id
JOIN rms.dim_item i   ON i.item_id = t.item_id
JOIN rms.dim_department dp ON dp.dept_id = i.dept_id
ORDER BY weeks_of_supply DESC
LIMIT 40;

-- ===========================================================================
-- Q4. "Smooth out the weekly noise — 4-week moving average and trend."
-- ===========================================================================
-- The FRAME clause is the whole answer. Default frame = running average from
-- the start of the year; ROWS BETWEEN 3 PRECEDING AND CURRENT ROW = rolling 4.
WITH dept_week AS (
    SELECT week_key, dept_id, SUM(sales_retail) AS sales_retail
    FROM rpt.mv_sales_dept_store_week
    GROUP BY week_key, dept_id
)
SELECT
    d.dept_name,
    w.week_key,
    w.sales_retail,
    ROUND(AVG(w.sales_retail) OVER (
        PARTITION BY w.dept_id ORDER BY w.week_key
        ROWS BETWEEN 3 PRECEDING AND CURRENT ROW), 2)          AS moving_avg_4wk,
    ROUND(AVG(w.sales_retail) OVER (
        PARTITION BY w.dept_id ORDER BY w.week_key), 2)        AS running_avg_ytd,
    CASE WHEN w.sales_retail > AVG(w.sales_retail) OVER (
             PARTITION BY w.dept_id ORDER BY w.week_key
             ROWS BETWEEN 3 PRECEDING AND CURRENT ROW)
         THEN 'ABOVE TREND' ELSE 'BELOW TREND' END             AS trend_flag
FROM dept_week w
JOIN rms.dim_department d ON d.dept_id = w.dept_id
WHERE w.week_key BETWEEN 202520 AND 202540
ORDER BY d.dept_name, w.week_key;

-- ===========================================================================
-- Q5. "Which items make 80% of our sales?" — Pareto / ABC
-- ===========================================================================
-- Answered two ways: live, and from the table PROC 2 built.
SELECT
    abc_class,
    COUNT(*)                                     AS items,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 1) AS pct_of_items,
    SUM(sales_retail)                            AS sales_retail,
    ROUND(SUM(sales_retail) * 100.0
          / SUM(SUM(sales_retail)) OVER (), 1)   AS pct_of_sales
FROM rpt.item_abc_class
WHERE week_from = 202501 AND week_to = 202552
GROUP BY abc_class
ORDER BY abc_class;
-- The classic result: class A is a small share of the SKUs and ~80% of the
-- value. Note SUM(COUNT(*)) OVER () -- an aggregate inside a window function,
-- which is how you get "percent of total" without a second query or a self-join.

-- ===========================================================================
-- Q6. "Which classes are missing their margin target, and is markdown to blame?"
-- ===========================================================================
SELECT
    dp.dept_name,
    c.class_name,
    SUM(s.sales_retail)                                                AS sales_retail,
    ROUND(SUM(s.sales_retail - s.sales_cost) * 100.0
          / NULLIF(SUM(s.sales_retail), 0), 2)                         AS actual_margin_pct,
    dp.target_margin_pct,
    ROUND(SUM(s.sales_retail - s.sales_cost) * 100.0
          / NULLIF(SUM(s.sales_retail), 0) - dp.target_margin_pct, 2)  AS margin_gap_pts,
    ROUND(SUM(s.markdown_amt) * 100.0
          / NULLIF(SUM(s.sales_retail + s.markdown_amt), 0), 2)        AS markdown_pct,
    RANK() OVER (ORDER BY SUM(s.sales_retail - s.sales_cost) * 100.0
                          / NULLIF(SUM(s.sales_retail), 0)
                          - dp.target_margin_pct)                      AS worst_gap_rank
FROM rpt.mv_sales_class_week s
JOIN rms.dim_class      c  ON c.class_id = s.class_id
JOIN rms.dim_department dp ON dp.dept_id = s.dept_id
WHERE s.week_key BETWEEN 202501 AND 202552
GROUP BY dp.dept_name, c.class_name, dp.target_margin_pct
ORDER BY margin_gap_pts
LIMIT 25;
-- A window function OVER an aggregate: RANK() is applied after the GROUP BY, so
-- it ranks the grouped rows. This is legal and extremely useful, and it trips
-- people up the first time they see it.

-- ===========================================================================
-- Q7. "Rank every store inside its district AND inside its region."
-- ===========================================================================
-- Two PARTITION BY clauses over the same rows, plus NTILE for quartiles.
WITH store_year AS (
    SELECT store_id, district_id, region_id,
           SUM(sales_retail) AS sales_retail,
           SUM(sales_units)  AS sales_units
    FROM rpt.mv_sales_dept_store_week
    WHERE week_key BETWEEN 202501 AND 202552
    GROUP BY store_id, district_id, region_id
)
SELECT
    st.store_name, st.store_format, dis.district_name, r.region_name,
    y.sales_retail,
    ROUND(y.sales_retail / NULLIF(st.selling_sqft, 0), 2)                       AS sales_per_sqft,
    DENSE_RANK() OVER (PARTITION BY y.district_id ORDER BY y.sales_retail DESC) AS rank_in_district,
    DENSE_RANK() OVER (PARTITION BY y.region_id   ORDER BY y.sales_retail DESC) AS rank_in_region,
    DENSE_RANK() OVER (ORDER BY y.sales_retail DESC)                            AS rank_in_chain,
    NTILE(4)     OVER (ORDER BY y.sales_retail DESC)                            AS chain_quartile,
    ROUND(PERCENT_RANK() OVER (ORDER BY y.sales_retail DESC), 3)                AS pct_rank
FROM store_year y
JOIN rms.dim_store    st  ON st.store_id    = y.store_id
JOIN rms.dim_district dis ON dis.district_id = y.district_id
JOIN rms.dim_region   r   ON r.region_id     = y.region_id
ORDER BY rank_in_chain
LIMIT 30;
-- Sales per square foot is the metric that stops a big flagship automatically
-- outranking a productive small store.

-- ===========================================================================
-- Q8. "Where did we go out of stock, and what did it cost us?"
-- ===========================================================================
-- Zero stock on hand in a week where the item normally sells = lost sales.
WITH demand AS (
    SELECT item_id, ROUND(AVG(sales_units), 2) AS avg_weekly_units,
           ROUND(AVG(sales_retail), 2)          AS avg_weekly_retail
    FROM rpt.mv_sales_item_week
    WHERE week_key BETWEEN 202501 AND 202552
    GROUP BY item_id
),
oos AS (
    SELECT week_key, item_id, store_id
    FROM rpt.mv_inv_item_store_week
    WHERE week_key BETWEEN 202501 AND 202552
      AND soh_units = 0
)
SELECT
    i.item_id, i.item_desc, dp.dept_name,
    COUNT(*)                                              AS oos_store_weeks,
    d.avg_weekly_units,
    ROUND(COUNT(*) * d.avg_weekly_retail, 2)              AS est_lost_sales,
    DENSE_RANK() OVER (ORDER BY COUNT(*) * d.avg_weekly_retail DESC) AS lost_sales_rank
FROM oos
JOIN demand d          ON d.item_id = oos.item_id
JOIN rms.dim_item i    ON i.item_id = oos.item_id
JOIN rms.dim_department dp ON dp.dept_id = i.dept_id
WHERE d.avg_weekly_units > 0
GROUP BY i.item_id, i.item_desc, dp.dept_name, d.avg_weekly_units, d.avg_weekly_retail
ORDER BY est_lost_sales DESC
LIMIT 25;
-- This is an ESTIMATE and should be labelled as one in any pack you hand a
-- buyer. It assumes demand would have continued at the average rate, which
-- ignores substitution -- the customer who could not buy item A often buys B.

-- ===========================================================================
-- Q9. "Which suppliers are failing OTIF?" — on time, in full
-- ===========================================================================
SELECT
    sp.supplier_id, sp.supplier_name, sp.country, sp.lead_time_days,
    SUM(m.po_lines)                                                   AS po_lines,
    ROUND(SUM(m.on_time_lines) * 100.0 / NULLIF(SUM(m.po_lines),0), 2) AS on_time_pct,
    ROUND(SUM(m.in_full_lines) * 100.0 / NULLIF(SUM(m.po_lines),0), 2) AS in_full_pct,
    ROUND(SUM(m.otif_lines)    * 100.0 / NULLIF(SUM(m.po_lines),0), 2) AS otif_pct,
    sp.otif_target_pct,
    CASE WHEN SUM(m.otif_lines) * 100.0 / NULLIF(SUM(m.po_lines),0) < sp.otif_target_pct
         THEN 'BELOW TARGET — escalate' ELSE 'meeting target' END      AS status,
    RANK() OVER (ORDER BY SUM(m.otif_lines) * 100.0 / NULLIF(SUM(m.po_lines),0)) AS worst_rank
FROM rpt.mv_receipts_supplier_week m
JOIN rms.dim_supplier sp ON sp.supplier_id = m.supplier_id
WHERE m.week_key BETWEEN 202501 AND 202552
GROUP BY sp.supplier_id, sp.supplier_name, sp.country, sp.lead_time_days, sp.otif_target_pct
ORDER BY otif_pct;
-- Suppliers 903 and 907 are seeded to underperform, so they should surface here.
-- OTIF is deliberately stricter than either component: a line only counts if it
-- was BOTH on time AND complete. Reporting the two separately as well is what
-- tells you whether it is a logistics problem or an allocation problem.

-- ===========================================================================
-- Q10. "Did the promotion actually lift sales, or did we discount base demand?"
-- ===========================================================================
-- The question every trading meeting asks and few reports answer honestly.
-- Compare promoted weeks against the item's own non-promoted baseline.
WITH baseline AS (
    SELECT item_id, ROUND(AVG(sales_units), 2) AS base_weekly_units
    FROM rpt.mv_sales_promo_item_week
    WHERE promo_id = 0
    GROUP BY item_id
),
promoted AS (
    SELECT p.promo_id, p.item_id, p.week_key, p.sales_units, p.sales_retail, p.markdown_amt
    FROM rpt.mv_sales_promo_item_week p
    WHERE p.promo_id > 0
)
SELECT
    pr.promo_name, pr.promo_type, pr.discount_pct,
    COUNT(*)                                                        AS item_weeks,
    ROUND(AVG(pm.sales_units), 2)                                   AS avg_promo_units,
    ROUND(AVG(b.base_weekly_units), 2)                              AS avg_base_units,
    ROUND((AVG(pm.sales_units) - AVG(b.base_weekly_units))
          / NULLIF(AVG(b.base_weekly_units), 0) * 100, 1)           AS uplift_pct,
    ROUND(SUM(pm.markdown_amt), 2)                                  AS markdown_given,
    ROUND(SUM(pm.sales_retail), 2)                                  AS promo_sales,
    CASE WHEN AVG(pm.sales_units) > AVG(b.base_weekly_units) * 1.20
         THEN 'GENUINE LIFT'
         ELSE 'MARGIN GIVEAWAY — review' END                        AS verdict
FROM promoted pm
JOIN baseline b       ON b.item_id  = pm.item_id
JOIN rms.dim_promotion pr ON pr.promo_id = pm.promo_id
GROUP BY pr.promo_name, pr.promo_type, pr.discount_pct
ORDER BY uplift_pct DESC;
-- The 20% threshold is a business rule, not a statistical test. State it on the
-- report. A promo that moves units 5% while giving away 40% of retail is a
-- margin giveaway wearing a growth costume.


-- ############################################################################
-- SECTION 6: WHAT THIS FILE DEMONSTRATES
-- ############################################################################
/*
THE ARCHITECTURE, IN ONE PICTURE

    rms.fct_sales / fct_inventory / fct_receipts     760,000 rows
              │  INNER JOIN + GROUP BY + SUM only
              ▼
    rpt.mv_*   10 materialized views                 all INCREMENTAL
              │  window functions applied HERE, at read time
              ▼
    Section 5  10 business questions                 a few thousand rows scanned
              │  procedures write durable outputs
              ▼
    rpt.item_abc_class / rpt.kpi_weekly / rpt.audit_report_build

WHY THE MVs ARE BORING ON PURPOSE
  Put a window function, COUNT(DISTINCT), an OUTER JOIN or a subquery in any MV
  above and it silently drops from incremental to full recompute. Nothing errors.
  The nightly refresh just starts rebuilding 760,000 rows instead of touching the
  delta, and six months later nobody remembers which change did it.
  Run the STV_MV_INFO check at the end of Section 3 after any edit.

PL/pgSQL FEATURES USED IN ANGER (module 62 taught these in isolation)
  %TYPE and %ROWTYPE anchoring        RECORD and cursor FOR loops
  IN / OUT / INOUT parameters         WHILE and numeric loops
  Dynamic SQL with QUOTE_IDENT        SELECT INTO
  GET DIAGNOSTICS ROW_COUNT           nested BEGIN...EXCEPTION blocks
  SQLSTATE / SQLERRM capture          RAISE INFO / WARNING / EXCEPTION
  Scalar SQL UDF                      persistent audit logging

THE THREE THINGS MOST LIKELY TO BE COPIED WRONG
  1. GETDATE(), not SYSDATE, for durations. A procedure body is one transaction;
     SYSDATE is frozen for all of it and every duration logs as 0 (module 20).
  2. Window functions cannot go in WHERE. Wrap in a CTE (Q1).
  3. NULLIF on every denominator. And if a measure is ever stored as INTEGER,
     cast before dividing or your percentages come back 0.

WHERE TO GO NEXT
  62    the 30 PL/pgSQL features on their own
  51    OLAP basics — every window function used above, one at a time
  77    materialized view refresh — why the MVs here are shaped as they are
  52.1  join algorithms   52.2  locking   28/29  distribution
  73    SCD types, if these dimensions ever need history
*/


-- ############################################################################
-- CLEANUP
-- ############################################################################
-- DROP SCHEMA IF EXISTS rpt CASCADE;
-- DROP SCHEMA IF EXISTS rms CASCADE;
