-- Check 4: Volume anomaly — >20% deviation from prior 7-day average

WITH daily_counts AS (
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
baseline AS (
    SELECT source_table, AVG(record_count) AS expected_record_count
    FROM daily_counts
    WHERE record_date BETWEEN CURRENT_DATE() - 7 AND CURRENT_DATE() - 1
    GROUP BY 1
),
current_day AS (
    SELECT source_table, record_date, record_count AS current_record_count
    FROM daily_counts
    WHERE record_date = CURRENT_DATE()
),
comparison AS (
    SELECT
        c.source_table,
        c.record_date AS alert_date,
        c.current_record_count,
        b.expected_record_count,
        ROUND(
            ABS(c.current_record_count - b.expected_record_count)
            / NULLIF(b.expected_record_count, 0) * 100,
            2
        ) AS deviation_pct
    FROM current_day c
    INNER JOIN baseline b ON c.source_table = b.source_table
)

SELECT
    'volume_anomaly' AS alert_type,
    'volume_anomaly_' || LOWER(source_table) AS issue_type,
    source_table,
    alert_date,
    current_record_count,
    ROUND(expected_record_count, 2) AS expected_record_count,
    deviation_pct,
    CASE WHEN deviation_pct > 20 THEN 'ALERT' ELSE 'OK' END AS status,
    OBJECT_CONSTRUCT(
        'current_record_count', current_record_count,
        'expected_record_count', ROUND(expected_record_count, 2),
        'deviation_pct', deviation_pct,
        'date', alert_date,
        'source_table', source_table
    ) AS detail
FROM comparison
WHERE deviation_pct > 20;
