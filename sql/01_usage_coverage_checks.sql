-- Check 1: Missing Usage Data for the Current Day
-- Uses MRT_USAGE.ACTIVE_EMPLOYEES (missing or zero = no usage)

WITH base_customers AS (
    SELECT DISTINCT company_id, account_name
    FROM PROD_DWH.WATERFALL.MRT_WTFL_DAILY
    WHERE model_type = 'actual'
      AND revenue_type = 'arr'
      AND date_id = CURRENT_DATE()
      AND is_active_product = TRUE
      AND account_status IN ('Customer', 'Pending Churn')
),

usage_checks AS (
    SELECT
        'fact_company_usage' AS check_name,
        'fact company usage' AS source_table,
        CURRENT_DATE() AS check_date,
        w.company_id,
        w.account_name,
        COALESCE(u.active_employees, 0) AS usage_value
    FROM base_customers w
    INNER JOIN PROD_DWH.WATERFALL.MRT_WTFL_DAILY elig
        ON w.company_id = elig.company_id
       AND elig.model_type = 'actual'
       AND elig.revenue_type = 'arr'
       AND elig.date_id = CURRENT_DATE()
       AND elig.is_active_product = TRUE
    LEFT JOIN (
        SELECT company_id, SUM(COALESCE(active_employees, 0)) AS active_employees
        FROM PROD_DWH.WATERFALL.MRT_USAGE
        WHERE source_table = 'fact company usage'
          AND date_id = CURRENT_DATE()
        GROUP BY 1
    ) u ON w.company_id = u.company_id

    UNION ALL

    SELECT
        'bllng_group',
        'Billing_Group',
        CURRENT_DATE() - 1,
        w.company_id,
        w.account_name,
        COALESCE(u.active_employees, 0)
    FROM base_customers w
    INNER JOIN PROD_DWH.WATERFALL.MRT_WTFL_DAILY elig
        ON w.company_id = elig.company_id
       AND elig.model_type = 'actual'
       AND elig.revenue_type = 'arr'
       AND elig.date_id = CURRENT_DATE()
       AND elig.is_active_product = TRUE
       AND elig.grouping_ind = 'yes'
       AND elig.product_code NOT LIKE 'UK%'
    LEFT JOIN (
        SELECT company_id, SUM(COALESCE(active_employees, 0)) AS active_employees
        FROM PROD_DWH.WATERFALL.MRT_USAGE
        WHERE source_table = 'Billing_Group'
          AND date_id = CURRENT_DATE() - 1
        GROUP BY 1
    ) u ON w.company_id = u.company_id

    UNION ALL

    SELECT
        'pento_payroll_usage',
        'pento_payroll_usage',
        CURRENT_DATE(),
        w.company_id,
        w.account_name,
        COALESCE(u.active_employees, 0)
    FROM base_customers w
    INNER JOIN PROD_DWH.WATERFALL.MRT_WTFL_DAILY elig
        ON w.company_id = elig.company_id
       AND elig.model_type = 'actual'
       AND elig.revenue_type = 'arr'
       AND elig.date_id = CURRENT_DATE()
       AND elig.is_active_product = TRUE
       AND elig.product_code LIKE 'UK%'
    LEFT JOIN (
        SELECT company_id, SUM(COALESCE(active_employees, 0)) AS active_employees
        FROM PROD_DWH.WATERFALL.MRT_USAGE
        WHERE source_table = 'pento_payroll_usage'
          AND date_id = CURRENT_DATE()
        GROUP BY 1
    ) u ON w.company_id = u.company_id
),

coverage AS (
    SELECT
        check_name,
        source_table,
        check_date,
        COUNT(DISTINCT company_id) AS total_eligible_companies,
        COUNT(DISTINCT CASE WHEN usage_value > 0 THEN company_id END) AS companies_with_usage,
        ROUND(
            COUNT(DISTINCT CASE WHEN usage_value > 0 THEN company_id END)
            / NULLIF(COUNT(DISTINCT company_id), 0) * 100,
            2
        ) AS coverage_pct
    FROM usage_checks
    GROUP BY 1, 2, 3
)

SELECT
    'missing_usage_data' AS alert_type,
    check_name AS issue_type,
    source_table,
    check_date AS alert_date,
    total_eligible_companies,
    companies_with_usage,
    coverage_pct,
    CASE
        WHEN companies_with_usage < total_eligible_companies * 0.5 THEN 'ALERT'
        ELSE 'OK'
    END AS status,
    OBJECT_CONSTRUCT(
        'total_eligible_companies', total_eligible_companies,
        'companies_with_usage', companies_with_usage,
        'coverage_pct', coverage_pct,
        'threshold_pct', 50,
        'source_table', source_table
    ) AS detail
FROM coverage
WHERE companies_with_usage < total_eligible_companies * 0.5;
