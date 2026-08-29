# KPI glossary

Definitions for every metric produced by the walkthrough, in the order they
first appear in `sql/03_schema_facts_aggregate.sql`.

| Metric | Definition | Grain it's computed at |
|---|---|---|
| `issued_quote_count` / `issued_quote_dollars` | Count and $ total of quotes issued to a customer, by issue date. | Daily, rolled to monthly |
| `accepted_quote_count` | Count of quotes the customer accepted, by acceptance date (may be a different month than issued). | Daily, rolled to monthly |
| `issued_quote_direct_margin` | Estimated direct margin on issued quotes (revenue − direct cost), at time of issue. | Daily, rolled to monthly |
| `booked_sales_count` / `booked_sales_dollars` | Count and $ total of orders actually booked, by booked date. Tracked independently of quotes — see `docs/architecture.md`. | Daily, rolled to monthly |
| `booked_sales_direct_margin` | Realized direct margin on booked orders. | Daily, rolled to monthly |
| `closed_rate` | `accepted_quote_count / issued_quote_count` for a period. Not a stored column — computed in the KPI queries / DAX measures, since it's a ratio that shouldn't be pre-summed. | Query-time |
| `direct_margin_pct` | `booked_sales_direct_margin / booked_sales_dollars`. Ratio measure, same reasoning as closed rate. | Query-time |
| `*_prior_month`, `*_last3months`, `*_last12months` | Rolling comparison windows, pre-computed once during the monthly ETL step so no downstream query has to re-derive them. `last3months` / `last12months` exclude the current month (trailing, not inclusive). | Monthly |
| `has_monthly_goal_flag` | 1 if the rep had an assigned quota for that month, 0 otherwise. Distinguishes "missed goal" from "no goal was set" — the latter should never tier as underperformance. | Monthly |
| `termination_repress` | 1 for any month strictly after a rep's termination date. Excludes departed reps from headcount- and tier-based cuts without deleting their history (their historical months, including the termination month itself, are still 0). | Monthly |
| `budget_tier` | Segment based on the rep's booked-$ attainment against `goal_amount` for that month: `5-Exceeding Goal` (≥100%), `4-Low Focus` (≥75%), `3-Medium Focus` (≥50%), `2-High Focus` (<50%), `6-No Monthly Goal` (no quota assigned), `1-New Hire` (<180 days since hire), `NA` (month precedes hire). | Monthly |
| `three_month_booked_tier` / `twelve_month_booked_tier` | Segment based on trailing average monthly booked $ (last 3 / last 12 months) against fixed thresholds, independent of any goal. Used to spot a rep who is missing a monthly quota but structurally underproducing (or overproducing) relative to peers. | Monthly |

## A note on "New Hire" and "No Monthly Goal"

Both exist to keep the tiering from producing a misleading signal in the
absence of enough history: a rep in their first 180 days hasn't had time to
establish a trailing average, and a rep with no assigned quota that month
can't meaningfully "miss" one. Both conditions short-circuit to their own
tier rather than falling through to a numeric threshold computed against
`NULL` or a partial-history average.
