-- ============================================================================
-- 05_etl_daily_rollup.sql
-- Step 1 of the ETL: reshape the two raw event streams (quotes, bookings) into
-- a single daily grain fact table, one row per rep x branch x project_type x
-- customer x date. This mirrors the production pattern of UNION-ing several
-- source-shaped CTEs and then GROUP BY-ing to the target grain, rather than
-- writing three separate near-duplicate fact tables.
--
-- rep_id = -3 is the "house account" sentinel from fact_booked_sales_lines
-- (see 02_schema_facts_raw.sql) -- it is intentionally carried through this
-- grain so branch-level totals stay complete, but it is excluded later from
-- any *per-rep* productivity metric (see 08_kpi_analysis_queries.sql).
-- ============================================================================

TRUNCATE TABLE fact_sales_productivity_daily;

WITH issued AS (
    SELECT
        rep_id, home_branch_id, operational_branch_id, project_type_id, customer_id,
        issued_date                              AS activity_date,
        COUNT(*)                                  AS issued_quote_count,
        SUM(quote_amount)                         AS issued_quote_dollars,
        SUM(quote_direct_margin)                  AS issued_quote_direct_margin,
        0                                          AS accepted_quote_count,
        0                                          AS booked_sales_count,
        0::DECIMAL(14,2)                          AS booked_sales_dollars,
        0::DECIMAL(14,2)                          AS booked_sales_direct_margin
    FROM fact_quote_events
    GROUP BY rep_id, home_branch_id, operational_branch_id, project_type_id, customer_id, issued_date
),
accepted AS (
    SELECT
        rep_id, home_branch_id, operational_branch_id, project_type_id, customer_id,
        accepted_date                             AS activity_date,
        0 AS issued_quote_count,
        0::DECIMAL(14,2) AS issued_quote_dollars,
        0::DECIMAL(14,2) AS issued_quote_direct_margin,
        COUNT(*)                                  AS accepted_quote_count,
        0 AS booked_sales_count,
        0::DECIMAL(14,2) AS booked_sales_dollars,
        0::DECIMAL(14,2) AS booked_sales_direct_margin
    FROM fact_quote_events
    WHERE accepted_date IS NOT NULL
    GROUP BY rep_id, home_branch_id, operational_branch_id, project_type_id, customer_id, accepted_date
),
booked AS (
    SELECT
        rep_id, home_branch_id, operational_branch_id, project_type_id, customer_id,
        booked_date                               AS activity_date,
        0 AS issued_quote_count,
        0::DECIMAL(14,2) AS issued_quote_dollars,
        0::DECIMAL(14,2) AS issued_quote_direct_margin,
        0 AS accepted_quote_count,
        COUNT(*)                                  AS booked_sales_count,
        SUM(revenue_amt)                          AS booked_sales_dollars,
        SUM(direct_margin_amt)                    AS booked_sales_direct_margin
    FROM fact_booked_sales_lines
    GROUP BY rep_id, home_branch_id, operational_branch_id, project_type_id, customer_id, booked_date
),
unioned AS (
    SELECT * FROM issued
    UNION ALL SELECT * FROM accepted
    UNION ALL SELECT * FROM booked
)
INSERT INTO fact_sales_productivity_daily
SELECT
    rep_id, home_branch_id, operational_branch_id, project_type_id, customer_id, activity_date,
    SUM(issued_quote_count)         AS issued_quote_count,
    SUM(issued_quote_dollars)       AS issued_quote_dollars,
    SUM(issued_quote_direct_margin) AS issued_quote_direct_margin,
    SUM(accepted_quote_count)       AS accepted_quote_count,
    SUM(booked_sales_count)         AS booked_sales_count,
    SUM(booked_sales_dollars)       AS booked_sales_dollars,
    SUM(booked_sales_direct_margin) AS booked_sales_direct_margin
FROM unioned
GROUP BY rep_id, home_branch_id, operational_branch_id, project_type_id, customer_id, activity_date;
