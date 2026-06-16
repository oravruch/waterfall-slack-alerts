# Waterfall Slack Alerts (#ca-data-alerts)

Monitoring and alerting for Waterfall data quality scenarios, posting to **#ca-data-alerts**.

## Architecture

```
sql/01-05 (individual checks)
        ↓
sql/vw_waterfall_slack_alerts.sql  →  PROD_INCUBATION.FIN_OPS.VW_WATERFALL_SLACK_ALERTS
        ↓
Scheduled job / Cursor Automation  →  #ca-data-alerts
```

Existing Tableau monitoring (`PROD_INCUBATION.FIN_OPS.WATERFALL_LOGIC_MONITOR`) remains unchanged except for removing `unique_combination_of_columns`.

## Checks implemented

| # | Alert type | Trigger |
|---|------------|---------|
| 1 | `missing_usage_data` | Usage missing or zero for ≥50% of table-specific eligible customers (`account_status` in Customer / Pending Churn) |
| 2 | `end_bucket_change` | >10% change in `SUM(end_budget_usd)` — today `MRT_WTFL_DAILY` vs yesterday `MRT_WTFL_DAILY_SNAP` (both `date_key` and `date_id` on snap) |
| 3 | `core_employee_count_change` | >10% change in Core (`COR0001`) `number_of_employees` — today daily vs yesterday snap |
| 4 | `volume_anomaly` | >20% deviation from 7-day average record count (+ duplicate-key diagnostics) |
| 5 | `natural_growth_change` | >$800K absolute change in `natural_growth_budget_usd` on snap (yesterday vs 2 days ago, with `date_id`) |

## Usage table eligibility (Check 1)

| Source table | Eligible population |
|--------------|---------------------|
| `fact company usage` | Active ARR customers |
| `Billing_Group` | `grouping_ind = 'yes'`, non-UK products; date = yesterday |
| `pento_payroll_usage` | UK products (`product_code LIKE 'UK%'`) |
## Deployment

Deploy via **dbt** (recommended) using role `DBT_PROD_RL` / `MODIFY_FIN_OPS`. Direct `CREATE VIEW` from `UNIT - CORPORATE ANALYTICS` is not permitted in Snowflake.

1. Add `sql/vw_waterfall_slack_alerts.sql` as a dbt model in `FIN_OPS`.

## Schedule

Cursor Automation: **daily at 08:00 Israel time** (cron `0 5 * * *` UTC during IDT / summer; use `0 6 * * *` during IST / winter). Posts to **#ca-data-alerts** (`C0BAS8S24QM`).

If Snowflake MCP is disconnected at run time, the automation posts a disconnect alert instead of anomaly results.

## Root cause in alerts

Alerts include driver detail in the `detail` JSON:

- **End bucket / EE / natural growth:** top 5 companies by measure delta (`detail.top_drivers`)
- **Volume:** duplicate key groups and sample keys (`detail.top_duplicate_keys`, `detail.likely_cause`)
- **Usage:** sample companies missing usage (`detail.sample_missing_companies`)

## Assumptions to validate

- `MRT_USAGE.active_employees` is the usage measure (missing or zero = no usage).
- `MRT_WTFL_DAILY.account_status` values are `'Customer'` and `'Pending Churn'`.
- End bucket and EE checks compare **today `MRT_WTFL_DAILY` vs yesterday `MRT_WTFL_DAILY_SNAP`**; both `date_key` and `date_id` must match on snap to avoid duplicate inflation.
- `ee_eligibility` is not in `MRT_USAGE` today — only the three live source tables are monitored.

## Slack message format

Each alert should include fields from `detail` JSON, for example:

```
:warning: Waterfall Alert — missing_usage_data / fact_company_usage
Date: 2026-06-16
Eligible companies: 1,240 | With usage: 412 (33.2%)
Threshold: 50% coverage
```
