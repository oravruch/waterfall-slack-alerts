-- Volume anomaly detection for MRT_WTFL_UNPIVOT comparing today's record count to 7-day average
-- Co-authored with CoCo

WITH daily_counts AS (
    SELECT date_id AS record_date, COUNT(*) AS record_count
    FROM PROD_DWH.WATERFALL.MRT_WTFL_UNPIVOT
    WHERE date_id BETWEEN CURRENT_DATE() - 7 AND CURRENT_DATE()
    GROUP BY 1
),
baseline AS (
    SELECT AVG(record_count) AS expected_record_count
    FROM daily_counts
    WHERE record_date BETWEEN CURRENT_DATE() - 7 AND CURRENT_DATE() - 1
),
today AS (
    SELECT record_count AS current_record_count
    FROM daily_counts
    WHERE record_date = CURRENT_DATE()
)
SELECT
    'volume_anomaly' AS alert_type,
    'volume_anomaly_mrt_wtfl_unpivot' AS issue_type,
    'MRT_WTFL_UNPIVOT' AS source_table,
    CURRENT_DATE() AS alert_date,
    t.current_record_count,
    t.current_record_count - b.expected_record_count AS diff_record,
    ROUND(b.expected_record_count, 2) AS expected_record_count,
    ROUND(
        ABS(t.current_record_count - b.expected_record_count)
        / NULLIF(b.expected_record_count, 0) * 100,
        2
    ) AS deviation_pct,
    CASE
        WHEN ABS(t.current_record_count - b.expected_record_count)
             / NULLIF(b.expected_record_count, 0) > 0.20
        THEN 'ALERT'
        ELSE 'OK'
    END AS status,
    OBJECT_CONSTRUCT(
        'current_record_count', t.current_record_count,
        'diff_record', t.current_record_count - b.expected_record_count,
        'expected_record_count', ROUND(b.expected_record_count, 2),
        'deviation_pct', ROUND(
            ABS(t.current_record_count - b.expected_record_count)
            / NULLIF(b.expected_record_count, 0) * 100,
            2
        ),
        'date', CURRENT_DATE(),
        'source_table', 'MRT_WTFL_UNPIVOT',
        'co_authored_with', 'CoCo'
    ) AS detail
FROM today t
CROSS JOIN baseline b
WHERE ABS(t.current_record_count - b.expected_record_count)
      / NULLIF(b.expected_record_count, 0) > 0.20;
