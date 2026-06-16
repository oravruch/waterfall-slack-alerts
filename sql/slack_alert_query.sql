-- Query for the Slack alerting job / Cursor Automation
-- Prefer the deployed view; fall back to sql/run_all_checks.sql if missing.

SELECT alert_type, issue_type, source_table, alert_date, detail
FROM PROD_INCUBATION.FIN_OPS.VW_WATERFALL_SLACK_ALERTS
ORDER BY alert_type, issue_type;

-- Fallback (run entire contents of sql/run_all_checks.sql):
-- SELECT alert_type, issue_type, source_table, alert_date, detail
-- FROM (<paste run_all_checks.sql body>) alerts
-- ORDER BY alert_type, issue_type;
