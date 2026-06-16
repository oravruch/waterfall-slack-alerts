-- Check 2: Significant Change in End Bucket
-- Compares MRT_WTFL_DAILY (today) vs MRT_WTFL_DAILY_SNAP (yesterday)

WITH today_daily AS (
    SELECT SUM(end_budget_usd) AS total_end
    FROM PROD_DWH.WATERFALL.MRT_WTFL_DAILY
    WHERE model_type = 'actual'
      AND revenue_type = 'carr'
      AND date_id = CURRENT_DATE()
),
yesterday_snap AS (
    SELECT SUM(end_budget_usd) AS total_end
    FROM PROD_DWH.WATERFALL.MRT_WTFL_DAILY_SNAP
    WHERE model_type = 'actual'
      AND revenue_type = 'carr'
      AND date_key = CURRENT_DATE() - 1
      AND date_id = CURRENT_DATE() - 1
),
comparison AS (
    SELECT
        CURRENT_DATE() AS alert_date,
        t.total_end AS current_value,
        s.total_end AS previous_value,
        ROUND(ABS(t.total_end - s.total_end) / NULLIF(s.total_end, 0) * 100, 2) AS diff_pct
    FROM today_daily t
    CROSS JOIN yesterday_snap s
),
top_company_deltas AS (
    SELECT
        COALESCE(t.company_id, s.company_id) AS company_id,
        COALESCE(t.account_name, s.account_name) AS account_name,
        COALESCE(t.end_val, 0) - COALESCE(s.end_val, 0) AS delta_end_budget_usd
    FROM (
        SELECT company_id, MAX(account_name) AS account_name, SUM(end_budget_usd) AS end_val
        FROM PROD_DWH.WATERFALL.MRT_WTFL_DAILY
        WHERE model_type = 'actual' AND revenue_type = 'carr' AND date_id = CURRENT_DATE()
        GROUP BY 1
    ) t
    FULL OUTER JOIN (
        SELECT company_id, MAX(account_name) AS account_name, SUM(end_budget_usd) AS end_val
        FROM PROD_DWH.WATERFALL.MRT_WTFL_DAILY_SNAP
        WHERE model_type = 'actual' AND revenue_type = 'carr'
          AND date_key = CURRENT_DATE() - 1 AND date_id = CURRENT_DATE() - 1
        GROUP BY 1
    ) s ON t.company_id = s.company_id
),
root_cause AS (
    SELECT ARRAY_AGG(
        OBJECT_CONSTRUCT(
            'company_id', company_id,
            'account_name', account_name,
            'delta_end_budget_usd', ROUND(delta_end_budget_usd, 2),
            'table', 'MRT_WTFL_DAILY vs MRT_WTFL_DAILY_SNAP',
            'field', 'end_budget_usd'
        )
    ) WITHIN GROUP (ORDER BY ABS(delta_end_budget_usd) DESC) AS top_drivers
    FROM (
        SELECT company_id, account_name, delta_end_budget_usd
        FROM top_company_deltas
        ORDER BY ABS(delta_end_budget_usd) DESC
        LIMIT 5
    )
)

SELECT
    'end_bucket_change' AS alert_type,
    'end_bucket_change' AS issue_type,
    'MRT_WTFL_DAILY / MRT_WTFL_DAILY_SNAP' AS source_table,
    c.alert_date,
    c.current_value,
    c.previous_value,
    c.diff_pct,
    CASE WHEN c.diff_pct > 10 THEN 'ALERT' ELSE 'OK' END AS status,
    OBJECT_CONSTRUCT(
        'current_value', c.current_value,
        'previous_value', c.previous_value,
        'diff_pct', c.diff_pct,
        'date', c.alert_date,
        'measure_field', 'end_budget_usd',
        'today_table', 'PROD_DWH.WATERFALL.MRT_WTFL_DAILY',
        'previous_table', 'PROD_DWH.WATERFALL.MRT_WTFL_DAILY_SNAP',
        'top_drivers', rc.top_drivers
    ) AS detail
FROM comparison c
CROSS JOIN root_cause rc
WHERE c.diff_pct > 10;
