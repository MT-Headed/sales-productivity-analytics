-- ============================================================================
-- 04_load_sample_data.sql
-- Loads the fabricated CSVs under sample-data/ into the dimension and raw
-- fact tables. All figures are synthetic (see sample-data/README.md); paths
-- are relative to the repo root, matching how run_demo.py invokes duckdb.
-- ============================================================================

INSERT INTO dim_branch
SELECT * FROM read_csv_auto('sample-data/dim_branch.csv', header=true);

INSERT INTO dim_sales_rep
SELECT * FROM read_csv_auto('sample-data/dim_sales_rep.csv', header=true);

INSERT INTO dim_customer_account
SELECT * FROM read_csv_auto('sample-data/dim_customer_account.csv', header=true);

INSERT INTO dim_project_type
SELECT * FROM read_csv_auto('sample-data/dim_project_type.csv', header=true);

INSERT INTO fact_quote_events
SELECT * FROM read_csv_auto('sample-data/fact_quote_events.csv', header=true);

INSERT INTO fact_booked_sales_lines
SELECT * FROM read_csv_auto('sample-data/fact_booked_sales_lines.csv', header=true);

INSERT INTO fact_rep_goals
SELECT * FROM read_csv_auto('sample-data/fact_rep_goals.csv', header=true);
