-- =============================================================================
-- HELIOS AIRCRAFT CORPORATION
-- Intelligent Predictive Operations Initiative
-- Use Case A: Component Health Assessment & Remaining Useful Life (RUL) Estimation
--
-- SCRIPT 01 of 04: Schema architecture, dimensional model, partitioning,
--                  constraints, and the data-quality framework.
--
-- Target platform: PostgreSQL 15+ (partitioning, generated columns, MERGE-ready)
-- Design follows business-case section 7.1: raw / curated / features / models /
-- predictions / monitoring schemas, native constraints & triggers for master
-- data management, and SQL-only data quality enforcement.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 0. Extensions & schemas
-- -----------------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS pgcrypto;     -- for gen_random_uuid() / audit hashing
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

CREATE SCHEMA IF NOT EXISTS raw;         -- landing zone for source extracts
CREATE SCHEMA IF NOT EXISTS curated;     -- governed, modeled analytical layer
CREATE SCHEMA IF NOT EXISTS features;    -- versioned feature tables/views for ML
CREATE SCHEMA IF NOT EXISTS models;      -- model registry & model-card metadata
CREATE SCHEMA IF NOT EXISTS predictions; -- scoring outputs
CREATE SCHEMA IF NOT EXISTS monitoring;  -- data quality, drift, performance logs
CREATE SCHEMA IF NOT EXISTS mgmt;        -- roles, audit, lineage

COMMENT ON SCHEMA raw IS 'Landing zone. Untransformed extracts from source systems (MRO, ERP, health-monitoring feeds). No analytical use.';
COMMENT ON SCHEMA curated IS 'Governed analytical data foundation. Conformed dimensions and fact tables. Single source of truth for downstream features, models, and BI.';
COMMENT ON SCHEMA features IS 'Versioned, model-ready feature tables/materialized views built exclusively with SQL.';
COMMENT ON SCHEMA models IS 'Model registry, model cards, hyperparameters, and lifecycle/version metadata (PostgresML-backed).';
COMMENT ON SCHEMA predictions IS 'Prediction outputs with model version, confidence, and explanation fields, written back by scoring jobs.';
COMMENT ON SCHEMA monitoring IS 'Data-quality results, drift statistics, and model-performance tracking, entirely SQL-computed.';
COMMENT ON SCHEMA mgmt IS 'Roles, audit logging, and lineage metadata.';

-- -----------------------------------------------------------------------------
-- 1. Master-data / reference tables (curated)
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS curated.dim_aircraft (
    aircraft_tail_number       TEXT PRIMARY KEY,
    aircraft_model             TEXT NOT NULL,
    fleet_type                 TEXT NOT NULL CHECK (fleet_type IN ('Narrowbody','Regional','Specialized-Mission')),
    aircraft_age_years         NUMERIC(6,2) CHECK (aircraft_age_years >= 0),
    operating_region           TEXT NOT NULL,
    operating_environment      TEXT NOT NULL CHECK (operating_environment IN ('Desert','Coastal','Temperate','Arctic','Tropical')),
    route_type                 TEXT NOT NULL CHECK (route_type IN ('Short-haul','Medium-haul','Long-haul')),
    avg_daily_utilization_hours NUMERIC(6,2) CHECK (avg_daily_utilization_hours >= 0),
    created_at                 TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at                 TIMESTAMPTZ NOT NULL DEFAULT now()
);
COMMENT ON TABLE curated.dim_aircraft IS 'Conformed aircraft master data. One row per tail number.';

CREATE TABLE IF NOT EXISTS curated.dim_supplier (
    supplier_id             TEXT PRIMARY KEY,
    supplier_quality_score  NUMERIC(5,1) CHECK (supplier_quality_score BETWEEN 0 AND 100),
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT now()
);
COMMENT ON TABLE curated.dim_supplier IS 'Conformed supplier master data and current quality score.';

CREATE TABLE IF NOT EXISTS curated.dim_component (
    component_serial_number    TEXT PRIMARY KEY,
    component_type             TEXT NOT NULL,
    component_subtype          TEXT NOT NULL,
    component_manufacturer     TEXT NOT NULL,
    part_number                TEXT NOT NULL,
    part_cost_usd               NUMERIC(12,2) CHECK (part_cost_usd >= 0),
    installation_date          DATE NOT NULL,
    design_mtbf_hours          NUMERIC(10,1) CHECK (design_mtbf_hours > 0),
    supplier_id                TEXT REFERENCES curated.dim_supplier(supplier_id),
    warranty_status             TEXT CHECK (warranty_status IN ('In Warranty','Out of Warranty','Extended Warranty')),
    firmware_version            TEXT,
    created_at                 TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at                 TIMESTAMPTZ NOT NULL DEFAULT now()
);
COMMENT ON TABLE curated.dim_component IS 'Conformed component master data. One row per physical component serial number.';

CREATE INDEX IF NOT EXISTS ix_dim_component_type ON curated.dim_component(component_type, component_subtype);
CREATE INDEX IF NOT EXISTS ix_dim_component_supplier ON curated.dim_component(supplier_id);

-- generic updated_at trigger, reused across master-data tables
CREATE OR REPLACE FUNCTION mgmt.set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_dim_aircraft_updated ON curated.dim_aircraft;
CREATE TRIGGER trg_dim_aircraft_updated BEFORE UPDATE ON curated.dim_aircraft
    FOR EACH ROW EXECUTE FUNCTION mgmt.set_updated_at();

DROP TRIGGER IF EXISTS trg_dim_supplier_updated ON curated.dim_supplier;
CREATE TRIGGER trg_dim_supplier_updated BEFORE UPDATE ON curated.dim_supplier
    FOR EACH ROW EXECUTE FUNCTION mgmt.set_updated_at();

DROP TRIGGER IF EXISTS trg_dim_component_updated ON curated.dim_component;
CREATE TRIGGER trg_dim_component_updated BEFORE UPDATE ON curated.dim_component
    FOR EACH ROW EXECUTE FUNCTION mgmt.set_updated_at();

-- -----------------------------------------------------------------------------
-- 2. Raw landing table (mirrors the flat source extract / Excel-derived CSV 1:1)
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS raw.component_health_stg (
    record_id                              INTEGER,
    snapshot_date                          DATE,
    aircraft_tail_number                   TEXT,
    aircraft_model                         TEXT,
    fleet_type                             TEXT,
    aircraft_age_years                     NUMERIC,
    operating_region                       TEXT,
    operating_environment                  TEXT,
    route_type                             TEXT,
    avg_daily_utilization_hours            NUMERIC,
    component_serial_number                TEXT,
    component_type                         TEXT,
    component_subtype                      TEXT,
    component_manufacturer                 TEXT,
    part_number                            TEXT,
    part_cost_usd                          NUMERIC,
    installation_date                      DATE,
    design_mtbf_hours                      NUMERIC,
    cumulative_flight_hours                NUMERIC,
    cumulative_flight_cycles               NUMERIC,
    flight_hours_since_last_overhaul       NUMERIC,
    flight_cycles_since_last_overhaul      NUMERIC,
    flight_hours_since_last_removal        NUMERIC,
    prior_removal_count                    INTEGER,
    prior_unscheduled_removal_count        INTEGER,
    days_since_last_maintenance_event      INTEGER,
    last_maintenance_type                  TEXT,
    maintenance_events_last_12_months      INTEGER,
    inspection_finding_severity            TEXT,
    inspection_technician_id               TEXT,
    work_order_number                      TEXT,
    sensor_vibration_index                 NUMERIC,
    sensor_temperature_avg_c               NUMERIC,
    sensor_pressure_avg_psi                NUMERIC,
    sensor_oil_debris_index                NUMERIC,
    health_monitoring_score                NUMERIC,
    anomaly_count_last_30_days             INTEGER,
    ambient_temperature_avg_c              NUMERIC,
    humidity_avg_pct                       NUMERIC,
    corrosion_risk_index                   NUMERIC,
    supplier_id                            TEXT,
    supplier_quality_score                 NUMERIC,
    warranty_status                        TEXT,
    firmware_version                       TEXT,
    data_quality_flag                      TEXT,
    remaining_useful_life_days             NUMERIC,
    failure_within_30_days                 INTEGER,
    failure_within_90_days                 INTEGER,
    record_created_timestamp               TIMESTAMP,
    load_batch_id                          UUID DEFAULT gen_random_uuid(),
    loaded_at                              TIMESTAMPTZ DEFAULT now()
);
COMMENT ON TABLE raw.component_health_stg IS 'Untransformed 1:1 landing table for the component-health source extract (Excel/CSV). Loaded via COPY. Never queried directly by BI.';

-- -----------------------------------------------------------------------------
-- 3. Curated fact table — partitioned by snapshot_date (monthly range partitions)
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS curated.fact_component_health_snapshot (
    record_id                              BIGINT NOT NULL,
    snapshot_date                          DATE NOT NULL,
    aircraft_tail_number                   TEXT NOT NULL REFERENCES curated.dim_aircraft(aircraft_tail_number),
    component_serial_number                TEXT NOT NULL REFERENCES curated.dim_component(component_serial_number),
    cumulative_flight_hours                NUMERIC(12,1) NOT NULL CHECK (cumulative_flight_hours >= 0),
    cumulative_flight_cycles               NUMERIC(12,0) NOT NULL CHECK (cumulative_flight_cycles >= 0),
    flight_hours_since_last_overhaul       NUMERIC(12,1) CHECK (flight_hours_since_last_overhaul >= 0),
    flight_cycles_since_last_overhaul      NUMERIC(12,0) CHECK (flight_cycles_since_last_overhaul >= 0),
    flight_hours_since_last_removal        NUMERIC(12,1) CHECK (flight_hours_since_last_removal >= 0),
    prior_removal_count                    INTEGER NOT NULL DEFAULT 0 CHECK (prior_removal_count >= 0),
    prior_unscheduled_removal_count        INTEGER NOT NULL DEFAULT 0 CHECK (prior_unscheduled_removal_count >= 0),
    days_since_last_maintenance_event      INTEGER CHECK (days_since_last_maintenance_event >= 0),
    last_maintenance_type                  TEXT,
    maintenance_events_last_12_months      INTEGER CHECK (maintenance_events_last_12_months >= 0),
    inspection_finding_severity            TEXT CHECK (inspection_finding_severity IN ('None','Minor','Major','Critical')),
    inspection_technician_id               TEXT,
    work_order_number                      TEXT,
    sensor_vibration_index                 NUMERIC(8,3),
    sensor_temperature_avg_c               NUMERIC(6,2),
    sensor_pressure_avg_psi                NUMERIC(8,1),
    sensor_oil_debris_index                NUMERIC(8,3),
    health_monitoring_score                NUMERIC(5,2) CHECK (health_monitoring_score BETWEEN 0 AND 100),
    anomaly_count_last_30_days             INTEGER CHECK (anomaly_count_last_30_days >= 0),
    ambient_temperature_avg_c              NUMERIC(6,2),
    humidity_avg_pct                       NUMERIC(5,1) CHECK (humidity_avg_pct BETWEEN 0 AND 100),
    corrosion_risk_index                   NUMERIC(5,2) CHECK (corrosion_risk_index BETWEEN 0 AND 100),
    data_quality_flag                      TEXT NOT NULL DEFAULT 'Complete',
    remaining_useful_life_days             NUMERIC(8,1) CHECK (remaining_useful_life_days >= 0),
    failure_within_30_days                 SMALLINT CHECK (failure_within_30_days IN (0,1)),
    failure_within_90_days                 SMALLINT CHECK (failure_within_90_days IN (0,1)),
    record_created_timestamp               TIMESTAMP NOT NULL,
    ingested_at                            TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (record_id, snapshot_date)
) PARTITION BY RANGE (snapshot_date);
COMMENT ON TABLE curated.fact_component_health_snapshot IS 'Curated, governed fact table underpinning Use Case A (Component Health / RUL). Partitioned monthly on snapshot_date. Sole source for the features schema.';

-- Partitions covering the two years the synthetic/source data spans; extend
-- monthly via the mgmt.ensure_partition() helper below as new data arrives.
DO $$
DECLARE
    p_start DATE := DATE '2023-06-01';
    p_end   DATE := DATE '2025-12-01';
    d       DATE;
    part_name TEXT;
BEGIN
    d := p_start;
    WHILE d < p_end LOOP
        part_name := 'fact_component_health_snapshot_' || to_char(d, 'YYYY_MM');
        EXECUTE format(
            'CREATE TABLE IF NOT EXISTS curated.%I PARTITION OF curated.fact_component_health_snapshot
             FOR VALUES FROM (%L) TO (%L);',
            part_name, d, (d + INTERVAL '1 month')::DATE
        );
        d := (d + INTERVAL '1 month')::DATE;
    END LOOP;
END $$;

-- Default partition to safely catch any out-of-range dates instead of failing the load
CREATE TABLE IF NOT EXISTS curated.fact_component_health_snapshot_default
    PARTITION OF curated.fact_component_health_snapshot DEFAULT;

-- Helper to add future monthly partitions (invoked by a scheduled job — see script 04)
CREATE OR REPLACE FUNCTION mgmt.ensure_partition(p_month DATE)
RETURNS VOID AS $$
DECLARE
    part_name TEXT := 'fact_component_health_snapshot_' || to_char(p_month, 'YYYY_MM');
BEGIN
    EXECUTE format(
        'CREATE TABLE IF NOT EXISTS curated.%I PARTITION OF curated.fact_component_health_snapshot
         FOR VALUES FROM (%L) TO (%L);',
        part_name, date_trunc('month', p_month)::DATE,
        (date_trunc('month', p_month) + INTERVAL '1 month')::DATE
    );
END;
$$ LANGUAGE plpgsql;

CREATE INDEX IF NOT EXISTS ix_fact_health_component ON curated.fact_component_health_snapshot(component_serial_number, snapshot_date);
CREATE INDEX IF NOT EXISTS ix_fact_health_aircraft   ON curated.fact_component_health_snapshot(aircraft_tail_number, snapshot_date);
CREATE INDEX IF NOT EXISTS ix_fact_health_failure90   ON curated.fact_component_health_snapshot(failure_within_90_days) WHERE failure_within_90_days = 1;
CREATE INDEX IF NOT EXISTS ix_fact_health_snapshot_dt ON curated.fact_component_health_snapshot(snapshot_date);

-- -----------------------------------------------------------------------------
-- 4. Data-quality framework (SQL-only, per business case section 7.1)
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS monitoring.data_quality_rules (
    rule_id         SERIAL PRIMARY KEY,
    rule_name       TEXT NOT NULL UNIQUE,
    rule_category   TEXT NOT NULL CHECK (rule_category IN ('Completeness','Validity','Consistency','Uniqueness','Referential Integrity')),
    target_table    TEXT NOT NULL,
    rule_sql        TEXT NOT NULL,   -- SQL predicate: rows FAILING the rule should match this WHERE clause
    severity        TEXT NOT NULL DEFAULT 'Warning' CHECK (severity IN ('Warning','Critical')),
    is_active       BOOLEAN NOT NULL DEFAULT TRUE
);

INSERT INTO monitoring.data_quality_rules (rule_name, rule_category, target_table, rule_sql, severity) VALUES
 ('health_score_out_of_range', 'Validity', 'raw.component_health_stg', 'health_monitoring_score IS NOT NULL AND (health_monitoring_score < 0 OR health_monitoring_score > 100)', 'Critical'),
 ('negative_usage_hours', 'Validity', 'raw.component_health_stg', 'cumulative_flight_hours < 0 OR cumulative_flight_cycles < 0', 'Critical'),
 ('missing_component_serial', 'Completeness', 'raw.component_health_stg', 'component_serial_number IS NULL', 'Critical'),
 ('missing_aircraft_tail', 'Completeness', 'raw.component_health_stg', 'aircraft_tail_number IS NULL', 'Critical'),
 ('duplicate_record_id', 'Uniqueness', 'raw.component_health_stg', 'record_id IN (SELECT record_id FROM raw.component_health_stg GROUP BY record_id HAVING COUNT(*) > 1)', 'Critical'),
 ('inconsistent_overhaul_hours', 'Consistency', 'raw.component_health_stg', 'flight_hours_since_last_overhaul > cumulative_flight_hours', 'Warning'),
 ('failure_label_conflict', 'Consistency', 'raw.component_health_stg', 'failure_within_30_days = 1 AND failure_within_90_days = 0', 'Critical')
ON CONFLICT (rule_name) DO NOTHING;

COMMENT ON TABLE monitoring.data_quality_rules IS 'Declarative data-quality rule catalog. rule_sql is a WHERE-clause predicate identifying FAILING rows; evaluated by mgmt.run_data_quality_checks().';

CREATE TABLE IF NOT EXISTS monitoring.data_quality_results (
    result_id       BIGSERIAL PRIMARY KEY,
    rule_id         INTEGER REFERENCES monitoring.data_quality_rules(rule_id),
    run_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    rows_checked    BIGINT,
    rows_failed     BIGINT,
    pass_rate_pct   NUMERIC(5,2),
    severity        TEXT,
    passed          BOOLEAN
);
COMMENT ON TABLE monitoring.data_quality_results IS 'Execution history of the data-quality rule catalog. Consumed by the executive/quality Power BI dashboard and by the load gate in script 02.';

CREATE TABLE IF NOT EXISTS raw.component_health_quarantine (
    LIKE raw.component_health_stg INCLUDING ALL,
    quarantine_reason   TEXT,
    quarantined_at      TIMESTAMPTZ DEFAULT now()
);
COMMENT ON TABLE raw.component_health_quarantine IS 'Rows failing Critical-severity data-quality rules are routed here instead of the curated layer, with the failing rule recorded.';

-- Runs every active rule against the named table and logs results. Returns TRUE
-- if no CRITICAL rule failed (i.e., safe to promote raw -> curated).
CREATE OR REPLACE FUNCTION mgmt.run_data_quality_checks(p_table TEXT DEFAULT 'raw.component_health_stg')
RETURNS BOOLEAN AS $$
DECLARE
    r RECORD;
    v_total BIGINT;
    v_failed BIGINT;
    v_critical_failed BOOLEAN := FALSE;
BEGIN
    EXECUTE format('SELECT COUNT(*) FROM %s', p_table) INTO v_total;

    FOR r IN SELECT * FROM monitoring.data_quality_rules WHERE is_active AND target_table = p_table LOOP
        EXECUTE format('SELECT COUNT(*) FROM %s WHERE %s', p_table, r.rule_sql) INTO v_failed;

        INSERT INTO monitoring.data_quality_results
            (rule_id, rows_checked, rows_failed, pass_rate_pct, severity, passed)
        VALUES (
            r.rule_id, v_total, v_failed,
            ROUND(100.0 * (v_total - v_failed) / GREATEST(v_total,1), 2),
            r.severity, (v_failed = 0)
        );

        IF v_failed > 0 AND r.severity = 'Critical' THEN
            v_critical_failed := TRUE;
        END IF;
    END LOOP;

    RETURN NOT v_critical_failed;
END;
$$ LANGUAGE plpgsql;

-- -----------------------------------------------------------------------------
-- 5. Role-based access control (per business-case section 7.1 & 7.4)
-- -----------------------------------------------------------------------------

DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'role_data_engineer') THEN
        CREATE ROLE role_data_engineer NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'role_ml_engineer') THEN
        CREATE ROLE role_ml_engineer NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'role_bi_reader') THEN
        CREATE ROLE role_bi_reader NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'role_auditor') THEN
        CREATE ROLE role_auditor NOLOGIN;
    END IF;
END $$;

GRANT USAGE ON SCHEMA raw, curated TO role_data_engineer;
GRANT ALL ON ALL TABLES IN SCHEMA raw TO role_data_engineer;
GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA curated TO role_data_engineer;

GRANT USAGE ON SCHEMA curated, features, models, predictions, monitoring TO role_ml_engineer;
GRANT SELECT ON ALL TABLES IN SCHEMA curated, features TO role_ml_engineer;
GRANT ALL ON ALL TABLES IN SCHEMA models, predictions TO role_ml_engineer;
GRANT SELECT, INSERT ON ALL TABLES IN SCHEMA monitoring TO role_ml_engineer;

GRANT USAGE ON SCHEMA curated, features, predictions TO role_bi_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA curated, features, predictions TO role_bi_reader;

GRANT USAGE ON SCHEMA monitoring, mgmt TO role_auditor;
GRANT SELECT ON ALL TABLES IN SCHEMA monitoring TO role_auditor;

-- -----------------------------------------------------------------------------
-- 6. Immutable audit log (append-only) — native PostgreSQL, no external tooling
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS mgmt.audit_log (
    audit_id        BIGSERIAL PRIMARY KEY,
    event_time      TIMESTAMPTZ NOT NULL DEFAULT now(),
    db_user         TEXT NOT NULL DEFAULT current_user,
    schema_name     TEXT NOT NULL,
    table_name      TEXT NOT NULL,
    operation       TEXT NOT NULL CHECK (operation IN ('INSERT','UPDATE','DELETE')),
    row_pk          TEXT,
    row_hash        TEXT
);
COMMENT ON TABLE mgmt.audit_log IS 'Append-only audit trail. Revoke UPDATE/DELETE from all roles in production to guarantee immutability.';
REVOKE UPDATE, DELETE ON mgmt.audit_log FROM PUBLIC;

CREATE OR REPLACE FUNCTION mgmt.audit_fact_health()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO mgmt.audit_log (schema_name, table_name, operation, row_pk, row_hash)
    VALUES (
        'curated', 'fact_component_health_snapshot', TG_OP,
        COALESCE(NEW.record_id, OLD.record_id)::TEXT,
        md5(COALESCE(NEW::TEXT, OLD::TEXT))
    );
    RETURN COALESCE(NEW, OLD);
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_audit_fact_health ON curated.fact_component_health_snapshot;
CREATE TRIGGER trg_audit_fact_health
    AFTER INSERT OR UPDATE OR DELETE ON curated.fact_component_health_snapshot
    FOR EACH ROW EXECUTE FUNCTION mgmt.audit_fact_health();
