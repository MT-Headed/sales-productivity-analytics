# DAX measures library (illustrative)

The `sql/` walkthrough in this repo builds the pre-aggregated fact tables a
Power BI semantic model would sit on top of. This file shows the *report-layer*
half of the pattern: the DAX measures that read those pre-aggregated columns
and turn them into the comparisons a scorecard actually shows (this period vs.
prior period, a rolling average, a value that swaps definition depending on
which page it's shown on).

These measures are written fresh against the generic schema used elsewhere in
this repo (`Dim_Date`, `Dim_SalesRep`, `Fact_SalesProductivity_Monthly`) --
they are illustrative of the pattern, not a copy of any production model.

## 1. Time-intelligence via `TREATAS`, not `DATEADD`

The standard DAX time-intelligence functions (`DATEADD`, `PARALLELPERIOD`,
`SAMEPERIODLASTYEAR`) assume a *contiguous marked date table* and silently
misbehave against a table that's dense only where the report needs it (which
is exactly what `fact_sales_productivity_monthly` is, in the SQL walkthrough).
Reading the already-computed `..._prior_month` / `..._last3months` columns
directly, keyed by `TREATAS`, sidesteps that assumption entirely:

```dax
BookedSalesDollars =
VAR SelectedMonth = SELECTEDVALUE ( Dim_Date[Month Start Date] )
RETURN
IF (
    NOT ISBLANK ( SelectedMonth ),
    CALCULATE (
        SUM ( Fact_SalesProductivity_Monthly[booked_sales_dollars] ),
        KEEPFILTERS (
            TREATAS ( { SelectedMonth }, Fact_SalesProductivity_Monthly[month_start_date] )
        )
    )
)

BookedSalesDollars_PriorMonth =
VAR SelectedMonth = SELECTEDVALUE ( Dim_Date[Month Start Date] )
RETURN
IF (
    NOT ISBLANK ( SelectedMonth ),
    CALCULATE (
        SUM ( Fact_SalesProductivity_Monthly[booked_sales_dollars_prior_month] ),
        KEEPFILTERS (
            TREATAS ( { SelectedMonth }, Fact_SalesProductivity_Monthly[month_start_date] )
        )
    )
)

BookedSalesDollars_VsPriorMonth_Pct =
DIVIDE (
    [BookedSalesDollars] - [BookedSalesDollars_PriorMonth],
    [BookedSalesDollars_PriorMonth]
)
```

Why bother: `[booked_sales_dollars_prior_month]` is already a column on the
fact row (computed once, in SQL, by the `LAG()` in `06_etl_monthly_rollup.sql`)
-- the DAX measure's only job is to sum it under the right filter context. No
per-visual date-shifting logic, no risk of a rep with a short tenure producing
a wrong "prior month" because their earliest row doesn't exist yet.

## 2. Rolling average, read straight off the fact table

```dax
BookedSalesDollars_Last3Months_Avg =
DIVIDE ( [BookedSalesDollars_Last3Months], 3 )

BookedSalesDollars_Last3Months =
VAR SelectedMonth = SELECTEDVALUE ( Dim_Date[Month Start Date] )
RETURN
IF (
    NOT ISBLANK ( SelectedMonth ),
    CALCULATE (
        SUM ( Fact_SalesProductivity_Monthly[booked_sales_dollars_last3months] ),
        KEEPFILTERS (
            TREATAS ( { SelectedMonth }, Fact_SalesProductivity_Monthly[month_start_date] )
        )
    )
)
```

## 3. Closed rate (a ratio measure, not a summed column)

```dax
ClosedRate =
VAR Issued   = SUM ( Fact_SalesProductivity_Monthly[issued_quote_count] )
VAR Accepted = SUM ( Fact_SalesProductivity_Monthly[accepted_quote_count] )
RETURN
DIVIDE ( Accepted, Issued, 0 )
```

## 4. Direct margin %

```dax
DirectMarginPct =
DIVIDE (
    SUM ( Fact_SalesProductivity_Monthly[booked_sales_direct_margin] ),
    SUM ( Fact_SalesProductivity_Monthly[booked_sales_dollars] ),
    0
)
```

## 5. Drill-through switch measure

The production report reuses one KPI card across four scorecard pages
(Monthly / Quarterly / Daily / Weekly) that each want a *different underlying
measure* behind the same visual, so the drill-through target and the card
definition don't have to be duplicated four times. A hidden "page of origin"
table (one column, one row per possible caller) drives a `SWITCH`:

```dax
DrillThrough_BookedDollars =
VAR OriginPage = SELECTEDVALUE ( Page_Of_Origin[navigation_page] )
RETURN
SWITCH (
    OriginPage,
    "Monthly",   [BookedSalesDollars],
    "Quarterly", [BookedSalesDollars_Last3Months_Avg],
    "Weekly",    [BookedSalesDollars_Weekly_PerDay],   -- not modeled in this repo's weekly grain (omitted, see sql/README)
    BLANK ()
)
```

Same measure name, same visual, four different meanings depending on where
the user clicked in from -- one definition to maintain instead of four.

## 6. Per-rep productivity (a ratio across two different grains)

```dax
QuotesPerRepPerDay =
VAR RepCount     = DISTINCTCOUNT ( Fact_SalesProductivity_Monthly[rep_id] )
VAR WorkingDays  = [WorkingDaysInSelectedPeriod]   -- a separate measure over Dim_Date
RETURN
DIVIDE (
    SUM ( Fact_SalesProductivity_Monthly[issued_quote_count] ),
    RepCount * WorkingDays,
    0
)
```

This is the DAX-side equivalent of Q4 in `sql/08_kpi_analysis_queries.sql` --
same numerator/denominator, expressed as a measure that recalculates under
whatever filter context (branch, project type, date range) the report page
currently has selected, instead of a fixed query.
