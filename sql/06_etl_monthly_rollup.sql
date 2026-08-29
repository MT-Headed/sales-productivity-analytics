-- ============================================================================
-- 06_etl_monthly_rollup.sql
-- Step 2 of the ETL, and the centerpiece engineering pattern of this repo:
-- build a DENSE monthly fact table (every partition x every month in its
-- active window, zeros where there's no activity) and compute every rolling
-- comparison window with plain window functions over that dense grid.
--
-- Why dense-then-window instead of correlated subqueries per period? Once the
-- grid has no gaps, "prior month" is just LAG(x, 1) OVER (PARTITION BY ...
-- ORDER BY month_start_date), and "trailing 3 months" is SUM(x) OVER (...
-- ROWS BETWEEN 3 PRECEDING AND 1 PRECEDING) -- both O(1) conceptually, no
-- per-row date-range re-scans, and both automatically return 0/NULL-safe
-- values for partitions that don't go back far enough (no manual edge-case
-- handling needed at the start of a partition's history).
-- ============================================================================

TRUNCATE TABLE fact_sales_productivity_monthly;

-- 1) Roll the daily grain up to monthly (still sparse: only months with
--    activity have a row).
WITH monthly_activity AS (
    SELECT
        d.rep_id, d.home_branch_id, d.operational_branch_id, d.project_type_id, d.customer_id,
        dt.month_start_date,
        SUM(d.issued_quote_count)         AS issued_quote_count,
        SUM(d.issued_quote_dollars)       AS issued_quote_dollars,
        SUM(d.issued_quote_direct_margin) AS issued_quote_direct_margin,
        SUM(d.accepted_quote_count)       AS accepted_quote_count,
        SUM(d.booked_sales_count)         AS booked_sales_count,
        SUM(d.booked_sales_dollars)       AS booked_sales_dollars,
        SUM(d.booked_sales_direct_margin) AS booked_sales_direct_margin
    FROM fact_sales_productivity_daily d
    JOIN dim_date dt ON dt.date = d.activity_date
    GROUP BY d.rep_id, d.home_branch_id, d.operational_branch_id, d.project_type_id, d.customer_id, dt.month_start_date
),

-- 2) Every distinct partition key that has EVER had activity...
partitions AS (
    SELECT DISTINCT rep_id, home_branch_id, operational_branch_id, project_type_id, customer_id
    FROM monthly_activity
),

-- 3) ...crossed with every month in the demo calendar, to remove gaps.
month_scaffold AS (
    SELECT DISTINCT month_start_date FROM dim_date
),
dense_grid AS (
    SELECT p.*, m.month_start_date
    FROM partitions p
    CROSS JOIN month_scaffold m
),

-- 4) Dense grid + actual values, zero-filled where a partition/month had no
--    activity at all.
dense_with_values AS (
    SELECT
        g.rep_id, g.home_branch_id, g.operational_branch_id, g.project_type_id, g.customer_id,
        g.month_start_date,
        COALESCE(a.issued_quote_count, 0)         AS issued_quote_count,
        COALESCE(a.issued_quote_dollars, 0)       AS issued_quote_dollars,
        COALESCE(a.issued_quote_direct_margin, 0) AS issued_quote_direct_margin,
        COALESCE(a.accepted_quote_count, 0)       AS accepted_quote_count,
        COALESCE(a.booked_sales_count, 0)         AS booked_sales_count,
        COALESCE(a.booked_sales_dollars, 0)       AS booked_sales_dollars,
        COALESCE(a.booked_sales_direct_margin, 0) AS booked_sales_direct_margin
    FROM dense_grid g
    LEFT JOIN monthly_activity a
      ON  a.rep_id                  = g.rep_id
      AND a.home_branch_id          = g.home_branch_id
      AND a.operational_branch_id   = g.operational_branch_id
      AND a.project_type_id         = g.project_type_id
      AND a.customer_id             = g.customer_id
      AND a.month_start_date        = g.month_start_date
),

-- 5) Which rep/month combinations have an assigned goal (drives the "No
--    Monthly Goal" tier in the next script) -- a flag, not an amount, because
--    the tiering logic only needs presence/absence here.
goal_flag AS (
    SELECT DISTINCT rep_id, month_start_date, 1 AS has_monthly_goal_flag
    FROM fact_rep_goals
)

INSERT INTO fact_sales_productivity_monthly (
    rep_id, home_branch_id, operational_branch_id, project_type_id, customer_id, month_start_date,
    issued_quote_count, issued_quote_dollars, issued_quote_direct_margin,
    accepted_quote_count, booked_sales_count, booked_sales_dollars, booked_sales_direct_margin,
    issued_quote_count_prior_month, issued_quote_dollars_prior_month,
    accepted_quote_count_prior_month, booked_sales_dollars_prior_month,
    issued_quote_count_last3months, issued_quote_dollars_last3months,
    accepted_quote_count_last3months, booked_sales_dollars_last3months,
    booked_sales_dollars_last12months,
    has_monthly_goal_flag, termination_repress, budget_tier, three_month_booked_tier, twelve_month_booked_tier
)
SELECT
    w.rep_id, w.home_branch_id, w.operational_branch_id, w.project_type_id, w.customer_id, w.month_start_date,
    w.issued_quote_count, w.issued_quote_dollars, w.issued_quote_direct_margin,
    w.accepted_quote_count, w.booked_sales_count, w.booked_sales_dollars, w.booked_sales_direct_margin,

    -- prior month: exact 1-period lag over the dense, gap-free grid
    COALESCE(LAG(w.issued_quote_count, 1) OVER (PARTITION BY w.rep_id, w.home_branch_id, w.operational_branch_id, w.project_type_id, w.customer_id ORDER BY w.month_start_date), 0) AS issued_quote_count_prior_month,
    COALESCE(LAG(w.issued_quote_dollars, 1) OVER (PARTITION BY w.rep_id, w.home_branch_id, w.operational_branch_id, w.project_type_id, w.customer_id ORDER BY w.month_start_date), 0) AS issued_quote_dollars_prior_month,
    COALESCE(LAG(w.accepted_quote_count, 1) OVER (PARTITION BY w.rep_id, w.home_branch_id, w.operational_branch_id, w.project_type_id, w.customer_id ORDER BY w.month_start_date), 0) AS accepted_quote_count_prior_month,
    COALESCE(LAG(w.booked_sales_dollars, 1) OVER (PARTITION BY w.rep_id, w.home_branch_id, w.operational_branch_id, w.project_type_id, w.customer_id ORDER BY w.month_start_date), 0) AS booked_sales_dollars_prior_month,

    -- trailing 3 months, EXCLUDING the current month (1 PRECEDING as the near edge)
    COALESCE(SUM(w.issued_quote_count) OVER (PARTITION BY w.rep_id, w.home_branch_id, w.operational_branch_id, w.project_type_id, w.customer_id ORDER BY w.month_start_date ROWS BETWEEN 3 PRECEDING AND 1 PRECEDING), 0) AS issued_quote_count_last3months,
    COALESCE(SUM(w.issued_quote_dollars) OVER (PARTITION BY w.rep_id, w.home_branch_id, w.operational_branch_id, w.project_type_id, w.customer_id ORDER BY w.month_start_date ROWS BETWEEN 3 PRECEDING AND 1 PRECEDING), 0) AS issued_quote_dollars_last3months,
    COALESCE(SUM(w.accepted_quote_count) OVER (PARTITION BY w.rep_id, w.home_branch_id, w.operational_branch_id, w.project_type_id, w.customer_id ORDER BY w.month_start_date ROWS BETWEEN 3 PRECEDING AND 1 PRECEDING), 0) AS accepted_quote_count_last3months,
    COALESCE(SUM(w.booked_sales_dollars) OVER (PARTITION BY w.rep_id, w.home_branch_id, w.operational_branch_id, w.project_type_id, w.customer_id ORDER BY w.month_start_date ROWS BETWEEN 3 PRECEDING AND 1 PRECEDING), 0) AS booked_sales_dollars_last3months,

    -- trailing 12 months, same technique, just a wider frame
    COALESCE(SUM(w.booked_sales_dollars) OVER (PARTITION BY w.rep_id, w.home_branch_id, w.operational_branch_id, w.project_type_id, w.customer_id ORDER BY w.month_start_date ROWS BETWEEN 12 PRECEDING AND 1 PRECEDING), 0) AS booked_sales_dollars_last12months,

    COALESCE(gf.has_monthly_goal_flag, 0) AS has_monthly_goal_flag,
    0    AS termination_repress,           -- set in 07_etl_tiering_and_repress.sql
    NULL AS budget_tier,                   -- set in 07_etl_tiering_and_repress.sql
    NULL AS three_month_booked_tier,       -- set in 07_etl_tiering_and_repress.sql
    NULL AS twelve_month_booked_tier       -- set in 07_etl_tiering_and_repress.sql
FROM dense_with_values w
LEFT JOIN goal_flag gf
  ON gf.rep_id = w.rep_id AND gf.month_start_date = w.month_start_date;
