-- Check 3: Significant Change in Total Employee Count (Core Product)

WITH today_daily AS (
    SELECT SUM(number_of_employees) AS total_ee
    FROM PROD_DWH.WATERFALL.MRT_WTFL_DAILY
    WHERE model_type = 'actual'
      AND revenue_type = 'carr'
      AND date_id = CURRENT_DATE()
      AND product_code = 'COR0001'
),
yesterday_snap AS (
    SELECT SUM(number_of_employees) AS total_ee
    FROM PROD_DWH.WATERFALL.MRT_WTFL_DAILY_SNAP
    WHERE model_type = 'actual'
      AND revenue_type = 'carr'
      AND date_key = CURRENT_DATE() - 1
      AND date_id = CURRENT_DATE() - 1
      AND product_code = 'COR0001'
),
comparison AS (
    SELECT
        CURRENT_DATE() AS alert_date,
        t.total_ee AS current_value,
        s.total_ee AS previous_value,
        ROUND(ABS(t.total_ee - s.total_ee) / NULLIF(s.total_ee, 0) * 100, 2) AS diff_pct
    FROM today_daily t
    CROSS JOIN yesterday_snap s
),
top_company_deltas AS (
    SELECT
        COALESCE(t.company_id, s.company_id) AS company_id,
        COALESCE(t.account_name, s.account_name) AS account_name,
        COALESCE(t.ee_val, 0) - COALESCE(s.ee_val, 0) AS delta_number_of_employees
    FROM (
        SELECT company_id, MAX(account_name) AS account_name, SUM(number_of_employees) AS ee_val
        FROM PROD_DWH.WATERFALL.MRT_WTFL_DAILY
        WHERE model_type = 'actual' AND revenue_type = 'carr'
          AND date_id = CURRENT_DATE() AND product_code = 'COR0001'
        GROUP BY 1
    ) t
    FULL OUTER JOIN (
        SELECT company_id, MAX(account_name) AS account_name, SUM(number_of_employees) AS ee_val
        FROM PROD_DWH.WATERFALL.MRT_WTFL_DAILY_SNAP
        WHERE model_type = 'actual' AND revenue_type = 'carr'
          AND date_key = CURRENT_DATE() - 1 AND date_id = CURRENT_DATE() - 1
          AND product_code = 'COR0001'
        GROUP BY 1
    ) s ON t.company_id = s.company_id
),
root_cause AS (
    SELECT ARRAY_AGG(
        OBJECT_CONSTRUCT(
            'company_id', company_id,
            'account_name', account_name,
            'delta_number_of_employees', delta_number_of_employees,
            'table', 'MRT_WTFL_DAILY vs MRT_WTFL_DAILY_SNAP',
            'field', 'number_of_employees',
            'product_code', 'COR0001'
        )
    ) WITHIN GROUP (ORDER BY ABS(delta_number_of_employees) DESC) AS top_drivers
    FROM (
        SELECT company_id, account_name, delta_number_of_employees
        FROM top_company_deltas
        ORDER BY ABS(delta_number_of_employees) DESC
        LIMIT 5
    )
)

SELECT
    'core_employee_count_change' AS alert_type,
    'core_employee_count_change' AS issue_type,
    'COR0001' AS source_table,
    c.alert_date,
    c.current_value,
    c.previous_value,
    c.diff_pct,
    CASE WHEN c.diff_pct > 10 THEN 'ALERT' ELSE 'OK' END AS status,
    OBJECT_CONSTRUCT(
        'current_employee_count', c.current_value,
        'previous_employee_count', c.previous_value,
        'diff_pct', c.diff_pct,
        'date', c.alert_date,
        'product', 'Core',
        'product_code', 'COR0001',
        'measure_field', 'number_of_employees',
        'today_table', 'PROD_DWH.WATERFALL.MRT_WTFL_DAILY',
        'previous_table', 'PROD_DWH.WATERFALL.MRT_WTFL_DAILY_SNAP',
        'top_drivers', rc.top_drivers
    ) AS detail
FROM comparison c
CROSS JOIN root_cause rc
WHERE c.diff_pct > 10;
