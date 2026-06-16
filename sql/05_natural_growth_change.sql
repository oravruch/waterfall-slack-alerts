-- Check 5: Significant Change in Natural Growth

WITH yesterday AS (
    SELECT SUM(natural_growth_budget_usd) AS total_natural_growth
    FROM PROD_DWH.WATERFALL.MRT_WTFL_DAILY_SNAP
    WHERE model_type = 'actual'
      AND revenue_type = 'carr'
      AND date_key = CURRENT_DATE() - 1
      AND date_id = CURRENT_DATE() - 1
),
day_before AS (
    SELECT SUM(natural_growth_budget_usd) AS total_natural_growth
    FROM PROD_DWH.WATERFALL.MRT_WTFL_DAILY_SNAP
    WHERE model_type = 'actual'
      AND revenue_type = 'carr'
      AND date_key = CURRENT_DATE() - 2
      AND date_id = CURRENT_DATE() - 2
),
comparison AS (
    SELECT
        CURRENT_DATE() - 1 AS alert_date,
        y.total_natural_growth AS prev_day_value,
        d.total_natural_growth AS two_days_ago_value,
        ROUND(ABS(y.total_natural_growth - d.total_natural_growth), 2) AS abs_difference,
        ROUND(
            ABS(y.total_natural_growth - d.total_natural_growth)
            / NULLIF(d.total_natural_growth, 0) * 100,
            2
        ) AS diff_pct
    FROM yesterday y
    CROSS JOIN day_before d
),
top_company_deltas AS (
    SELECT
        COALESCE(y.company_id, d.company_id) AS company_id,
        COALESCE(y.account_name, d.account_name) AS account_name,
        COALESCE(y.ng_val, 0) - COALESCE(d.ng_val, 0) AS delta_natural_growth_budget_usd
    FROM (
        SELECT company_id, MAX(account_name) AS account_name, SUM(natural_growth_budget_usd) AS ng_val
        FROM PROD_DWH.WATERFALL.MRT_WTFL_DAILY_SNAP
        WHERE model_type = 'actual' AND revenue_type = 'carr'
          AND date_key = CURRENT_DATE() - 1 AND date_id = CURRENT_DATE() - 1
        GROUP BY 1
    ) y
    FULL OUTER JOIN (
        SELECT company_id, MAX(account_name) AS account_name, SUM(natural_growth_budget_usd) AS ng_val
        FROM PROD_DWH.WATERFALL.MRT_WTFL_DAILY_SNAP
        WHERE model_type = 'actual' AND revenue_type = 'carr'
          AND date_key = CURRENT_DATE() - 2 AND date_id = CURRENT_DATE() - 2
        GROUP BY 1
    ) d ON y.company_id = d.company_id
),
root_cause AS (
    SELECT ARRAY_AGG(
        OBJECT_CONSTRUCT(
            'company_id', company_id,
            'account_name', account_name,
            'delta_natural_growth_budget_usd', ROUND(delta_natural_growth_budget_usd, 2),
            'table', 'MRT_WTFL_DAILY_SNAP',
            'field', 'natural_growth_budget_usd'
        )
    ) WITHIN GROUP (ORDER BY ABS(delta_natural_growth_budget_usd) DESC) AS top_drivers
    FROM (
        SELECT company_id, account_name, delta_natural_growth_budget_usd
        FROM top_company_deltas
        ORDER BY ABS(delta_natural_growth_budget_usd) DESC
        LIMIT 5
    )
)

SELECT
    'natural_growth_change' AS alert_type,
    'natural_growth_change' AS issue_type,
    'carr_current' AS source_table,
    c.alert_date,
    c.prev_day_value,
    c.two_days_ago_value,
    c.abs_difference,
    c.diff_pct,
    CASE WHEN c.abs_difference > 800000 THEN 'ALERT' ELSE 'OK' END AS status,
    OBJECT_CONSTRUCT(
        'prev_day_natural_growth', c.prev_day_value,
        'two_days_ago_natural_growth', c.two_days_ago_value,
        'abs_difference', c.abs_difference,
        'diff_pct', c.diff_pct,
        'date', c.alert_date,
        'bucket_type', 'carr_current',
        'measure_field', 'natural_growth_budget_usd',
        'table', 'PROD_DWH.WATERFALL.MRT_WTFL_DAILY_SNAP',
        'top_drivers', rc.top_drivers
    ) AS detail
FROM comparison c
CROSS JOIN root_cause rc
WHERE c.abs_difference > 800000;
