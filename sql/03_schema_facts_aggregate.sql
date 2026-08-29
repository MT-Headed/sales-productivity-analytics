-- ============================================================================
-- 03_schema_facts_aggregate.sql
-- "Silver" grain fact tables built by the ETL step (05-07). These are the
-- tables the semantic model / report layer actually queries -- pre-aggregated
-- to daily and monthly grain with rolling windows already computed, so the
-- report layer never has to scan raw event rows at query time.
--
-- Production carries a third grain (weekly) built with the identical pattern;
-- it's omitted here to keep the walkthrough focused, not because the
-- technique differs.
-- ============================================================================

DROP TABLE IF EXISTS fact_sales_productivity_daily;
DROP TABLE IF EXISTS fact_sales_productivity_monthly;

-- ----------------------------------------------------------------------------
-- fact_sales_productivity_daily
-- Grain: one row per rep x branch x project_type x customer x calendar date
-- that has ANY activity. Sparse by design (most rep/customer/day combinations
-- have no quotes or bookings at all) -- this is why a dense date scaffold is
-- needed one level up, at the monthly grain, rather than here.
-- ----------------------------------------------------------------------------
CREATE TABLE fact_sales_productivity_daily (
    rep_id                     INTEGER,
    home_branch_id             INTEGER,
    operational_branch_id      INTEGER,
    project_type_id            INTEGER,
    customer_id                INTEGER,
    activity_date              DATE,

    issued_quote_count          INTEGER,
    issued_quote_dollars        DECIMAL(14, 2),
    issued_quote_direct_margin  DECIMAL(14, 2),
    accepted_quote_count        INTEGER,
    booked_sales_count          INTEGER,
    booked_sales_dollars        DECIMAL(14, 2),
    booked_sales_direct_margin  DECIMAL(14, 2)
);

-- ----------------------------------------------------------------------------
-- fact_sales_productivity_monthly
-- Grain: one row per rep x branch x project_type x customer x month_start_date,
-- DENSE across the full calendar (every partition gets a row for every month
-- in its active window, even months with zero activity -- see
-- 06_etl_monthly_rollup.sql). This density is what makes "prior month" and
-- "rolling 3/12 month" comparisons a plain LAG()/SUM() OVER (...) instead of a
-- self-join with fragile date math.
-- ----------------------------------------------------------------------------
CREATE TABLE fact_sales_productivity_monthly (
    rep_id                          INTEGER,
    home_branch_id                  INTEGER,
    operational_branch_id           INTEGER,
    project_type_id                 INTEGER,
    customer_id                     INTEGER,
    month_start_date                 DATE,

    issued_quote_count                INTEGER,
    issued_quote_dollars              DECIMAL(14, 2),
    issued_quote_direct_margin        DECIMAL(14, 2),
    accepted_quote_count              INTEGER,
    booked_sales_count                INTEGER,
    booked_sales_dollars              DECIMAL(14, 2),
    booked_sales_direct_margin        DECIMAL(14, 2),

    -- rolling / comparison windows, computed once here so every downstream
    -- query (and every report-layer measure) reads a plain column instead of
    -- re-deriving the window at query time
    issued_quote_count_prior_month     INTEGER,
    issued_quote_dollars_prior_month   DECIMAL(14, 2),
    accepted_quote_count_prior_month   INTEGER,
    booked_sales_dollars_prior_month   DECIMAL(14, 2),

    issued_quote_count_last3months     INTEGER,
    issued_quote_dollars_last3months   DECIMAL(14, 2),
    accepted_quote_count_last3months   INTEGER,
    booked_sales_dollars_last3months   DECIMAL(14, 2),

    booked_sales_dollars_last12months  DECIMAL(14, 2),

    -- rep lifecycle / segmentation, computed in 07_etl_tiering_and_repress.sql
    has_monthly_goal_flag              INTEGER,   -- 1 if a goal row exists this month
    termination_repress                INTEGER,   -- 1 = rep had already left before this month; exclude from active-headcount cuts
    budget_tier                        VARCHAR,   -- goal-attainment segment, see 07_
    three_month_booked_tier            VARCHAR,   -- trailing-3-month booked-$ segment
    twelve_month_booked_tier           VARCHAR    -- trailing-12-month booked-$ segment
);
