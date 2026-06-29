-- Standalone alert query (no deployed view required).
-- Cursor Automation: run this when VW_WATERFALL_SLACK_ALERTS is not deployed.
-- Returns: alert_type, issue_type, source_table, alert_date, metric_1..4, detail

WITH base_customers AS (
    SELECT DISTINCT company_id
    FROM PROD_DWH.WATERFALL.MRT_WTFL_DAILY
    WHERE model_type = 'actual'
      AND revenue_type = 'arr'
      AND date_id = CURRENT_DATE()
      AND is_active_product = TRUE
      AND account_status IN ('Customer', 'Pending Churn')
),

usage_checks AS (
    SELECT 'fact_company_usage' AS check_name, 'fact company usage' AS source_table,
           CURRENT_DATE() AS check_date, w.company_id, COALESCE(u.active_employees, 0) AS usage_value
    FROM base_customers w
    INNER JOIN PROD_DWH.WATERFALL.MRT_WTFL_DAILY elig
        ON w.company_id = elig.company_id
       AND elig.model_type = 'actual' AND elig.revenue_type = 'arr'
       AND elig.date_id = CURRENT_DATE() AND elig.is_active_product = TRUE
    LEFT JOIN (
        SELECT company_id, SUM(COALESCE(active_employees, 0)) AS active_employees
        FROM PROD_DWH.WATERFALL.MRT_USAGE
        WHERE source_table = 'fact company usage' AND date_id = CURRENT_DATE()
        GROUP BY 1
    ) u ON w.company_id = u.company_id

    UNION ALL

    SELECT 'bllng_group', 'Billing_Group', CURRENT_DATE() - 1,
           w.company_id, COALESCE(u.active_employees, 0)
    FROM base_customers w
    INNER JOIN PROD_DWH.WATERFALL.MRT_WTFL_DAILY elig
        ON w.company_id = elig.company_id
       AND elig.model_type = 'actual' AND elig.revenue_type = 'arr'
       AND elig.date_id = CURRENT_DATE() AND elig.is_active_product = TRUE
       AND elig.grouping_ind = 'yes' AND elig.product_code NOT LIKE 'UK%'
    LEFT JOIN (
        SELECT company_id, SUM(COALESCE(active_employees, 0)) AS active_employees
        FROM PROD_DWH.WATERFALL.MRT_USAGE
        WHERE source_table = 'Billing_Group' AND date_id = CURRENT_DATE() - 1
        GROUP BY 1
    ) u ON w.company_id = u.company_id

    UNION ALL

    SELECT 'pento_payroll_usage', 'pento_payroll_usage', CURRENT_DATE(),
           w.company_id, COALESCE(u.active_employees, 0)
    FROM base_customers w
    INNER JOIN PROD_DWH.WATERFALL.MRT_WTFL_DAILY elig
        ON w.company_id = elig.company_id
       AND elig.model_type = 'actual' AND elig.revenue_type = 'arr'
       AND elig.date_id = CURRENT_DATE() AND elig.is_active_product = TRUE
       AND elig.product_code LIKE 'UK%'
    LEFT JOIN (
        SELECT company_id, SUM(COALESCE(active_employees, 0)) AS active_employees
        FROM PROD_DWH.WATERFALL.MRT_USAGE
        WHERE source_table = 'pento_payroll_usage' AND date_id = CURRENT_DATE()
        GROUP BY 1
    ) u ON w.company_id = u.company_id
),

usage_missing_samples AS (
    SELECT
        check_name,
        source_table,
        check_date,
        ARRAY_AGG(OBJECT_CONSTRUCT('company_id', company_id)) WITHIN GROUP (ORDER BY company_id) AS sample_missing_companies
    FROM (
        SELECT uc.check_name, uc.source_table, uc.check_date, uc.company_id,
               ROW_NUMBER() OVER (PARTITION BY uc.check_name ORDER BY uc.company_id) AS rn
        FROM usage_checks uc
        WHERE usage_value = 0
    )
    WHERE rn <= 10
    GROUP BY 1, 2, 3
),

usage_alerts AS (
    SELECT
        'missing_usage_data' AS alert_type,
        uc.check_name AS issue_type,
        uc.source_table,
        uc.check_date AS alert_date,
        COUNT(DISTINCT uc.company_id) AS metric_1,
        COUNT(DISTINCT CASE WHEN uc.usage_value > 0 THEN uc.company_id END) AS metric_2,
        ROUND(
            COUNT(DISTINCT CASE WHEN uc.usage_value > 0 THEN uc.company_id END)
            / NULLIF(COUNT(DISTINCT uc.company_id), 0) * 100, 2
        ) AS metric_3,
        NULL::NUMBER AS metric_4,
        OBJECT_CONSTRUCT(
            'total_eligible_companies', COUNT(DISTINCT uc.company_id),
            'companies_with_usage', COUNT(DISTINCT CASE WHEN uc.usage_value > 0 THEN uc.company_id END),
            'coverage_pct', ROUND(
                COUNT(DISTINCT CASE WHEN uc.usage_value > 0 THEN uc.company_id END)
                / NULLIF(COUNT(DISTINCT uc.company_id), 0) * 100, 2
            ),
            'threshold_pct', 50,
            'source_table', uc.source_table,
            'measure_field', 'active_employees',
            'table', 'PROD_DWH.WATERFALL.MRT_USAGE',
            'sample_missing_companies', COALESCE(ms.sample_missing_companies, ARRAY_CONSTRUCT())
        ) AS detail
    FROM usage_checks uc
    LEFT JOIN usage_missing_samples ms
        ON uc.check_name = ms.check_name
       AND uc.source_table = ms.source_table
       AND uc.check_date = ms.check_date
    GROUP BY uc.check_name, uc.source_table, uc.check_date, ms.sample_missing_companies
    HAVING COUNT(DISTINCT CASE WHEN uc.usage_value > 0 THEN uc.company_id END)
         < COUNT(DISTINCT uc.company_id) * 0.5
),

end_bucket_top_drivers AS (
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
        ORDER BY ABS(delta_end_budget_usd) DESC
        LIMIT 5
    )
),

end_bucket_alerts AS (
    SELECT
        'end_bucket_change' AS alert_type,
        'end_bucket_change' AS issue_type,
        'MRT_WTFL_DAILY / MRT_WTFL_DAILY_SNAP' AS source_table,
        CURRENT_DATE() AS alert_date,
        t.total_end AS metric_1,
        s.total_end AS metric_2,
        ROUND(ABS(t.total_end - s.total_end) / NULLIF(s.total_end, 0) * 100, 2) AS metric_3,
        NULL::NUMBER AS metric_4,
        OBJECT_CONSTRUCT(
            'current_value', t.total_end,
            'previous_value', s.total_end,
            'diff_pct', ROUND(ABS(t.total_end - s.total_end) / NULLIF(s.total_end, 0) * 100, 2),
            'date', CURRENT_DATE(),
            'measure_field', 'end_budget_usd',
            'today_table', 'PROD_DWH.WATERFALL.MRT_WTFL_DAILY',
            'previous_table', 'PROD_DWH.WATERFALL.MRT_WTFL_DAILY_SNAP',
            'top_drivers', d.top_drivers
        ) AS detail
    FROM (
        SELECT SUM(end_budget_usd) AS total_end
        FROM PROD_DWH.WATERFALL.MRT_WTFL_DAILY
        WHERE model_type = 'actual' AND revenue_type = 'carr' AND date_id = CURRENT_DATE()
    ) t
    CROSS JOIN (
        SELECT SUM(end_budget_usd) AS total_end
        FROM PROD_DWH.WATERFALL.MRT_WTFL_DAILY_SNAP
        WHERE model_type = 'actual' AND revenue_type = 'carr'
          AND date_key = CURRENT_DATE() - 1 AND date_id = CURRENT_DATE() - 1
    ) s
    CROSS JOIN end_bucket_top_drivers d
    WHERE ABS(t.total_end - s.total_end) / NULLIF(s.total_end, 0) > 0.10
),

ee_top_drivers AS (
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
        ORDER BY ABS(delta_number_of_employees) DESC
        LIMIT 5
    )
),

ee_alerts AS (
    SELECT
        'core_employee_count_change' AS alert_type,
        'core_employee_count_change' AS issue_type,
        'COR0001' AS source_table,
        CURRENT_DATE() AS alert_date,
        t.total_ee AS metric_1,
        s.total_ee AS metric_2,
        ROUND(ABS(t.total_ee - s.total_ee) / NULLIF(s.total_ee, 0) * 100, 2) AS metric_3,
        NULL::NUMBER AS metric_4,
        OBJECT_CONSTRUCT(
            'current_employee_count', t.total_ee,
            'previous_employee_count', s.total_ee,
            'diff_pct', ROUND(ABS(t.total_ee - s.total_ee) / NULLIF(s.total_ee, 0) * 100, 2),
            'date', CURRENT_DATE(),
            'product', 'Core',
            'product_code', 'COR0001',
            'measure_field', 'number_of_employees',
            'today_table', 'PROD_DWH.WATERFALL.MRT_WTFL_DAILY',
            'previous_table', 'PROD_DWH.WATERFALL.MRT_WTFL_DAILY_SNAP',
            'top_drivers', d.top_drivers
        ) AS detail
    FROM (
        SELECT SUM(number_of_employees) AS total_ee
        FROM PROD_DWH.WATERFALL.MRT_WTFL_DAILY
        WHERE model_type = 'actual' AND revenue_type = 'carr'
          AND date_id = CURRENT_DATE() AND product_code = 'COR0001'
    ) t
    CROSS JOIN (
        SELECT SUM(number_of_employees) AS total_ee
        FROM PROD_DWH.WATERFALL.MRT_WTFL_DAILY_SNAP
        WHERE model_type = 'actual' AND revenue_type = 'carr'
          AND date_key = CURRENT_DATE() - 1 AND date_id = CURRENT_DATE() - 1
          AND product_code = 'COR0001'
    ) s
    CROSS JOIN ee_top_drivers d
    WHERE ABS(t.total_ee - s.total_ee) / NULLIF(s.total_ee, 0) > 0.10
),

daily_counts AS (
    SELECT 'MRT_WTFL_DAILY' AS source_table, date_id AS record_date, COUNT(*) AS record_count
    FROM PROD_DWH.WATERFALL.MRT_WTFL_DAILY
    WHERE date_id BETWEEN CURRENT_DATE() - 7 AND CURRENT_DATE()
    GROUP BY 1, 2
    UNION ALL
    SELECT 'MRT_WTFL_DAILY_SNAP', date_key, COUNT(*)
    FROM PROD_DWH.WATERFALL.MRT_WTFL_DAILY_SNAP
    WHERE date_key BETWEEN CURRENT_DATE() - 7 AND CURRENT_DATE()
    GROUP BY 1, 2
    UNION ALL
    SELECT 'MRT_USAGE', date_id, COUNT(*)
    FROM PROD_DWH.WATERFALL.MRT_USAGE
    WHERE date_id BETWEEN CURRENT_DATE() - 7 AND CURRENT_DATE()
    GROUP BY 1, 2
    UNION ALL
    SELECT 'FACT_WATERFALL_BUCKETS', date_id, COUNT(*)
    FROM PROD_DWH.WATERFALL.FACT_WATERFALL_BUCKETS
    WHERE date_id BETWEEN CURRENT_DATE() - 7 AND CURRENT_DATE()
    GROUP BY 1, 2
),

volume_dup_daily AS (
    SELECT
        'MRT_WTFL_DAILY' AS source_table,
        stats.duplicate_key_groups,
        stats.extra_duplicate_rows,
        tops.top_duplicate_keys
    FROM (
        SELECT
            COUNT(*) AS duplicate_key_groups,
            SUM(cnt - 1) AS extra_duplicate_rows
        FROM (
            SELECT COUNT(*) AS cnt
            FROM PROD_DWH.WATERFALL.MRT_WTFL_DAILY
            WHERE date_id = CURRENT_DATE()
            GROUP BY company_id, product_code, revenue_type, model_type, date_id
            HAVING COUNT(*) > 1
        )
    ) stats
    CROSS JOIN (
        SELECT ARRAY_AGG(
            OBJECT_CONSTRUCT(
                'company_id', company_id,
                'product_code', product_code,
                'row_count', cnt,
                'field', 'company_id, product_code, revenue_type, model_type, date_id'
            )
        ) WITHIN GROUP (ORDER BY cnt DESC) AS top_duplicate_keys
        FROM (
            SELECT company_id, product_code, COUNT(*) AS cnt
            FROM PROD_DWH.WATERFALL.MRT_WTFL_DAILY
            WHERE date_id = CURRENT_DATE()
            GROUP BY company_id, product_code, revenue_type, model_type, date_id
            HAVING COUNT(*) > 1
            ORDER BY cnt DESC
            LIMIT 5
        )
    ) tops
),
volume_dup_snap AS (
    SELECT
        'MRT_WTFL_DAILY_SNAP' AS source_table,
        stats.duplicate_key_groups,
        stats.extra_duplicate_rows,
        tops.top_duplicate_keys
    FROM (
        SELECT
            COUNT(*) AS duplicate_key_groups,
            SUM(cnt - 1) AS extra_duplicate_rows
        FROM (
            SELECT COUNT(*) AS cnt
            FROM PROD_DWH.WATERFALL.MRT_WTFL_DAILY_SNAP
            WHERE date_key = CURRENT_DATE()
            GROUP BY company_id, product_code, revenue_type, model_type, date_key, date_id
            HAVING COUNT(*) > 1
        )
    ) stats
    CROSS JOIN (
        SELECT ARRAY_AGG(
            OBJECT_CONSTRUCT(
                'company_id', company_id,
                'product_code', product_code,
                'row_count', cnt,
                'field', 'company_id, product_code, revenue_type, model_type, date_key, date_id'
            )
        ) WITHIN GROUP (ORDER BY cnt DESC) AS top_duplicate_keys
        FROM (
            SELECT company_id, product_code, COUNT(*) AS cnt
            FROM PROD_DWH.WATERFALL.MRT_WTFL_DAILY_SNAP
            WHERE date_key = CURRENT_DATE()
            GROUP BY company_id, product_code, revenue_type, model_type, date_key, date_id
            HAVING COUNT(*) > 1
            ORDER BY cnt DESC
            LIMIT 5
        )
    ) tops
),
volume_dup_usage AS (
    SELECT
        'MRT_USAGE' AS source_table,
        stats.duplicate_key_groups,
        stats.extra_duplicate_rows,
        tops.top_duplicate_keys
    FROM (
        SELECT
            COUNT(*) AS duplicate_key_groups,
            SUM(cnt - 1) AS extra_duplicate_rows
        FROM (
            SELECT COUNT(*) AS cnt
            FROM PROD_DWH.WATERFALL.MRT_USAGE
            WHERE date_id = CURRENT_DATE()
            GROUP BY company_id, source_table, date_id
            HAVING COUNT(*) > 1
        )
    ) stats
    CROSS JOIN (
        SELECT ARRAY_AGG(
            OBJECT_CONSTRUCT(
                'company_id', company_id,
                'source_table', source_table_name,
                'row_count', cnt,
                'field', 'company_id, source_table, date_id'
            )
        ) WITHIN GROUP (ORDER BY cnt DESC) AS top_duplicate_keys
        FROM (
            SELECT company_id, source_table AS source_table_name, COUNT(*) AS cnt
            FROM PROD_DWH.WATERFALL.MRT_USAGE
            WHERE date_id = CURRENT_DATE()
            GROUP BY company_id, source_table, date_id
            HAVING COUNT(*) > 1
            ORDER BY cnt DESC
            LIMIT 5
        )
    ) tops
),
volume_dup_buckets AS (
    SELECT
        'FACT_WATERFALL_BUCKETS' AS source_table,
        stats.duplicate_key_groups,
        stats.extra_duplicate_rows,
        tops.top_duplicate_keys
    FROM (
        SELECT
            COUNT(*) AS duplicate_key_groups,
            SUM(cnt - 1) AS extra_duplicate_rows
        FROM (
            SELECT COUNT(*) AS cnt
            FROM PROD_DWH.WATERFALL.FACT_WATERFALL_BUCKETS
            WHERE date_id = CURRENT_DATE()
            GROUP BY company_id, product_code, revenue_type, model_type, date_id
            HAVING COUNT(*) > 1
        )
    ) stats
    CROSS JOIN (
        SELECT ARRAY_AGG(
            OBJECT_CONSTRUCT(
                'company_id', company_id,
                'product_code', product_code,
                'row_count', cnt,
                'field', 'company_id, product_code, revenue_type, model_type, date_id'
            )
        ) WITHIN GROUP (ORDER BY cnt DESC) AS top_duplicate_keys
        FROM (
            SELECT company_id, product_code, COUNT(*) AS cnt
            FROM PROD_DWH.WATERFALL.FACT_WATERFALL_BUCKETS
            WHERE date_id = CURRENT_DATE()
            GROUP BY company_id, product_code, revenue_type, model_type, date_id
            HAVING COUNT(*) > 1
            ORDER BY cnt DESC
            LIMIT 5
        )
    ) tops
),
volume_dup_all AS (
    SELECT * FROM volume_dup_daily
    UNION ALL SELECT * FROM volume_dup_snap
    UNION ALL SELECT * FROM volume_dup_usage
    UNION ALL SELECT * FROM volume_dup_buckets
),

volume_alerts AS (
    SELECT
        'volume_anomaly' AS alert_type,
        'volume_anomaly_' || LOWER(c.source_table) AS issue_type,
        c.source_table,
        c.record_date AS alert_date,
        c.record_count AS metric_1,
        b.expected_record_count AS metric_2,
        ROUND(
            ABS(c.record_count - b.expected_record_count)
            / NULLIF(b.expected_record_count, 0) * 100, 2
        ) AS metric_3,
        NULL::NUMBER AS metric_4,
        OBJECT_CONSTRUCT(
            'current_record_count', c.record_count,
            'expected_record_count', ROUND(b.expected_record_count, 2),
            'deviation_pct', ROUND(
                ABS(c.record_count - b.expected_record_count)
                / NULLIF(b.expected_record_count, 0) * 100, 2
            ),
            'date', c.record_date,
            'source_table', c.source_table,
            'duplicate_key_groups', COALESCE(d.duplicate_key_groups, 0),
            'extra_duplicate_rows', COALESCE(d.extra_duplicate_rows, 0),
            'top_duplicate_keys', COALESCE(d.top_duplicate_keys, ARRAY_CONSTRUCT()),
            'likely_cause',
                CASE
                    WHEN COALESCE(d.duplicate_key_groups, 0) > 0 THEN 'duplicate rows on natural key'
                    ELSE 'row count deviation vs 7-day average'
                END
        ) AS detail
    FROM daily_counts c
    INNER JOIN (
        SELECT source_table, AVG(record_count) AS expected_record_count
        FROM daily_counts
        WHERE record_date BETWEEN CURRENT_DATE() - 7 AND CURRENT_DATE() - 1
        GROUP BY 1
    ) b ON c.source_table = b.source_table
    LEFT JOIN volume_dup_all d ON c.source_table = d.source_table
    WHERE c.record_date = CURRENT_DATE()
      AND ABS(c.record_count - b.expected_record_count) / NULLIF(b.expected_record_count, 0) > 0.20
),

natural_growth_top_drivers AS (
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
        ORDER BY ABS(delta_natural_growth_budget_usd) DESC
        LIMIT 5
    )
),

natural_growth_alerts AS (
    SELECT
        'natural_growth_change' AS alert_type,
        'natural_growth_change' AS issue_type,
        'carr_current' AS source_table,
        CURRENT_DATE() - 1 AS alert_date,
        y.total_natural_growth AS metric_1,
        d.total_natural_growth AS metric_2,
        ROUND(ABS(y.total_natural_growth - d.total_natural_growth), 2) AS metric_3,
        ROUND(
            ABS(y.total_natural_growth - d.total_natural_growth)
            / NULLIF(d.total_natural_growth, 0) * 100, 2
        ) AS metric_4,
        OBJECT_CONSTRUCT(
            'prev_day_natural_growth', y.total_natural_growth,
            'two_days_ago_natural_growth', d.total_natural_growth,
            'abs_difference', ROUND(ABS(y.total_natural_growth - d.total_natural_growth), 2),
            'diff_pct', ROUND(
                ABS(y.total_natural_growth - d.total_natural_growth)
                / NULLIF(d.total_natural_growth, 0) * 100, 2
            ),
            'date', CURRENT_DATE() - 1,
            'bucket_type', 'carr_current',
            'measure_field', 'natural_growth_budget_usd',
            'table', 'PROD_DWH.WATERFALL.MRT_WTFL_DAILY_SNAP',
            'top_drivers', td.top_drivers
        ) AS detail
    FROM (
        SELECT SUM(natural_growth_budget_usd) AS total_natural_growth
        FROM PROD_DWH.WATERFALL.MRT_WTFL_DAILY_SNAP
        WHERE model_type = 'actual' AND revenue_type = 'carr'
          AND date_key = CURRENT_DATE() - 1 AND date_id = CURRENT_DATE() - 1
    ) y
    CROSS JOIN (
        SELECT SUM(natural_growth_budget_usd) AS total_natural_growth
        FROM PROD_DWH.WATERFALL.MRT_WTFL_DAILY_SNAP
        WHERE model_type = 'actual' AND revenue_type = 'carr'
          AND date_key = CURRENT_DATE() - 2 AND date_id = CURRENT_DATE() - 2
    ) d
    CROSS JOIN natural_growth_top_drivers td
    WHERE ABS(y.total_natural_growth - d.total_natural_growth) > 800000
)

SELECT alert_type, issue_type, source_table, alert_date, metric_1, metric_2, metric_3, metric_4, detail
FROM usage_alerts
UNION ALL SELECT alert_type, issue_type, source_table, alert_date, metric_1, metric_2, metric_3, metric_4, detail FROM end_bucket_alerts
UNION ALL SELECT alert_type, issue_type, source_table, alert_date, metric_1, metric_2, metric_3, metric_4, detail FROM ee_alerts
UNION ALL SELECT alert_type, issue_type, source_table, alert_date, metric_1, metric_2, metric_3, metric_4, detail FROM volume_alerts
UNION ALL SELECT alert_type, issue_type, source_table, alert_date, metric_1, metric_2, metric_3, metric_4, detail FROM natural_growth_alerts;
