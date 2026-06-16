# Remove unique_combination_of_columns

## dbt repo changes

1. Search the dbt project for `unique_combination_of_columns`:
   ```bash
   rg -n "unique_combination_of_columns" models/ tests/ analyses/
   ```

2. Remove the test definition from the relevant `schema.yml` / `models.yml`, for example:
   ```yaml
   # DELETE this block
   - dbt_utils.unique_combination_of_columns:
       combination_of_columns:
         - ...
   ```

3. If a custom singular test or macro wraps this check, remove that SQL file too.

## WATERFALL_LOGIC_MONITOR view

If `WATERFALL_LOGIC_MONITOR` unions dbt test failures by `issue_type`, ensure the branch that surfaces `unique_combination_of_columns` is removed:

```sql
-- Remove any UNION ALL arm like:
SELECT
    'unique_combination_of_columns' AS issue_type,
    ...
FROM ...
```

Or filter it out at the Slack alert layer (already excluded from `VW_WATERFALL_SLACK_ALERTS`).

## dbt Cloud / Slack

- Remove any alert routing or notification rule scoped to `unique_combination_of_columns`.
- Re-run the Waterfall monitor dbt job after merge.

## Verification

```sql
SELECT issue_type, COUNT(*)
FROM PROD_INCUBATION.FIN_OPS.WATERFALL_LOGIC_MONITOR
WHERE LOWER(issue_type) LIKE '%unique_combination%'
GROUP BY 1;
-- Expected: 0 rows after deployment
```
