-- =============================================================================
-- SCRIPT 04 of 04: Continuous monitoring, drift detection, and retraining
--                   automation — entirely SQL / pg_cron, per business-case 7.2.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Monitoring tables
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS monitoring.model_performance_log (
    log_id            BIGSERIAL PRIMARY KEY,
    model_name         TEXT NOT NULL,
    model_version        TEXT NOT NULL,
    evaluation_window_start DATE,
    evaluation_window_end   DATE,
    metric_name             TEXT NOT NULL,      -- e.g. 'RMSE','MAE','AUC','F1','Precision','Recall'
    metric_value              NUMERIC(10,4),
    sample_size                 INTEGER,
    logged_at                    TIMESTAMPTZ NOT NULL DEFAULT now()
);
COMMENT ON TABLE monitoring.model_performance_log IS 'Rolling model performance metrics, computed in SQL against known-outcome data, for the Power BI model-ops dashboard.';

CREATE TABLE IF NOT EXISTS monitoring.data_drift_log (
    log_id            BIGSERIAL PRIMARY KEY,
    feature_name       TEXT NOT NULL,
    reference_mean      NUMERIC,
    current_mean          NUMERIC,
    pct_change              NUMERIC(8,4),
    drift_flag                BOOLEAN,
    evaluated_at                TIMESTAMPTZ NOT NULL DEFAULT now()
);
COMMENT ON TABLE monitoring.data_drift_log IS 'Simple threshold-based drift detection on key feature distributions (mean-shift test). Extend with KS-test approximations as needed.';

CREATE TABLE IF NOT EXISTS monitoring.alerts (
    alert_id          BIGSERIAL PRIMARY KEY,
    alert_type          TEXT NOT NULL CHECK (alert_type IN ('Data Quality','Data Drift','Model Performance','Prediction Volume')),
    severity              TEXT NOT NULL CHECK (severity IN ('Info','Warning','Critical')),
    message                 TEXT NOT NULL,
    related_entity            TEXT,
    raised_at                   TIMESTAMPTZ NOT NULL DEFAULT now(),
    acknowledged                 BOOLEAN NOT NULL DEFAULT FALSE,
    acknowledged_by                TEXT,
    acknowledged_at                  TIMESTAMPTZ
);
COMMENT ON TABLE monitoring.alerts IS 'Unified alert feed surfaced in the Power BI executive and reliability-engineering dashboards.';

-- -----------------------------------------------------------------------------
-- 2. Performance evaluation function (RMSE/MAE for RUL, AUC-proxy for classifiers)
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION monitoring.evaluate_rul_model(p_model_name TEXT, p_model_version TEXT)
RETURNS VOID AS $$
DECLARE
    v_rmse NUMERIC;
    v_mae  NUMERIC;
    v_n    INTEGER;
    v_start DATE;
    v_end   DATE;
BEGIN
    SELECT MIN(f.snapshot_date), MAX(f.snapshot_date) INTO v_start, v_end
    FROM features.component_health_test f;

    SELECT
        ROUND(SQRT(AVG(POWER(p.predicted_rul_days - f.remaining_useful_life_days, 2))), 4),
        ROUND(AVG(ABS(p.predicted_rul_days - f.remaining_useful_life_days)), 4),
        COUNT(*)
    INTO v_rmse, v_mae, v_n
    FROM predictions.component_rul_predictions p
    JOIN features.component_health_features_v1 f
      ON f.record_id = p.record_id AND f.snapshot_date = p.snapshot_date
    WHERE p.model_name = p_model_name;

    INSERT INTO monitoring.model_performance_log
        (model_name, model_version, evaluation_window_start, evaluation_window_end, metric_name, metric_value, sample_size)
    VALUES
        (p_model_name, p_model_version, v_start, v_end, 'RMSE', v_rmse, v_n),
        (p_model_name, p_model_version, v_start, v_end, 'MAE', v_mae, v_n);

    IF v_rmse IS NOT NULL AND v_rmse > 150 THEN
        INSERT INTO monitoring.alerts (alert_type, severity, message, related_entity)
        VALUES ('Model Performance', 'Warning',
                format('RUL model RMSE degraded to %s days (threshold: 150).', v_rmse),
                p_model_name);
    END IF;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION monitoring.evaluate_classifier(p_model_name TEXT, p_prob_column TEXT, p_label_column TEXT)
RETURNS VOID AS $$
DECLARE
    v_precision NUMERIC;
    v_recall    NUMERIC;
    v_n         INTEGER;
BEGIN
    EXECUTE format($f$
        SELECT
            ROUND(SUM(CASE WHEN p.%1$I > 0.5 AND f.%2$I = 1 THEN 1 ELSE 0 END)::NUMERIC
                  / NULLIF(SUM(CASE WHEN p.%1$I > 0.5 THEN 1 ELSE 0 END), 0), 4),
            ROUND(SUM(CASE WHEN p.%1$I > 0.5 AND f.%2$I = 1 THEN 1 ELSE 0 END)::NUMERIC
                  / NULLIF(SUM(CASE WHEN f.%2$I = 1 THEN 1 ELSE 0 END), 0), 4),
            COUNT(*)
        FROM predictions.component_rul_predictions p
        JOIN features.component_health_features_v1 f
          ON f.record_id = p.record_id AND f.snapshot_date = p.snapshot_date
        WHERE p.model_name = %3$L
    $f$, p_prob_column, p_label_column, p_model_name)
    INTO v_precision, v_recall, v_n;

    INSERT INTO monitoring.model_performance_log
        (model_name, model_version, evaluation_window_start, evaluation_window_end, metric_name, metric_value, sample_size)
    VALUES
        (p_model_name, 'v1', NULL, NULL, 'Precision', v_precision, v_n),
        (p_model_name, 'v1', NULL, NULL, 'Recall', v_recall, v_n);

    IF v_recall IS NOT NULL AND v_recall < 0.6 THEN
        INSERT INTO monitoring.alerts (alert_type, severity, message, related_entity)
        VALUES ('Model Performance', 'Critical',
                format('%s recall dropped to %s (threshold: 0.60) — schedule retraining review.', p_model_name, v_recall),
                p_model_name);
    END IF;
END;
$$ LANGUAGE plpgsql;

-- -----------------------------------------------------------------------------
-- 3. Data drift check — compares current 30-day feature means to a reference
--    baseline window, per feature, and logs/alerts on threshold breach.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION monitoring.check_feature_drift()
RETURNS VOID AS $$
DECLARE
    v_ref_mean NUMERIC;
    v_cur_mean NUMERIC;
    v_pct NUMERIC;
    v_feature TEXT;
    v_features TEXT[] := ARRAY['health_monitoring_score','sensor_vibration_index',
                                'sensor_oil_debris_index','anomaly_count_last_30_days'];
BEGIN
    FOREACH v_feature IN ARRAY v_features LOOP
        EXECUTE format(
            'SELECT AVG(%1$I) FROM features.component_health_features_v1
             WHERE snapshot_date < (SELECT MAX(snapshot_date) - INTERVAL %2$L FROM features.component_health_features_v1)',
             v_feature, '90 days'
        ) INTO v_ref_mean;

        EXECUTE format(
            'SELECT AVG(%1$I) FROM features.component_health_features_v1
             WHERE snapshot_date >= (SELECT MAX(snapshot_date) - INTERVAL %2$L FROM features.component_health_features_v1)',
             v_feature, '30 days'
        ) INTO v_cur_mean;

        v_pct := ROUND(100.0 * (v_cur_mean - v_ref_mean) / NULLIF(ABS(v_ref_mean), 0), 4);

        INSERT INTO monitoring.data_drift_log (feature_name, reference_mean, current_mean, pct_change, drift_flag)
        VALUES (v_feature, v_ref_mean, v_cur_mean, v_pct, ABS(v_pct) > 15);

        IF ABS(v_pct) > 15 THEN
            INSERT INTO monitoring.alerts (alert_type, severity, message, related_entity)
            VALUES ('Data Drift', 'Warning',
                    format('Feature "%s" shifted %s%% vs. baseline — review upstream source and consider retraining.', v_feature, v_pct),
                    v_feature);
        END IF;
    END LOOP;
END;
$$ LANGUAGE plpgsql;

-- -----------------------------------------------------------------------------
-- 4. Scheduled jobs via pg_cron (requires: CREATE EXTENSION IF NOT EXISTS pg_cron;)
-- -----------------------------------------------------------------------------

-- CREATE EXTENSION IF NOT EXISTS pg_cron;

-- Nightly: refresh features, re-score, log drift & performance
-- SELECT cron.schedule('helios_nightly_feature_refresh', '0 2 * * *',
--     $$SELECT features.build_component_health_features_v1();$$);

-- SELECT cron.schedule('helios_nightly_drift_check', '15 2 * * *',
--     $$SELECT monitoring.check_feature_drift();$$);

-- SELECT cron.schedule('helios_weekly_model_eval', '0 3 * * 1',
--     $$SELECT monitoring.evaluate_rul_model('helios_component_rul_regression','v1');
--       SELECT monitoring.evaluate_classifier('helios_component_failure_90d_classification','predicted_failure_prob_90d','failure_within_90_days');
--       SELECT monitoring.evaluate_classifier('helios_component_failure_30d_classification','predicted_failure_prob_30d','failure_within_30_days');$$);

-- Monthly: ensure next month's fact-table partition exists ahead of load
-- SELECT cron.schedule('helios_monthly_partition', '0 0 1 * *',
--     $$SELECT mgmt.ensure_partition((CURRENT_DATE + INTERVAL '1 month')::DATE);$$);

-- Retraining trigger: simple threshold-based condition, per business-case 7.2
-- ("retraining triggered by scheduled SQL jobs or simple threshold-based
-- conditions stored in the database"). Run manually or wire into pg_cron.
CREATE OR REPLACE FUNCTION mgmt.retraining_required()
RETURNS TABLE(model_name TEXT, reason TEXT) AS $$
    SELECT DISTINCT a.related_entity, a.message
    FROM monitoring.alerts a
    WHERE a.alert_type IN ('Model Performance', 'Data Drift')
      AND a.severity IN ('Warning', 'Critical')
      AND a.raised_at > now() - INTERVAL '7 days'
      AND NOT a.acknowledged;
$$ LANGUAGE sql;

-- -----------------------------------------------------------------------------
-- 5. Convenience views for the Power BI decision-support layer
-- -----------------------------------------------------------------------------

CREATE OR REPLACE VIEW predictions.vw_latest_component_risk AS
SELECT DISTINCT ON (p.component_serial_number)
    p.component_serial_number, c.component_type, c.component_subtype,
    f.aircraft_tail_number, a.aircraft_model, a.fleet_type, a.operating_region,
    p.predicted_rul_days, p.predicted_failure_prob_30d, p.predicted_failure_prob_90d,
    p.risk_tier, p.snapshot_date, p.scored_at
FROM predictions.component_rul_predictions p
JOIN curated.dim_component c ON c.component_serial_number = p.component_serial_number
JOIN curated.fact_component_health_snapshot f
     ON f.record_id = p.record_id AND f.snapshot_date = p.snapshot_date
JOIN curated.dim_aircraft a ON a.aircraft_tail_number = f.aircraft_tail_number
ORDER BY p.component_serial_number, p.scored_at DESC;
COMMENT ON VIEW predictions.vw_latest_component_risk IS 'One row per component: most recent prediction, joined to master data. Primary Power BI source for the reliability-engineering and executive dashboards.';

CREATE OR REPLACE VIEW monitoring.vw_open_alerts AS
SELECT * FROM monitoring.alerts WHERE NOT acknowledged ORDER BY severity DESC, raised_at DESC;
