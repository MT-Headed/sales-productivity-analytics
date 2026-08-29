-- ============================================================================
-- 02_schema_facts_raw.sql
-- "Bronze" grain fact tables -- one row per source event, as they'd land from
-- a quoting system and an order-entry/ERP system. These are intentionally
-- ungroomed (mixed grain, some nullable dates) to mirror what actually shows
-- up from operational systems before the ETL step reshapes them.
-- ============================================================================

DROP TABLE IF EXISTS fact_quote_events;
DROP TABLE IF EXISTS fact_booked_sales_lines;
DROP TABLE IF EXISTS fact_rep_goals;

-- ----------------------------------------------------------------------------
-- fact_quote_events: one row per quote. accepted_date is NULL until (if) the
-- quote is accepted. This is the source-of-truth for "issued" and "accepted"
-- counts/dollars.
-- ----------------------------------------------------------------------------
CREATE TABLE fact_quote_events (
    quote_id                  INTEGER PRIMARY KEY,
    rep_id                    INTEGER,
    home_branch_id            INTEGER,
    operational_branch_id     INTEGER,
    project_type_id           INTEGER REFERENCES dim_project_type(project_type_id),
    customer_id               INTEGER REFERENCES dim_customer_account(customer_id),
    issued_date               DATE,
    accepted_date             DATE,     -- NULL = not yet (or never) accepted
    quote_amount               DECIMAL(12, 2),
    quote_direct_margin        DECIMAL(12, 2)
);

-- ----------------------------------------------------------------------------
-- fact_booked_sales_lines: one row per booked order line. Booked business is
-- tracked independently of quotes on purpose -- in the real source systems a
-- booking does not always trace back to a single quote header, so the ETL
-- layer reconciles the two streams by rep/branch/date rather than by a shared
-- key. rep_id = -3 is a "house account" sentinel: revenue not attributable to
-- an individual rep (see 05_etl_daily_rollup.sql for how it's handled).
-- ----------------------------------------------------------------------------
CREATE TABLE fact_booked_sales_lines (
    order_line_id             INTEGER PRIMARY KEY,
    rep_id                    INTEGER,
    home_branch_id            INTEGER,
    operational_branch_id     INTEGER,
    project_type_id           INTEGER REFERENCES dim_project_type(project_type_id),
    customer_id               INTEGER REFERENCES dim_customer_account(customer_id),
    booked_date               DATE,
    revenue_amt                DECIMAL(12, 2),
    cost_amt                   DECIMAL(12, 2),
    direct_margin_amt          DECIMAL(12, 2)
);

-- ----------------------------------------------------------------------------
-- fact_rep_goals: one row per rep per month with an assigned quota. Absence of
-- a row for a given rep/month (rather than a zero) is meaningful -- it drives
-- the "No Monthly Goal" tier in 07_etl_tiering_and_repress.sql.
-- ----------------------------------------------------------------------------
CREATE TABLE fact_rep_goals (
    rep_id             INTEGER,
    month_start_date   DATE,
    goal_amount         DECIMAL(12, 2),
    PRIMARY KEY (rep_id, month_start_date)
);
