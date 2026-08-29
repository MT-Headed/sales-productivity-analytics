-- ============================================================================
-- 01_schema_dims.sql
-- Dimension tables for the sales-productivity-analytics demo star schema.
-- Portable ANSI SQL, tested against DuckDB. dim_date is generated here rather
-- than loaded from a file, so the whole demo is reproducible from this repo
-- alone with no external calendar dependency.
-- ============================================================================

DROP TABLE IF EXISTS dim_date;
DROP TABLE IF EXISTS dim_branch;
DROP TABLE IF EXISTS dim_sales_rep;
DROP TABLE IF EXISTS dim_customer_account;
DROP TABLE IF EXISTS dim_project_type;

-- ----------------------------------------------------------------------------
-- dim_date: generated business calendar, 2025-01-01 .. 2026-03-31.
-- "is_business_day" is a simple Mon-Fri flag for this demo; a production
-- calendar would also flag holidays (the real pattern is identical, just an
-- extra CASE branch here).
-- ----------------------------------------------------------------------------
CREATE TABLE dim_date AS
SELECT
    d::DATE                                                    AS date,
    CAST(strftime(d, '%w') AS INT)                             AS day_of_week_num,   -- 0=Sun .. 6=Sat
    CASE WHEN CAST(strftime(d, '%w') AS INT) BETWEEN 1 AND 5
         THEN 1 ELSE 0 END                                     AS is_business_day,
    date_trunc('week', d)::DATE                                AS week_start_date,   -- Monday
    date_trunc('month', d)::DATE                               AS month_start_date,
    (date_trunc('month', d) + INTERVAL '1 month' - INTERVAL '1 day')::DATE
                                                                AS month_end_date,
    strftime(d, '%Y-%m')                                       AS year_month
FROM generate_series(DATE '2025-01-01', DATE '2026-03-31', INTERVAL '1 day') AS t(d);

-- ----------------------------------------------------------------------------
-- dim_branch: reporting-ladder / org-hierarchy stand-in. Kept flat (one level)
-- for readability; production hierarchies are typically 3-5 levels deep and
-- roll up the same way.
-- ----------------------------------------------------------------------------
CREATE TABLE dim_branch (
    branch_id    INTEGER PRIMARY KEY,
    branch_name  VARCHAR,
    region       VARCHAR
);

-- ----------------------------------------------------------------------------
-- dim_sales_rep: one row per rep. job_family_grouping distinguishes reps whose
-- activity counts toward outside-sales productivity metrics ("Outside Sales")
-- from support/inside roles that are excluded from per-rep KPI denominators.
-- termination_date is NULL for active reps -- see the "termination repress"
-- pattern in 07_etl_tiering_and_repress.sql for why this matters.
-- ----------------------------------------------------------------------------
CREATE TABLE dim_sales_rep (
    rep_id                  INTEGER PRIMARY KEY,
    rep_name                VARCHAR,
    job_family_grouping      VARCHAR,      -- 'Outside Sales' | 'Inside Sales'
    home_branch_id           INTEGER REFERENCES dim_branch(branch_id),
    hire_date                DATE,
    termination_date         DATE          -- NULL = still active
);

-- ----------------------------------------------------------------------------
-- dim_customer_account
-- ----------------------------------------------------------------------------
CREATE TABLE dim_customer_account (
    customer_id       INTEGER PRIMARY KEY,
    customer_name     VARCHAR,
    customer_segment  VARCHAR
);

-- ----------------------------------------------------------------------------
-- dim_project_type: building_type = 'Tract/Production' identifies high-volume,
-- lower-margin tract work, used downstream to segment quote/booking mix.
-- ----------------------------------------------------------------------------
CREATE TABLE dim_project_type (
    project_type_id   INTEGER PRIMARY KEY,
    project_type      VARCHAR,
    building_type     VARCHAR
);
