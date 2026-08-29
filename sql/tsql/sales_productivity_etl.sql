/* =============================================================================
   sales_productivity_etl.sql  (T-SQL / SQL Server & Microsoft Fabric Warehouse)

   Production-dialect counterpart to sql/01-08 (DuckDB). Same tables, same
   engineering pattern (dense date scaffold + window functions for rolling
   metrics, two-phase repress-then-tier update). Not runnable standalone in
   this repo -- see sql/tsql/README.md for what would need to change to stand
   this up against a real SQL Server / Fabric Warehouse instance.
   ============================================================================= */

CREATE SCHEMA dim;
GO
CREATE SCHEMA fact;
GO

-- -----------------------------------------------------------------------------
-- Dimensions
-- -----------------------------------------------------------------------------
CREATE TABLE dim.branch (
    branch_id    INT NOT NULL PRIMARY KEY,
    branch_name  NVARCHAR(100) NOT NULL,
    region       NVARCHAR(50)  NOT NULL
);

CREATE TABLE dim.sales_rep (
    rep_id                 INT NOT NULL PRIMARY KEY,
    rep_name               NVARCHAR(100) NOT NULL,
    job_family_grouping    NVARCHAR(50)  NOT NULL,
    home_branch_id         INT NOT NULL REFERENCES dim.branch(branch_id),
    hire_date              DATE NOT NULL,
    termination_date       DATE NULL
);

CREATE TABLE dim.customer_account (
    customer_id       INT NOT NULL PRIMARY KEY,
    customer_name     NVARCHAR(200) NOT NULL,
    customer_segment  NVARCHAR(50)  NOT NULL
);

CREATE TABLE dim.project_type (
    project_type_id   INT NOT NULL PRIMARY KEY,
    project_type      NVARCHAR(100) NOT NULL,
    building_type     NVARCHAR(50)  NOT NULL
);

-- dim.date is generated below via a recursive CTE, not loaded from a file --
-- SQL Server has no generate_series() table function (Azure SQL / recent
-- Fabric builds do via GENERATE_SERIES, but a recursive CTE is the portable,
-- version-agnostic way to build a date spine).
CREATE TABLE dim.date (
    [date]              DATE NOT NULL PRIMARY KEY,
    is_business_day     BIT NOT NULL,
    week_start_date     DATE NOT NULL,
    month_start_date    DATE NOT NULL,
    month_end_date      DATE NOT NULL
);

INSERT INTO dim.date ([date], is_business_day, week_start_date, month_start_date, month_end_date)
WITH date_spine AS (
    SELECT CAST('2025-01-01' AS DATE) AS [date]
    UNION ALL
    SELECT DATEADD(DAY, 1, [date]) FROM date_spine WHERE [date] < '2026-03-31'
)
SELECT
    d.[date],
    CASE WHEN DATEPART(WEEKDAY, d.[date]) IN (1, 7) THEN 0 ELSE 1 END,  -- adjust for @@DATEFIRST
    DATEADD(DAY, 1 - DATEPART(WEEKDAY, d.[date]), d.[date]),
    DATEFROMPARTS(YEAR(d.[date]), MONTH(d.[date]), 1),
    EOMONTH(d.[date])
FROM date_spine d
OPTION (MAXRECURSION 0);

-- -----------------------------------------------------------------------------
-- Raw ("bronze") fact tables
-- -----------------------------------------------------------------------------
CREATE TABLE fact.quote_events (
    quote_id                INT NOT NULL PRIMARY KEY,
    rep_id                  INT NOT NULL,
    home_branch_id          INT NOT NULL,
    operational_branch_id   INT NOT NULL,
    project_type_id         INT NOT NULL REFERENCES dim.project_type(project_type_id),
    customer_id             INT NOT NULL REFERENCES dim.customer_account(customer_id),
    issued_date             DATE NOT NULL,
    accepted_date           DATE NULL,
    quote_amount            DECIMAL(12, 2) NOT NULL,
    quote_direct_margin     DECIMAL(12, 2) NOT NULL
);

CREATE TABLE fact.booked_sales_lines (
    order_line_id            INT NOT NULL PRIMARY KEY,
    rep_id                   INT NOT NULL,       -- -3 = house account (see repo root README)
    home_branch_id           INT NOT NULL,
    operational_branch_id    INT NOT NULL,
    project_type_id          INT NOT NULL REFERENCES dim.project_type(project_type_id),
    customer_id              INT NOT NULL REFERENCES dim.customer_account(customer_id),
    booked_date               DATE NOT NULL,
    revenue_amt                DECIMAL(12, 2) NOT NULL,
    cost_amt                   DECIMAL(12, 2) NOT NULL,
    direct_margin_amt          DECIMAL(12, 2) NOT NULL
);

CREATE TABLE fact.rep_goals (
    rep_id             INT NOT NULL,
    month_start_date   DATE NOT NULL,
    goal_amount        DECIMAL(12, 2) NOT NULL,
    PRIMARY KEY (rep_id, month_start_date)
);

/* Sample data load in the production system happens via BULK INSERT from the
   same CSVs under sample-data/, e.g.:

       BULK INSERT dim.branch
       FROM '\\fileshare\sales-productivity-analytics\sample-data\dim_branch.csv'
       WITH (FORMAT = 'CSV', FIRSTROW = 2);

   omitted here (x7, one per table) since the path has to be reachable by the
   database engine, not the client running this script. */

-- -----------------------------------------------------------------------------
-- Aggregate ("silver") fact tables -- see sql/03_schema_facts_aggregate.sql
-- for the column-by-column rationale, identical here.
-- -----------------------------------------------------------------------------
CREATE TABLE fact.sales_productivity_daily (
    rep_id                     INT,
    home_branch_id             INT,
    operational_branch_id      INT,
    project_type_id            INT,
    customer_id                INT,
    activity_date               DATE,
    issued_quote_count          INT,
    issued_quote_dollars        DECIMAL(14, 2),
    issued_quote_direct_margin  DECIMAL(14, 2),
    accepted_quote_count        INT,
    booked_sales_count          INT,
    booked_sales_dollars        DECIMAL(14, 2),
    booked_sales_direct_margin  DECIMAL(14, 2)
);

CREATE TABLE fact.sales_productivity_monthly (
    rep_id                              INT,
    home_branch_id                      INT,
    operational_branch_id               INT,
    project_type_id                     INT,
    customer_id                         INT,
    month_start_date                     DATE,
    issued_quote_count                    INT,
    issued_quote_dollars                  DECIMAL(14, 2),
    issued_quote_direct_margin            DECIMAL(14, 2),
    accepted_quote_count                  INT,
    booked_sales_count                    INT,
    booked_sales_dollars                  DECIMAL(14, 2),
    booked_sales_direct_margin            DECIMAL(14, 2),
    issued_quote_count_prior_month         INT,
    issued_quote_dollars_prior_month       DECIMAL(14, 2),
    accepted_quote_count_prior_month       INT,
    booked_sales_dollars_prior_month       DECIMAL(14, 2),
    issued_quote_count_last3months         INT,
    issued_quote_dollars_last3months       DECIMAL(14, 2),
    accepted_quote_count_last3months       INT,
    booked_sales_dollars_last3months       DECIMAL(14, 2),
    booked_sales_dollars_last12months      DECIMAL(14, 2),
    has_monthly_goal_flag                  BIT,
    termination_repress                    BIT,
    budget_tier                            NVARCHAR(30),
    three_month_booked_tier                NVARCHAR(30),
    twelve_month_booked_tier               NVARCHAR(30)
);
GO

-- =============================================================================
-- Stored procedure: full ETL, TRUNCATE + reload, run on a schedule.
-- =============================================================================
CREATE OR ALTER PROCEDURE fact.sp_process_sales_productivity_metrics
AS
BEGIN
    SET NOCOUNT ON;

    TRUNCATE TABLE fact.sales_productivity_daily;
    TRUNCATE TABLE fact.sales_productivity_monthly;

    -- ---------------------------------------------------------------------
    -- Step 1: daily rollup (union quote-issued, quote-accepted, and booked
    -- events; group to daily grain). Identical logic to
    -- sql/05_etl_daily_rollup.sql -- see that file for inline commentary.
    -- ---------------------------------------------------------------------
    ;WITH issued AS (
        SELECT rep_id, home_branch_id, operational_branch_id, project_type_id, customer_id,
               issued_date AS activity_date,
               COUNT(*) AS issued_quote_count,
               SUM(quote_amount) AS issued_quote_dollars,
               SUM(quote_direct_margin) AS issued_quote_direct_margin,
               0 AS accepted_quote_count, 0 AS booked_sales_count,
               CAST(0 AS DECIMAL(14,2)) AS booked_sales_dollars,
               CAST(0 AS DECIMAL(14,2)) AS booked_sales_direct_margin
        FROM fact.quote_events
        GROUP BY rep_id, home_branch_id, operational_branch_id, project_type_id, customer_id, issued_date
    ),
    accepted AS (
        SELECT rep_id, home_branch_id, operational_branch_id, project_type_id, customer_id,
               accepted_date AS activity_date,
               0, CAST(0 AS DECIMAL(14,2)), CAST(0 AS DECIMAL(14,2)),
               COUNT(*), 0, CAST(0 AS DECIMAL(14,2)), CAST(0 AS DECIMAL(14,2))
        FROM fact.quote_events
        WHERE accepted_date IS NOT NULL
        GROUP BY rep_id, home_branch_id, operational_branch_id, project_type_id, customer_id, accepted_date
    ),
    booked AS (
        SELECT rep_id, home_branch_id, operational_branch_id, project_type_id, customer_id,
               booked_date AS activity_date,
               0, CAST(0 AS DECIMAL(14,2)), CAST(0 AS DECIMAL(14,2)),
               0, COUNT(*), SUM(revenue_amt), SUM(direct_margin_amt)
        FROM fact.booked_sales_lines
        GROUP BY rep_id, home_branch_id, operational_branch_id, project_type_id, customer_id, booked_date
    ),
    unioned AS (
        SELECT * FROM issued
        UNION ALL SELECT * FROM accepted
        UNION ALL SELECT * FROM booked
    )
    INSERT INTO fact.sales_productivity_daily
    SELECT
        rep_id, home_branch_id, operational_branch_id, project_type_id, customer_id, activity_date,
        SUM(issued_quote_count), SUM(issued_quote_dollars), SUM(issued_quote_direct_margin),
        SUM(accepted_quote_count), SUM(booked_sales_count), SUM(booked_sales_dollars), SUM(booked_sales_direct_margin)
    FROM unioned
    GROUP BY rep_id, home_branch_id, operational_branch_id, project_type_id, customer_id, activity_date;

    -- ---------------------------------------------------------------------
    -- Step 2: monthly rollup -- dense scaffold + window functions.
    -- Identical logic and comments to sql/06_etl_monthly_rollup.sql.
    -- ---------------------------------------------------------------------
    ;WITH monthly_activity AS (
        SELECT
            d.rep_id, d.home_branch_id, d.operational_branch_id, d.project_type_id, d.customer_id,
            dt.month_start_date,
            SUM(d.issued_quote_count) AS issued_quote_count,
            SUM(d.issued_quote_dollars) AS issued_quote_dollars,
            SUM(d.issued_quote_direct_margin) AS issued_quote_direct_margin,
            SUM(d.accepted_quote_count) AS accepted_quote_count,
            SUM(d.booked_sales_count) AS booked_sales_count,
            SUM(d.booked_sales_dollars) AS booked_sales_dollars,
            SUM(d.booked_sales_direct_margin) AS booked_sales_direct_margin
        FROM fact.sales_productivity_daily d
        JOIN dim.date dt ON dt.[date] = d.activity_date
        GROUP BY d.rep_id, d.home_branch_id, d.operational_branch_id, d.project_type_id, d.customer_id, dt.month_start_date
    ),
    partitions AS (
        SELECT DISTINCT rep_id, home_branch_id, operational_branch_id, project_type_id, customer_id
        FROM monthly_activity
    ),
    month_scaffold AS (
        SELECT DISTINCT month_start_date FROM dim.date
    ),
    dense_grid AS (
        SELECT p.*, m.month_start_date
        FROM partitions p
        CROSS JOIN month_scaffold m
    ),
    dense_with_values AS (
        SELECT
            g.rep_id, g.home_branch_id, g.operational_branch_id, g.project_type_id, g.customer_id, g.month_start_date,
            ISNULL(a.issued_quote_count, 0) AS issued_quote_count,
            ISNULL(a.issued_quote_dollars, 0) AS issued_quote_dollars,
            ISNULL(a.issued_quote_direct_margin, 0) AS issued_quote_direct_margin,
            ISNULL(a.accepted_quote_count, 0) AS accepted_quote_count,
            ISNULL(a.booked_sales_count, 0) AS booked_sales_count,
            ISNULL(a.booked_sales_dollars, 0) AS booked_sales_dollars,
            ISNULL(a.booked_sales_direct_margin, 0) AS booked_sales_direct_margin
        FROM dense_grid g
        LEFT JOIN monthly_activity a
          ON  a.rep_id = g.rep_id AND a.home_branch_id = g.home_branch_id
          AND a.operational_branch_id = g.operational_branch_id
          AND a.project_type_id = g.project_type_id AND a.customer_id = g.customer_id
          AND a.month_start_date = g.month_start_date
    ),
    goal_flag AS (
        SELECT DISTINCT rep_id, month_start_date, CAST(1 AS BIT) AS has_monthly_goal_flag
        FROM fact.rep_goals
    )
    INSERT INTO fact.sales_productivity_monthly (
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

        ISNULL(LAG(w.issued_quote_count, 1) OVER (PARTITION BY w.rep_id, w.home_branch_id, w.operational_branch_id, w.project_type_id, w.customer_id ORDER BY w.month_start_date), 0),
        ISNULL(LAG(w.issued_quote_dollars, 1) OVER (PARTITION BY w.rep_id, w.home_branch_id, w.operational_branch_id, w.project_type_id, w.customer_id ORDER BY w.month_start_date), 0),
        ISNULL(LAG(w.accepted_quote_count, 1) OVER (PARTITION BY w.rep_id, w.home_branch_id, w.operational_branch_id, w.project_type_id, w.customer_id ORDER BY w.month_start_date), 0),
        ISNULL(LAG(w.booked_sales_dollars, 1) OVER (PARTITION BY w.rep_id, w.home_branch_id, w.operational_branch_id, w.project_type_id, w.customer_id ORDER BY w.month_start_date), 0),

        ISNULL(SUM(w.issued_quote_count) OVER (PARTITION BY w.rep_id, w.home_branch_id, w.operational_branch_id, w.project_type_id, w.customer_id ORDER BY w.month_start_date ROWS BETWEEN 3 PRECEDING AND 1 PRECEDING), 0),
        ISNULL(SUM(w.issued_quote_dollars) OVER (PARTITION BY w.rep_id, w.home_branch_id, w.operational_branch_id, w.project_type_id, w.customer_id ORDER BY w.month_start_date ROWS BETWEEN 3 PRECEDING AND 1 PRECEDING), 0),
        ISNULL(SUM(w.accepted_quote_count) OVER (PARTITION BY w.rep_id, w.home_branch_id, w.operational_branch_id, w.project_type_id, w.customer_id ORDER BY w.month_start_date ROWS BETWEEN 3 PRECEDING AND 1 PRECEDING), 0),
        ISNULL(SUM(w.booked_sales_dollars) OVER (PARTITION BY w.rep_id, w.home_branch_id, w.operational_branch_id, w.project_type_id, w.customer_id ORDER BY w.month_start_date ROWS BETWEEN 3 PRECEDING AND 1 PRECEDING), 0),

        ISNULL(SUM(w.booked_sales_dollars) OVER (PARTITION BY w.rep_id, w.home_branch_id, w.operational_branch_id, w.project_type_id, w.customer_id ORDER BY w.month_start_date ROWS BETWEEN 12 PRECEDING AND 1 PRECEDING), 0),

        ISNULL(gf.has_monthly_goal_flag, 0),
        CAST(0 AS BIT), NULL, NULL, NULL
    FROM dense_with_values w
    LEFT JOIN goal_flag gf ON gf.rep_id = w.rep_id AND gf.month_start_date = w.month_start_date;

    -- ---------------------------------------------------------------------
    -- Step 3, phase 1: termination repress. Identical to
    -- sql/07_etl_tiering_and_repress.sql.
    -- ---------------------------------------------------------------------
    UPDATE tgt
    SET termination_repress = CASE
            WHEN r.termination_date IS NOT NULL
             AND DATEFROMPARTS(YEAR(r.termination_date), MONTH(r.termination_date), 1) < tgt.month_start_date
            THEN 1 ELSE 0
        END
    FROM fact.sales_productivity_monthly AS tgt
    JOIN dim.sales_rep r ON r.rep_id = tgt.rep_id;

    -- ---------------------------------------------------------------------
    -- Step 3, phase 2: tiering, computed at rep x month grain and applied to
    -- every fine-grain row for that rep/month. Runs only over non-repressed
    -- rows. Identical to sql/07_etl_tiering_and_repress.sql.
    -- ---------------------------------------------------------------------
    ;WITH rep_month AS (
        SELECT
            f.rep_id, f.month_start_date,
            MAX(CAST(f.has_monthly_goal_flag AS INT)) AS has_monthly_goal_flag,
            SUM(f.booked_sales_dollars) AS booked_sales_dollars,
            MAX(f.booked_sales_dollars_last3months) AS booked_sales_dollars_last3months,
            MAX(f.booked_sales_dollars_last12months) AS booked_sales_dollars_last12months
        FROM fact.sales_productivity_monthly f
        WHERE f.termination_repress = 0
        GROUP BY f.rep_id, f.month_start_date
    ),
    rep_month_with_goal AS (
        SELECT
            rm.*, g.goal_amount, r.hire_date,
            DATEDIFF(DAY, r.hire_date, rm.month_start_date) AS days_since_hire
        FROM rep_month rm
        JOIN dim.sales_rep r ON r.rep_id = rm.rep_id
        LEFT JOIN fact.rep_goals g ON g.rep_id = rm.rep_id AND g.month_start_date = rm.month_start_date
    ),
    tiered AS (
        SELECT
            rep_id, month_start_date,
            CASE
                WHEN month_start_date < DATEFROMPARTS(YEAR(hire_date), MONTH(hire_date), 1) THEN 'NA'
                WHEN days_since_hire < 180 THEN '1-New Hire'
                WHEN has_monthly_goal_flag = 0 OR goal_amount IS NULL THEN '6-No Monthly Goal'
                WHEN booked_sales_dollars / NULLIF(goal_amount, 0) >= 1.00 THEN '5-Exceeding Goal'
                WHEN booked_sales_dollars / NULLIF(goal_amount, 0) >= 0.75 THEN '4-Low Focus'
                WHEN booked_sales_dollars / NULLIF(goal_amount, 0) >= 0.50 THEN '3-Medium Focus'
                ELSE '2-High Focus'
            END AS budget_tier,
            CASE
                WHEN month_start_date < DATEFROMPARTS(YEAR(hire_date), MONTH(hire_date), 1) THEN 'NA'
                WHEN days_since_hire < 180 THEN '1-New Hire'
                WHEN booked_sales_dollars_last3months / 3.0 >= 30000 THEN '4-Low Focus'
                WHEN booked_sales_dollars_last3months / 3.0 >= 15000 THEN '3-Medium Focus'
                ELSE '2-High Focus'
            END AS three_month_booked_tier,
            CASE
                WHEN month_start_date < DATEFROMPARTS(YEAR(hire_date), MONTH(hire_date), 1) THEN 'NA'
                WHEN days_since_hire < 180 THEN '1-New Hire'
                WHEN booked_sales_dollars_last12months / 12.0 >= 30000 THEN '4-Low Focus'
                WHEN booked_sales_dollars_last12months / 12.0 >= 15000 THEN '3-Medium Focus'
                ELSE '2-High Focus'
            END AS twelve_month_booked_tier
        FROM rep_month_with_goal
    )
    UPDATE tgt
    SET
        budget_tier = t.budget_tier,
        three_month_booked_tier = t.three_month_booked_tier,
        twelve_month_booked_tier = t.twelve_month_booked_tier
    FROM fact.sales_productivity_monthly AS tgt
    JOIN tiered t ON t.rep_id = tgt.rep_id AND t.month_start_date = tgt.month_start_date
    WHERE tgt.termination_repress = 0;

END
GO
