# Waterfall Slack Alerts — Agent instructions

You monitor Waterfall data quality and post to **#ca-data-alerts** (`C0BAS8S24QM`).

## MCP: use **mcpx** (Cloud → User MCP Servers)

- Snowflake queries: `snowflake__sql_exec` via **mcpx**
- Slack posts: automation **Slack action** → `#ca-data-alerts` (`C0BAS8S24QM`), or `slack-official__slack_send_message` if available in mcpx
- Do **not** rely on the Snowflake Cursor plugin (separate, often unreachable)

## 1. Snowflake probe (required first)

```sql
SELECT CURRENT_DATE() AS today;
```

If this fails → post **only**:

> :x: *Waterfall monitor could not run — mcpx / Snowflake connection is disconnected.*
> Reconnect **mcpx** in Cursor Settings → Cloud → User MCP Servers.

Stop. Do not run checks.

## 2. Run alerts query

**Try the view first:**
```sql
SELECT alert_type, issue_type, source_table, alert_date, detail
FROM PROD_INCUBATION.FIN_OPS.VW_WATERFALL_SLACK_ALERTS
ORDER BY alert_type, issue_type;
```

**If view missing** → run the **entire** `sql/run_all_checks.sql` file, then:
```sql
SELECT alert_type, issue_type, source_table, alert_date, detail
FROM (<run_all_checks body>) q
ORDER BY alert_type, issue_type;
```

(`detail` is JSON; `metric_*` columns exist in run_all_checks output but use `detail` for Slack.)

## 3. Post to Slack

**Zero rows:**
> :white_check_mark: Waterfall monitors — all checks passed for {date}.

**Each alert row** — one message. Include **Root cause** from `detail`:
- `top_drivers` — company/account/field deltas
- `top_duplicate_keys` — volume duplicates
- `sample_missing_companies` — usage gaps

Templates: see `automation/waterfall-slack-alerts-prompt.md`.

## 4. Do not alert on `unique_combination_of_columns` (retired).

## Schedule

Daily **08:00 Israel** — cron `0 5 * * *` (summer IDT) or `0 6 * * *` (winter IST).
