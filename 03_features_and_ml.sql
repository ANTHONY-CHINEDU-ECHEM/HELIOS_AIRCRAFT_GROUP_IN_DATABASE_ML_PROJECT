-- =============================================================================
-- SCRIPT 03 of 04: Feature engineering (pure SQL) + in-database ML lifecycle
--
-- Per business-case section 7.2, all training/inference happens INSIDE
-- PostgreSQL via the PostgresML extension. Algorithms are restricted to those
-- natively supported (gradient-boosted trees, linear/logistic regression).
--
-- If PostgresML is not available in your environment, section 3 shows the
-- MADlib-equivalent call pattern as a fallback (commented).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Feature engineering — versioned feature table, built entirely with SQL
--    window functions, ratios, and joins against the curated fact table.
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS features.component_health_features_v1 (
    record_id                          BIGINT,
    snapshot_date                      DATE,
    component_serial_number            TEXT,
    aircraft_tail_number               TEXT,
    component_type                     TEXT,
    fleet_type                         TEXT,
    operating_environment              TEXT,
    -- engineered ratio / derived features
    pct_of_design_life_consumed        NUMERIC(8,4),   -- cumulative_flight_hours / design_mtbf_hours
    hours_per_cycle                    NUMERIC(10,3),  -- cumulative_flight_hours / NULLIF(cycles,0)
    unscheduled_removal_ratio          NUMERIC(6,4),   -- prior_unscheduled / NULLIF(prior_removal_count,0)
    sensor_composite_risk_score        NUMERIC(10,4),  -- weighted blend of vibration/oil/anomaly
    maintenance_recency_score          NUMERIC(8,4),   -- decays with days_since_last_maintenance_event
    rolling_30d_component_type_failure_rate NUMERIC(6,4), -- window function over component_type cohort
    aircraft_age_years                 NUMERIC(6,2),
    avg_daily_utilization_hours        NUMERIC(6,2),
    supplier_quality_score             NUMERIC(5,1),
    -- passthrough raw features model will also use
    cumulative_flight_hours            NUMERIC(12,1),
    cumulative_flight_cycles           NUMERIC(12,0),
    prior_removal_count                INTEGER,
    prior_unscheduled_removal_count    INTEGER,
    days_since_last_maintenance_event  INTEGER,
    maintenance_events_last_12_months  INTEGER,
    sensor_vibration_index             NUMERIC(8,3),
    sensor_oil_debris_index            NUMERIC(8,3),
    health_monitoring_score            NUMERIC(5,2),
    anomaly_count_last_30_days         INTEGER,
    corrosion_risk_index                NUMERIC(5,2),
    -- labels
    remaining_useful_life_days         NUMERIC(8,1),
    failure_within_30_days             SMALLINT,
    failure_within_90_days             SMALLINT,
    feature_version                    TEXT NOT NULL DEFAULT 'v1',
    computed_at                        TIMESTAMPTZ NOT NULL DEFAULT now()
);
COMMENT ON TABLE features.component_health_features_v1 IS 'Versioned, model-ready feature table for Use Case A. Rebuilt by features.build_component_health_features_v1(). Never edited by hand.';

CREATE OR REPLACE FUNCTION features.build_component_health_features_v1()
RETURNS VOID AS $$
BEGIN
    TRUNCATE TABLE features.component_health_features_v1;

    INSERT INTO features.component_health_features_v1 (
        record_id, snapshot_date, component_serial_number, aircraft_tail_number,
        component_type, fleet_type, operating_environment,
        pct_of_design_life_consumed, hours_per_cycle, unscheduled_removal_ratio,
        sensor_composite_risk_score, maintenance_recency_score,
        rolling_30d_component_type_failure_rate,
        aircraft_age_years, avg_daily_utilization_hours, supplier_quality_score,
        cumulative_flight_hours, cumulative_flight_cycles, prior_removal_count,
        prior_unscheduled_removal_count, days_since_last_maintenance_event,
        maintenance_events_last_12_months, sensor_vibration_index, sensor_oil_debris_index,
        health_monitoring_score, anomaly_count_last_30_days, corrosion_risk_index,
        remaining_useful_life_days, failure_within_30_days, failure_within_90_days
    )
    SELECT
        f.record_id, f.snapshot_date, f.component_serial_number, f.aircraft_tail_number,
        c.component_type, a.fleet_type, a.operating_environment,
        ROUND(f.cumulative_flight_hours / NULLIF(c.design_mtbf_hours, 0), 4) AS pct_of_design_life_consumed,
        ROUND(f.cumulative_flight_hours / NULLIF(f.cumulative_flight_cycles, 0), 3) AS hours_per_cycle,
        ROUND(f.prior_unscheduled_removal_count::NUMERIC / NULLIF(f.prior_removal_count, 0), 4) AS unscheduled_removal_ratio,
        ROUND(
            (0.40 * COALESCE(f.sensor_vibration_index, 0))
          + (0.35 * COALESCE(f.sensor_oil_debris_index, 0))
          + (0.25 * COALESCE(f.anomaly_count_last_30_days, 0)),
        4) AS sensor_composite_risk_score,
        ROUND(EXP(-1.0 * COALESCE(f.days_since_last_maintenance_event, 0) / 90.0), 4) AS maintenance_recency_score,
        ROUND(
            AVG(f.failure_within_90_days::NUMERIC) OVER (
                PARTITION BY c.component_type
                ORDER BY f.snapshot_date
                RANGE BETWEEN INTERVAL '30 days' PRECEDING AND CURRENT ROW
            ), 4
        ) AS rolling_30d_component_type_failure_rate,
        a.aircraft_age_years, a.avg_daily_utilization_hours, s.supplier_quality_score,
        f.cumulative_flight_hours, f.cumulative_flight_cycles, f.prior_removal_count,
        f.prior_unscheduled_removal_count, f.days_since_last_maintenance_event,
        f.maintenance_events_last_12_months, f.sensor_vibration_index, f.sensor_oil_debris_index,
        f.health_monitoring_score, f.anomaly_count_last_30_days, f.corrosion_risk_index,
        f.remaining_useful_life_days, f.failure_within_30_days, f.failure_within_90_days
    FROM curated.fact_component_health_snapshot f
    JOIN curated.dim_component c ON c.component_serial_number = f.component_serial_number
    JOIN curated.dim_aircraft  a ON a.aircraft_tail_number = f.aircraft_tail_number
    LEFT JOIN curated.dim_supplier s ON s.supplier_id = c.supplier_id;
END;
$$ LANGUAGE plpgsql;

SELECT features.build_component_health_features_v1();

CREATE INDEX IF NOT EXISTS ix_features_v1_snapshot ON features.component_health_features_v1(snapshot_date);
CREATE INDEX IF NOT EXISTS ix_features_v1_component ON features.component_health_features_v1(component_serial_number);

-- -----------------------------------------------------------------------------
-- 2. Temporal train/validation/test split (SQL date-filter based, per 7.2)
-- -----------------------------------------------------------------------------

CREATE OR REPLACE VIEW features.component_health_train AS
SELECT * FROM features.component_health_features_v1
WHERE snapshot_date < (SELECT MAX(snapshot_date) - INTERVAL '120 days' FROM features.component_health_features_v1);

CREATE OR REPLACE VIEW features.component_health_validation AS
SELECT * FROM features.component_health_features_v1
WHERE snapshot_date BETWEEN
    (SELECT MAX(snapshot_date) - INTERVAL '120 days' FROM features.component_health_features_v1)
    AND (SELECT MAX(snapshot_date) - INTERVAL '60 days' FROM features.component_health_features_v1);

CREATE OR REPLACE VIEW features.component_health_test AS
SELECT * FROM features.component_health_features_v1
WHERE snapshot_date > (SELECT MAX(snapshot_date) - INTERVAL '60 days' FROM features.component_health_features_v1);

-- -----------------------------------------------------------------------------
-- 3. Model registry & model-card metadata (structured data inside PostgreSQL)
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS models.model_registry (
    model_id            SERIAL PRIMARY KEY,
    model_name          TEXT NOT NULL,
    model_version        TEXT NOT NULL,
    use_case             TEXT NOT NULL,
    problem_type          TEXT NOT NULL CHECK (problem_type IN ('regression','classification')),
    algorithm            TEXT NOT NULL,
    feature_table         TEXT NOT NULL,
    target_column         TEXT NOT NULL,
    training_data_summary  JSONB,
    hyperparameters        JSONB,
    performance_metrics    JSONB,
    intended_use           TEXT,
    known_limitations      TEXT,
    risk_classification     TEXT CHECK (risk_classification IN ('Low','Medium','High')),
    trained_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    trained_by               TEXT NOT NULL DEFAULT current_user,
    is_active                BOOLEAN NOT NULL DEFAULT FALSE,
    UNIQUE (model_name, model_version)
);
COMMENT ON TABLE models.model_registry IS 'Model-card style registry: one row per trained model version, per business-case section 7.2.';

CREATE TABLE IF NOT EXISTS models.human_review_overrides (
    override_id       BIGSERIAL PRIMARY KEY,
    record_id          BIGINT,
    model_id            INTEGER REFERENCES models.model_registry(model_id),
    original_prediction  JSONB,
    reviewer_decision     TEXT CHECK (reviewer_decision IN ('Confirmed','Overridden','Escalated')),
    reviewer_id            TEXT,
    reviewer_comment        TEXT,
    reviewed_at              TIMESTAMPTZ NOT NULL DEFAULT now()
);
COMMENT ON TABLE models.human_review_overrides IS 'Captures human-in-the-loop review/override of high-impact predictions, feeding future retraining cycles (business-case design principle: human-in-the-loop by deliberate design).';

-- -----------------------------------------------------------------------------
-- 4. Train models via PostgresML
--    Requires: CREATE EXTENSION IF NOT EXISTS pgml;   (run once, superuser)
-- -----------------------------------------------------------------------------

-- CREATE EXTENSION IF NOT EXISTS pgml;

-- 4a. Regression model: Remaining Useful Life (days)
SELECT * FROM pgml.train(
    project_name  => 'helios_component_rul_regression',
    task          => 'regression',
    relation_name => 'features.component_health_train',
    y_column_name => 'remaining_useful_life_days',
    algorithm     => 'xgboost',
    hyperparams   => '{"n_estimators": 300, "max_depth": 6, "learning_rate": 0.05}'
);

-- 4b. Classification model: failure within 90 days
SELECT * FROM pgml.train(
    project_name  => 'helios_component_failure_90d_classification',
    task          => 'classification',
    relation_name => 'features.component_health_train',
    y_column_name => 'failure_within_90_days',
    algorithm     => 'xgboost',
    hyperparams   => '{"n_estimators": 300, "max_depth": 5, "learning_rate": 0.05}'
);

-- 4c. Classification model: failure within 30 days (higher-urgency, tighter window)
SELECT * FROM pgml.train(
    project_name  => 'helios_component_failure_30d_classification',
    task          => 'classification',
    relation_name => 'features.component_health_train',
    y_column_name => 'failure_within_30_days',
    algorithm     => 'xgboost',
    hyperparams   => '{"n_estimators": 250, "max_depth": 5, "learning_rate": 0.05}'
);

-- ---- MADlib fallback pattern (use if PostgresML extension is unavailable) ----
-- SELECT madlib.xgboost_train(
--     'features.component_health_train',       -- source table
--     'models.rul_xgb_model',                  -- output model table
--     'record_id',                             -- id column
--     'remaining_useful_life_days',             -- dependent variable
--     'ARRAY[cumulative_flight_hours, cumulative_flight_cycles, pct_of_design_life_consumed, ...]'
-- );

-- Register the trained models (metrics pulled from pgml.deploy history in practice;
-- illustrative INSERT shown here so the registry is populated end-to-end)
INSERT INTO models.model_registry
    (model_name, model_version, use_case, problem_type, algorithm, feature_table, target_column,
     training_data_summary, hyperparameters, intended_use, known_limitations, risk_classification, is_active)
VALUES
    ('helios_component_rul_regression', 'v1', 'Component Health Assessment & RUL Estimation', 'regression', 'xgboost',
     'features.component_health_features_v1', 'remaining_useful_life_days',
     jsonb_build_object('training_rows', (SELECT COUNT(*) FROM features.component_health_train)),
     '{"n_estimators": 300, "max_depth": 6, "learning_rate": 0.05}',
     'Prioritizing maintenance planning and identifying components approaching end-of-life for the four in-scope component families.',
     'Trained on synthetic/historical data; does not yet incorporate live health-monitoring telemetry; requires re-validation before use on new component types.',
     'High', TRUE),
    ('helios_component_failure_90d_classification', 'v1', 'Component Health Assessment & RUL Estimation', 'classification', 'xgboost',
     'features.component_health_features_v1', 'failure_within_90_days',
     jsonb_build_object('training_rows', (SELECT COUNT(*) FROM features.component_health_train)),
     '{"n_estimators": 300, "max_depth": 5, "learning_rate": 0.05}',
     'Ranking components for proactive inspection within a 90-day horizon.',
     'Class imbalance (~9% positive rate); recommend recall-oriented threshold tuning and human review of all High-risk flags.',
     'High', TRUE),
    ('helios_component_failure_30d_classification', 'v1', 'Component Health Assessment & RUL Estimation', 'classification', 'xgboost',
     'features.component_health_features_v1', 'failure_within_30_days',
     jsonb_build_object('training_rows', (SELECT COUNT(*) FROM features.component_health_train)),
     '{"n_estimators": 250, "max_depth": 5, "learning_rate": 0.05}',
     'Urgent, near-term maintenance triage.',
     'Severe class imbalance (~4% positive rate); precision degrades outside the training component families.',
     'High', TRUE)
ON CONFLICT (model_name, model_version) DO NOTHING;

-- -----------------------------------------------------------------------------
-- 5. Score (predict) and write results back into PostgreSQL
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS predictions.component_rul_predictions (
    prediction_id           BIGSERIAL PRIMARY KEY,
    record_id                BIGINT NOT NULL,
    component_serial_number   TEXT NOT NULL,
    snapshot_date              DATE NOT NULL,
    model_name                  TEXT NOT NULL,
    model_version                 TEXT NOT NULL,
    predicted_rul_days             NUMERIC(8,1),
    predicted_failure_prob_30d      NUMERIC(6,4),
    predicted_failure_prob_90d       NUMERIC(6,4),
    risk_tier                          TEXT CHECK (risk_tier IN ('Low','Watch','Elevated','High')),
    top_contributing_factors             JSONB,
    scored_at                             TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ix_predictions_component ON predictions.component_rul_predictions(component_serial_number, scored_at);
CREATE INDEX IF NOT EXISTS ix_predictions_risk_tier ON predictions.component_rul_predictions(risk_tier);
COMMENT ON TABLE predictions.component_rul_predictions IS 'Batch scoring output consumed by the Power BI decision-support layer. One row per component per scoring run.';

-- Batch scoring pattern using pgml.predict; risk_tier derived in-SQL from the
-- classification outputs so Power BI needs no business logic of its own.
INSERT INTO predictions.component_rul_predictions
    (record_id, component_serial_number, snapshot_date, model_name, model_version,
     predicted_rul_days, predicted_failure_prob_30d, predicted_failure_prob_90d, risk_tier)
SELECT
    t.record_id,
    t.component_serial_number,
    t.snapshot_date,
    'helios_component_rul_regression' AS model_name,
    'v1' AS model_version,
    pgml.predict('helios_component_rul_regression', ROW(t.*)) AS predicted_rul_days,
    pgml.predict('helios_component_failure_30d_classification', ROW(t.*)) AS predicted_failure_prob_30d,
    pgml.predict('helios_component_failure_90d_classification', ROW(t.*)) AS predicted_failure_prob_90d,
    CASE
        WHEN pgml.predict('helios_component_failure_30d_classification', ROW(t.*)) > 0.5 THEN 'High'
        WHEN pgml.predict('helios_component_failure_90d_classification', ROW(t.*)) > 0.5 THEN 'Elevated'
        WHEN pgml.predict('helios_component_failure_90d_classification', ROW(t.*)) > 0.2 THEN 'Watch'
        ELSE 'Low'
    END AS risk_tier
FROM features.component_health_test t;

-- NOTE: the ROW(t.*) call pattern above is illustrative of the PostgresML API
-- shape; exact syntax varies by PostgresML version — confirm against the
-- extension version installed (pgml.predict may expect an explicit feature
-- array rather than a row type). Validate with a LIMIT 10 run before scoring
-- the full table.
