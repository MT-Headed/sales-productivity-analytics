-- ============================================================================
-- 08_kpi_analysis_queries.sql
-- Business-facing KPI queries against the finished fact_sales_productivity_monthly
-- table. These are the SQL-native equivalents of the DAX measures documented
-- in dax/measures_library.md -- same logic, expressed against the pre-shaped
-- table instead of live inside a semantic model.
--
-- Convention used throughout: rep_id = -3 (house account, see
-- 02_schema_facts_raw.sql) and job_family_grouping <> 'Outside Sales' are
-- excluded from anything measuring *individual rep* productivity, but
-- included in *branch/company* totals.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Q1. Company-wide booked $ by month, vs prior month, with % change.
-- ----------------------------------------------------------------------------
SELECT
    month_start_date,
    SUM(booked_sales_dollars)                                          AS booked_sales_dollars,
    SUM(booked_sales_dollars_prior_month)                              AS booked_sales_dollars_prior_month,
    ROUND(
        (SUM(booked_sales_dollars) - SUM(booked_sales_dollars_prior_month))
        / NULLIF(SUM(booked_sales_dollars_prior_month), 0) * 100, 1
    )                                                                   AS pct_change_vs_prior_month
FROM fact_sales_productivity_monthly
GROUP BY month_start_date
ORDER BY month_start_date;

-- ----------------------------------------------------------------------------
-- Q2. Closed rate (accepted / issued) by month, outside-sales reps only.
-- ----------------------------------------------------------------------------
SELECT
    f.month_start_date,
    SUM(f.issued_quote_count)                                           AS issued_quote_count,
    SUM(f.accepted_quote_count)                                         AS accepted_quote_count,
    ROUND(SUM(f.accepted_quote_count)::DECIMAL / NULLIF(SUM(f.issued_quote_count), 0) * 100, 1)
                                                                         AS closed_rate_pct
FROM fact_sales_productivity_monthly f
JOIN dim_sales_rep r ON r.rep_id = f.rep_id
WHERE r.job_family_grouping = 'Outside Sales'
GROUP BY f.month_start_date
ORDER BY f.month_start_date;

-- ----------------------------------------------------------------------------
-- Q3. Booked direct margin % by month (company-wide, includes house account).
-- ----------------------------------------------------------------------------
SELECT
    month_start_date,
    SUM(booked_sales_dollars)                                           AS booked_sales_dollars,
    SUM(booked_sales_direct_margin)                                     AS booked_sales_direct_margin,
    ROUND(SUM(booked_sales_direct_margin) / NULLIF(SUM(booked_sales_dollars), 0) * 100, 1)
                                                                         AS direct_margin_pct
FROM fact_sales_productivity_monthly
GROUP BY month_start_date
ORDER BY month_start_date;

-- ----------------------------------------------------------------------------
-- Q4. Per-rep quotes issued per working day, rolling trailing 3 months,
-- outside-sales reps only, most recent month in the dataset.
-- ----------------------------------------------------------------------------
WITH working_days AS (
    SELECT month_start_date, SUM(is_business_day) AS working_days_in_month
    FROM dim_date
    GROUP BY month_start_date
),
trailing_3mo_working_days AS (
    SELECT
        w1.month_start_date,
        SUM(w2.working_days_in_month) AS working_days_last3months
    FROM working_days w1
    JOIN working_days w2
      ON w2.month_start_date BETWEEN w1.month_start_date - INTERVAL '3 months'
                                  AND w1.month_start_date - INTERVAL '1 day'
    GROUP BY w1.month_start_date
),
latest_month AS (
    SELECT MAX(month_start_date) AS month_start_date FROM fact_sales_productivity_monthly
)
SELECT
    r.rep_id,
    r.rep_name,
    b.branch_name,
    SUM(f.issued_quote_count_last3months)                               AS issued_quotes_last3months,
    t.working_days_last3months,
    ROUND(SUM(f.issued_quote_count_last3months)::DECIMAL / NULLIF(t.working_days_last3months, 0), 2)
                                                                         AS quotes_per_working_day_last3mo
FROM fact_sales_productivity_monthly f
JOIN dim_sales_rep r      ON r.rep_id = f.rep_id
JOIN dim_branch b         ON b.branch_id = f.home_branch_id
JOIN latest_month lm      ON lm.month_start_date = f.month_start_date
JOIN trailing_3mo_working_days t ON t.month_start_date = f.month_start_date
WHERE r.job_family_grouping = 'Outside Sales'
  AND f.termination_repress = 0
GROUP BY r.rep_id, r.rep_name, b.branch_name, t.working_days_last3months
ORDER BY quotes_per_working_day_last3mo DESC;

-- ----------------------------------------------------------------------------
-- Q5. Budget tier distribution, most recent month -- "who needs coaching now"
-- ----------------------------------------------------------------------------
WITH latest_month AS (
    SELECT MAX(month_start_date) AS month_start_date FROM fact_sales_productivity_monthly
)
SELECT
    f.budget_tier,
    COUNT(DISTINCT f.rep_id)                                            AS rep_count
FROM fact_sales_productivity_monthly f
JOIN latest_month lm ON lm.month_start_date = f.month_start_date
JOIN dim_sales_rep r ON r.rep_id = f.rep_id
WHERE r.job_family_grouping = 'Outside Sales'
  AND f.termination_repress = 0
GROUP BY f.budget_tier
ORDER BY f.budget_tier;

-- ----------------------------------------------------------------------------
-- Q6. Tract vs. non-Tract mix of issued quote dollars by month -- segmentation
-- by build type, a common "is our mix shifting toward lower-margin volume
-- work" question.
-- ----------------------------------------------------------------------------
SELECT
    f.month_start_date,
    pt.building_type,
    SUM(f.issued_quote_dollars) AS issued_quote_dollars
FROM fact_sales_productivity_monthly f
JOIN dim_project_type pt ON pt.project_type_id = f.project_type_id
GROUP BY f.month_start_date, pt.building_type
ORDER BY f.month_start_date, pt.building_type;
