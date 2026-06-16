# Deploy checklist (for dbt admin)

Hand this to whoever runs **dbt prod** with role `DBT_PROD_RL` / `MODIFY_FIN_OPS`.

## Option A — copy into bob-transform (or your FIN_OPS dbt project)

1. Copy `dbt/models/fin_ops/vw_waterfall_slack_alerts.sql` into the project’s `models/fin_ops/` folder.
2. Merge `dbt/schema.yml` into the existing FIN_OPS schema tests.
3. Run:
   ```bash
   dbt run --select vw_waterfall_slack_alerts --target prod
   ```
4. Verify:
   ```sql
   SELECT COUNT(*) FROM PROD_INCUBATION.FIN_OPS.VW_WATERFALL_SLACK_ALERTS;
   ```

## Option B — run DDL manually (same role)

Run the full contents of `sql/vw_waterfall_slack_alerts.sql` in Snowflake as `DBT_PROD_RL`.

## Until the view exists

The Cursor Automation is configured to run `sql/run_all_checks.sql` instead — **no view required** for daily alerts.
