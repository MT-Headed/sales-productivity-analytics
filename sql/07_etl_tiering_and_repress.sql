-- ============================================================================
-- 07_etl_tiering_and_repress.sql
-- Step 3 of the ETL: two ordered passes over the monthly fact table.
--
--   Phase 1 (repress): flag rows for months AFTER a rep's termination date so
--   headcount- and tier-based cuts don't count someone who has already left.
--   A rep's termination month itself is NOT repressed (they were still active
--   for part of it); only months strictly after it are.
--
--   Phase 2 (tier): segment each active rep/month by (a) goal attainment for
--   that month and (b) trailing booked-$ average, so the report layer can
--   slice "who needs coaching this month" without recomputing the segment
--   logic in every visual. Tiering runs AFTER repress and explicitly excludes
--   repressed rows, matching the ordering in the production procedure.
--
-- Simplification vs. production: the real system tiers against a mid-month
-- pro-rated ("month-to-date") goal, because it also serves an in-flight
-- current month. This walkthrough only ever looks at completed historical
-- months, so it tiers on full-month attainment instead -- same idea, one
-- fewer moving part.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Phase 1: termination repress
-- ----------------------------------------------------------------------------
UPDATE fact_sales_productivity_monthly AS tgt
SET termination_repress = CASE
        WHEN r.termination_date IS NOT NULL
         AND date_trunc('month', r.termination_date) < tgt.month_start_date
        THEN 1 ELSE 0
    END
FROM dim_sales_rep r
WHERE r.rep_id = tgt.rep_id;

-- ----------------------------------------------------------------------------
-- Phase 2: tiering, computed at rep x month grain (summed across branch /
-- project_type / customer), then applied to every fine-grain row for that
-- rep/month -- a rep is one tier for the month, not one tier per project type.
-- ----------------------------------------------------------------------------
WITH rep_month AS (
    SELECT
        f.rep_id,
        f.month_start_date,
        MAX(f.has_monthly_goal_flag)             AS has_monthly_goal_flag,
        SUM(f.booked_sales_dollars)               AS booked_sales_dollars,
        MAX(f.booked_sales_dollars_last3months)   AS booked_sales_dollars_last3months,
        MAX(f.booked_sales_dollars_last12months)  AS booked_sales_dollars_last12months
    FROM fact_sales_productivity_monthly f
    WHERE f.termination_repress = 0
    GROUP BY f.rep_id, f.month_start_date
),
rep_month_with_goal AS (
    SELECT
        rm.*,
        g.goal_amount,
        r.hire_date,
        DATE_DIFF('day', r.hire_date, rm.month_start_date) AS days_since_hire
    FROM rep_month rm
    JOIN dim_sales_rep r ON r.rep_id = rm.rep_id
    LEFT JOIN fact_rep_goals g
      ON g.rep_id = rm.rep_id AND g.month_start_date = rm.month_start_date
),
tiered AS (
    SELECT
        rep_id,
        month_start_date,

        CASE
            WHEN month_start_date < date_trunc('month', hire_date)          THEN 'NA'
            WHEN days_since_hire < 180                                       THEN '1-New Hire'
            WHEN has_monthly_goal_flag = 0 OR goal_amount IS NULL            THEN '6-No Monthly Goal'
            WHEN booked_sales_dollars / NULLIF(goal_amount, 0) >= 1.00       THEN '5-Exceeding Goal'
            WHEN booked_sales_dollars / NULLIF(goal_amount, 0) >= 0.75       THEN '4-Low Focus'
            WHEN booked_sales_dollars / NULLIF(goal_amount, 0) >= 0.50       THEN '3-Medium Focus'
            ELSE '2-High Focus'
        END AS budget_tier,

        CASE
            WHEN month_start_date < date_trunc('month', hire_date)          THEN 'NA'
            WHEN days_since_hire < 180                                       THEN '1-New Hire'
            WHEN booked_sales_dollars_last3months / 3.0 >= 30000             THEN '4-Low Focus'
            WHEN booked_sales_dollars_last3months / 3.0 >= 15000             THEN '3-Medium Focus'
            ELSE '2-High Focus'
        END AS three_month_booked_tier,

        CASE
            WHEN month_start_date < date_trunc('month', hire_date)          THEN 'NA'
            WHEN days_since_hire < 180                                       THEN '1-New Hire'
            WHEN booked_sales_dollars_last12months / 12.0 >= 30000           THEN '4-Low Focus'
            WHEN booked_sales_dollars_last12months / 12.0 >= 15000           THEN '3-Medium Focus'
            ELSE '2-High Focus'
        END AS twelve_month_booked_tier
    FROM rep_month_with_goal
)
UPDATE fact_sales_productivity_monthly AS tgt
SET
    budget_tier              = t.budget_tier,
    three_month_booked_tier  = t.three_month_booked_tier,
    twelve_month_booked_tier = t.twelve_month_booked_tier
FROM tiered t
WHERE t.rep_id = tgt.rep_id
  AND t.month_start_date = tgt.month_start_date
  AND tgt.termination_repress = 0;
