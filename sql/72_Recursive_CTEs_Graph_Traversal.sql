/*
======================================================================================
MODULE 72: RECURSIVE CTEs & HIERARCHICAL / GRAPH TRAVERSAL IN REDSHIFT
======================================================================================
MAPPED BEST PRACTICES (from PROCEDURE_OPTIMIZATION_BEST_PRACTICES_MASTER_FILE.md):
- Practice 25: "Replace correlated subqueries with joins or window functions."
  Recursive CTEs replace self-referencing loops.
- Practice 27: "Set-based, not row-by-row" — recursive CTEs are set-based graph
  traversal, replacing cursor-based tree walking.
- Practice 26: "Break complex queries into staged temp tables."

TARGET AUDIENCE: SQL Engineers, Application Developers, Reporting Engineers
BUSINESS SCENARIO:
An enterprise HR system stores an org chart with 50,000 employees. Each employee
has a manager_id pointing to their manager. The VP of Engineering needs:
  1. Full reporting chain for any employee (who reports to whom, all levels)
  2. All subordinates under a given manager (entire sub-tree)
  3. Bill-of-Materials explosion for manufacturing (part → sub-parts → sub-sub-parts)

Without recursive CTEs: developers write cursor loops that walk the tree level by level.
With recursive CTEs: one SQL statement traverses the entire hierarchy in parallel.

ARCHITECTURE:
┌──────────────────────────────────────────────────────────────────────────────┐
│                    RECURSIVE CTE EXECUTION MODEL                             │
├──────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  WITH RECURSIVE cte AS (                                                    │
│      SELECT ...              ← ANCHOR MEMBER (base case)                    │
│      UNION ALL                 (runs once, returns seed rows)               │
│      SELECT ...              ← RECURSIVE MEMBER                             │
│      FROM cte JOIN table       (runs repeatedly until empty set)            │
│  )                                                                           │
│  SELECT * FROM cte;                                                          │
│                                                                              │
│  EXECUTION FLOW:                                                            │
│  ┌──────────────┐                                                           │
│  │ Iteration 0  │ → Anchor: CEO (level 0)                                   │
│  │ 1 row        │                                                           │
│  └──────┬───────┘                                                           │
│         ▼                                                                    │
│  ┌──────────────┐                                                           │
│  │ Iteration 1  │ → Direct reports of CEO (level 1)                         │
│  │ 5 rows       │                                                           │
│  └──────┬───────┘                                                           │
│         ▼                                                                    │
│  ┌──────────────┐                                                           │
│  │ Iteration 2  │ → Reports of those 5 (level 2)                            │
│  │ 25 rows      │                                                           │
│  └──────┬───────┘                                                           │
│         ▼                                                                    │
│  ┌──────────────┐                                                           │
│  │ Iteration N  │ → Empty set → STOP                                        │
│  │ 0 rows       │                                                           │
│  └──────────────┘                                                           │
│                                                                              │
│  SAFETY: Redshift limits recursion depth to prevent infinite loops.          │
│  Default max iterations depends on cluster size.                            │
│                                                                              │
└──────────────────────────────────────────────────────────────────────────────┘

======================================================================================
*/

-- The lab schema is not created anywhere else in this repo; these modules are the
-- only users of it. Without this line every lab.* reference below fails with
-- "schema "lab" does not exist".
CREATE SCHEMA IF NOT EXISTS lab;

-- ============================================================================
-- SECTION 1: DATA GENERATION — ORG CHART HIERARCHY
-- ============================================================================

CREATE TABLE IF NOT EXISTS lab.employees (
    employee_id     INT         PRIMARY KEY,
    employee_name   VARCHAR(100) NOT NULL,
    title           VARCHAR(100),
    department      VARCHAR(50),
    manager_id      INT,            -- Self-referencing FK (NULL = CEO)
    hire_date       DATE,
    salary          DECIMAL(12,2)
)
DISTSTYLE ALL;                      -- Small lookup table, broadcast to all slices

-- Seed a 7-level org hierarchy:
INSERT INTO lab.employees VALUES
-- Level 0: CEO
(1, 'Alice Chen',       'CEO',                    'Executive',   NULL, '2015-01-01', 500000),
-- Level 1: C-Suite
(2, 'Bob Martinez',     'CTO',                    'Engineering', 1,    '2016-03-15', 350000),
(3, 'Carol Williams',   'CFO',                    'Finance',     1,    '2016-06-01', 340000),
(4, 'David Kim',        'VP Sales',               'Sales',       1,    '2017-01-10', 300000),
-- Level 2: Directors
(5, 'Eve Johnson',      'Dir. of Engineering',    'Engineering', 2,    '2017-06-01', 220000),
(6, 'Frank Brown',      'Dir. of Data',           'Engineering', 2,    '2018-01-15', 210000),
(7, 'Grace Lee',        'Dir. of Finance',        'Finance',     3,    '2018-03-01', 200000),
(8, 'Hank Davis',       'Dir. of Sales US',       'Sales',       4,    '2018-06-01', 195000),
-- Level 3: Managers
(9,  'Iris Wang',       'Eng Manager',            'Engineering', 5,    '2019-01-15', 180000),
(10, 'Jack Miller',     'Data Eng Manager',       'Engineering', 6,    '2019-03-01', 175000),
(11, 'Kate Wilson',     'Finance Manager',        'Finance',     7,    '2019-06-01', 160000),
(12, 'Leo Garcia',      'Sales Manager West',     'Sales',       8,    '2019-09-01', 155000),
-- Level 4: Senior ICs
(13, 'Mia Anderson',    'Senior Engineer',        'Engineering', 9,    '2020-01-15', 150000),
(14, 'Noah Thomas',     'Senior Data Engineer',   'Engineering', 10,   '2020-03-01', 145000),
(15, 'Olivia Taylor',   'Senior Analyst',         'Finance',     11,   '2020-06-01', 130000),
(16, 'Paul Jackson',    'Senior Sales Rep',       'Sales',       12,   '2020-09-01', 125000),
-- Level 5: Junior ICs
(17, 'Quinn Harris',    'Software Engineer',      'Engineering', 13,   '2021-01-15', 110000),
(18, 'Rosa Clark',      'Data Engineer',          'Engineering', 14,   '2021-03-01', 105000),
(19, 'Sam Lewis',       'Financial Analyst',      'Finance',     15,   '2021-06-01', 90000),
(20, 'Tina Robinson',   'Sales Rep',              'Sales',       16,   '2021-09-01', 85000);


-- ============================================================================
-- SECTION 2: THE "BAD" WAY — CURSOR-BASED TREE TRAVERSAL
-- ============================================================================
-- ❌ ANTI-PATTERN: Walking the tree level by level with a loop
--
-- CREATE OR REPLACE PROCEDURE lab.sp_get_subordinates_bad(p_mgr_id INT)
-- LANGUAGE plpgsql AS $$
-- DECLARE
--     v_level INT := 0;
--     v_count INT := 1;
-- BEGIN
--     CREATE TEMP TABLE tmp_subordinates (emp_id INT, level INT);
--     INSERT INTO tmp_subordinates VALUES (p_mgr_id, 0);
--
--     WHILE v_count > 0 LOOP
--         v_level := v_level + 1;
--         INSERT INTO tmp_subordinates
--         SELECT e.employee_id, v_level
--         FROM lab.employees e
--         JOIN tmp_subordinates t ON e.manager_id = t.emp_id AND t.level = v_level - 1;
--         GET DIAGNOSTICS v_count = ROW_COUNT;
--     END LOOP;
-- END; $$;
--
-- PROBLEMS:
--   1. Multiple round-trips between Leader Node and Compute Nodes per level
--   2. Temp table re-scanned on every iteration
--   3. Cannot be used in a regular SELECT — requires a procedure call


-- ============================================================================
-- SECTION 3: THE "GOOD" WAY — RECURSIVE CTE
-- ============================================================================
-- IMPLEMENTS: Best Practice #25, #27

-- Find the full reporting chain ABOVE a given employee (walk UP the tree):
WITH RECURSIVE reporting_chain AS (
    -- Anchor: Start with the target employee
    SELECT
        employee_id,
        employee_name,
        title,
        manager_id,
        0 AS level,
        employee_name::VARCHAR(2000) AS chain
    FROM lab.employees
    WHERE employee_id = 18       -- Rosa Clark (Data Engineer)

    UNION ALL

    -- Recursive: Walk up to the manager
    SELECT
        mgr.employee_id,
        mgr.employee_name,
        mgr.title,
        mgr.manager_id,
        rc.level + 1,
        -- Cast the recursive member to the SAME width as the anchor. Redshift matches
        -- the two members' column types positionally, and an uncast concatenation
        -- widens to a different VARCHAR length than the anchor's VARCHAR(2000).
        (rc.chain || ' → ' || mgr.employee_name)::VARCHAR(2000)
    FROM lab.employees mgr
    JOIN reporting_chain rc ON mgr.employee_id = rc.manager_id
)
SELECT level, employee_name, title, chain
FROM reporting_chain
ORDER BY level;

-- Result:
-- 0  Rosa Clark         Data Engineer        Rosa Clark
-- 1  Noah Thomas        Senior Data Eng      Rosa Clark → Noah Thomas
-- 2  Jack Miller        Data Eng Manager     Rosa Clark → Noah Thomas → Jack Miller
-- 3  Frank Brown        Dir. of Data         Rosa Clark → ... → Frank Brown
-- 4  Bob Martinez       CTO                  Rosa Clark → ... → Bob Martinez
-- 5  Alice Chen         CEO                  Rosa Clark → ... → Alice Chen


-- ============================================================================
-- SECTION 4: FIND ALL SUBORDINATES (WALK DOWN THE TREE)
-- ============================================================================

-- All employees under the CTO (Bob Martinez, ID=2):
WITH RECURSIVE subordinates AS (
    -- Anchor: The manager
    SELECT
        employee_id,
        employee_name,
        title,
        department,
        manager_id,
        salary,
        0 AS depth
    FROM lab.employees
    WHERE employee_id = 2       -- CTO

    UNION ALL

    -- Recursive: All direct reports of the current set
    SELECT
        e.employee_id,
        e.employee_name,
        e.title,
        e.department,
        e.manager_id,
        e.salary,
        s.depth + 1
    FROM lab.employees e
    JOIN subordinates s ON e.manager_id = s.employee_id
)
SELECT
    depth,
    LPAD('', depth * 4, ' ') || employee_name AS org_tree,
    title,
    salary,
    SUM(salary) OVER () AS total_eng_payroll
FROM subordinates
ORDER BY depth, employee_name;


-- ============================================================================
-- SECTION 5: DEPARTMENT BUDGET ROLL-UP (AGGREGATE UP THE HIERARCHY)
-- ============================================================================

-- Total salary budget under each manager (including all nested subordinates):
WITH RECURSIVE team_budget AS (
    SELECT
        employee_id,
        employee_name,
        title,
        manager_id,
        salary,
        employee_id AS root_manager_id
    FROM lab.employees

    UNION ALL

    SELECT
        e.employee_id,
        e.employee_name,
        e.title,
        e.manager_id,
        e.salary,
        tb.root_manager_id
    FROM lab.employees e
    JOIN team_budget tb ON e.manager_id = tb.employee_id
    WHERE e.employee_id <> tb.root_manager_id  -- Prevent self-loops
)
SELECT
    m.employee_name AS manager,
    m.title,
    COUNT(DISTINCT tb.employee_id) - 1 AS team_size,  -- Exclude self
    SUM(tb.salary) AS total_team_salary
FROM team_budget tb
JOIN lab.employees m ON tb.root_manager_id = m.employee_id
WHERE m.manager_id IS NOT NULL OR m.employee_id = 1  -- Include CEO
GROUP BY m.employee_name, m.title
HAVING COUNT(DISTINCT tb.employee_id) > 1
ORDER BY total_team_salary DESC;


-- ============================================================================
-- SECTION 6: BILL OF MATERIALS (BOM) EXPLOSION
-- ============================================================================

-- Classic manufacturing use case: a finished product contains sub-assemblies,
-- which contain parts, which contain raw materials.

CREATE TABLE IF NOT EXISTS lab.bom (
    parent_part_id  VARCHAR(20),
    child_part_id   VARCHAR(20),
    quantity        INT,
    unit_cost       DECIMAL(10,2)
)
DISTSTYLE ALL;

INSERT INTO lab.bom VALUES
('BIKE-001',  'FRAME-A',   1, 150.00),
('BIKE-001',  'WHEEL-B',   2,  45.00),
('BIKE-001',  'SEAT-C',    1,  30.00),
('FRAME-A',   'TUBE-D',    3,  15.00),
('FRAME-A',   'WELD-E',    6,   2.50),
('WHEEL-B',   'RIM-F',     1,  20.00),
('WHEEL-B',   'SPOKE-G',  32,   0.50),
('WHEEL-B',   'TIRE-H',    1,  10.00);

-- Explode the BOM: all raw materials needed for BIKE-001
WITH RECURSIVE bom_explosion AS (
    -- Anchor: top-level product
    SELECT
        parent_part_id,
        child_part_id,
        quantity,
        unit_cost,
        1 AS level,
        quantity AS total_qty,
        ('BIKE-001' || ' → ' || child_part_id)::VARCHAR(2000) AS path
    FROM lab.bom
    WHERE parent_part_id = 'BIKE-001'

    UNION ALL

    -- Recursive: sub-components
    SELECT
        b.parent_part_id,
        b.child_part_id,
        b.quantity,
        b.unit_cost,
        be.level + 1,
        be.total_qty * b.quantity AS total_qty,
        (be.path || ' → ' || b.child_part_id)::VARCHAR(2000)
    FROM lab.bom b
    JOIN bom_explosion be ON b.parent_part_id = be.child_part_id
)
SELECT
    level,
    LPAD('', level * 2, '  ') || child_part_id AS component,
    total_qty,
    unit_cost,
    total_qty * unit_cost AS total_cost,
    path
FROM bom_explosion
ORDER BY path;


-- ============================================================================
-- SECTION 7: CYCLE DETECTION (PREVENTING INFINITE LOOPS)
-- ============================================================================

-- If your hierarchy has a cycle (A → B → C → A), the recursive CTE
-- will loop forever. Redshift has a default recursion limit, but you
-- should also guard explicitly:

WITH RECURSIVE safe_traversal AS (
    SELECT
        employee_id,
        employee_name,
        manager_id,
        0 AS depth,
        ARRAY(employee_id) AS visited_ids     -- Track visited nodes
    FROM lab.employees
    WHERE employee_id = 2

    UNION ALL

    SELECT
        e.employee_id,
        e.employee_name,
        e.manager_id,
        st.depth + 1,
        ARRAY_CONCAT(st.visited_ids, ARRAY(e.employee_id))
    FROM lab.employees e
    JOIN safe_traversal st ON e.manager_id = st.employee_id
    WHERE st.depth < 20                             -- Hard depth limit
      AND NOT ARRAY_CONTAINS(st.visited_ids, e.employee_id)  -- Cycle detection
)
SELECT depth, employee_name FROM safe_traversal ORDER BY depth;


-- ============================================================================
-- SECTION 8: RECURSIVE CTE BEST PRACTICES
-- ============================================================================
/*
┌──────────────────────────────────────────────────────────────────────────────┐
│                    RECURSIVE CTE RULES FOR REDSHIFT                          │
├──────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  DO:                                                                        │
│  ✅ Always include a depth/level counter                                    │
│  ✅ Add a WHERE depth < N safety limit                                      │
│  ✅ Use UNION ALL (not UNION) — dedup is handled by cycle detection         │
│  ✅ Keep the anchor member selective (one root, not all employees)           │
│  ✅ Use DISTSTYLE ALL for small hierarchy tables                            │
│  ✅ ANALYZE the hierarchy table before recursive queries                    │
│                                                                              │
│  DON'T:                                                                     │
│  ❌ Don't use recursive CTEs for large fact table processing                │
│  ❌ Don't nest recursive CTEs inside other recursive CTEs                   │
│  ❌ Don't use ORDER BY inside the recursive member                          │
│  ❌ Don't use aggregates (SUM, COUNT) inside the recursive member           │
│  ❌ Don't use LIMIT inside the recursive member                             │
│                                                                              │
│  PERFORMANCE TIP:                                                           │
│  If hierarchy > 100K rows and > 10 levels deep, consider pre-materializing │
│  the closure table (all ancestor-descendant pairs) as a flat table and     │
│  refreshing it on schedule. This trades storage for query speed.            │
│                                                                              │
└──────────────────────────────────────────────────────────────────────────────┘
*/
