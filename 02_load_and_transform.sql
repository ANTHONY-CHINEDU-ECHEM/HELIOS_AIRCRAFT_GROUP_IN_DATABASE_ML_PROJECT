-- =============================================================================
-- SCRIPT 02 of 04: Load the source extract and promote raw -> curated
--
-- Prerequisite: 01_schema_and_tables.sql has been executed.
-- Prerequisite: Helios_Component_Health_Dataset.xlsx has been exported to CSV
--               (Component_Health_Dataset sheet -> component_health_dataset.csv)
--               and is reachable from the machine running psql.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Load the flat extract into the raw landing table
-- -----------------------------------------------------------------------------
-- NOTE: adjust the path to wherever you exported the CSV. \copy runs client-side
-- so it works even when psql is not on the same host as the PostgreSQL server;
-- swap to server-side COPY only if the file already lives on the DB server.

TRUNCATE TABLE raw.component_health_stg;

\copy raw.component_health_stg (record_id, snapshot_date, aircraft_tail_number, aircraft_model, fleet_type, aircraft_age_years, operating_region, operating_environment, route_type, avg_daily_utilization_hours, component_serial_number, component_type, component_subtype, component_manufacturer, part_number, part_cost_usd, installation_date, design_mtbf_hours, cumulative_flight_hours, cumulative_flight_cycles, flight_hours_since_last_overhaul, flight_cycles_since_last_overhaul, flight_hours_since_last_removal, prior_removal_count, prior_unscheduled_removal_count, days_since_last_maintenance_event, last_maintenance_type, maintenance_events_last_12_months, inspection_finding_severity, inspection_technician_id, work_order_number, sensor_vibration_index, sensor_temperature_avg_c, sensor_pressure_avg_psi, sensor_oil_debris_index, health_monitoring_score, anomaly_count_last_30_days, ambient_temperature_avg_c, humidity_avg_pct, corrosion_risk_index, supplier_id, supplier_quality_score, warranty_status, firmware_version, data_quality_flag, remaining_useful_life_days, failure_within_30_days, failure_within_90_days, record_created_timestamp) FROM 'component_health_dataset.csv' WITH (FORMAT csv, HEADER true, NULL '');

-- -----------------------------------------------------------------------------
-- 2. Run the data-quality gate. Critical failures route to quarantine and the
--    promotion step below is skipped for those rows (Referential Integrity /
--    Consistency issues are isolated rather than failing the whole batch).
-- -----------------------------------------------------------------------------

SELECT mgmt.run_data_quality_checks('raw.component_health_stg') AS all_critical_rules_passed;

-- Review results:
--   SELECT r.rule_name, res.rows_checked, res.rows_failed, res.pass_rate_pct, res.severity
--   FROM monitoring.data_quality_results res
--   JOIN monitoring.data_quality_rules r USING (rule_id)
--   WHERE res.run_at = (SELECT MAX(run_at) FROM monitoring.data_quality_results)
--   ORDER BY res.passed, r.severity DESC;

INSERT INTO raw.component_health_quarantine
SELECT s.*, 'duplicate_record_id', now()
FROM raw.component_health_stg s
WHERE s.record_id IN (
    SELECT record_id FROM raw.component_health_stg GROUP BY record_id HAVING COUNT(*) > 1
);

DELETE FROM raw.component_health_stg
WHERE record_id IN (SELECT record_id FROM raw.component_health_quarantine);

-- -----------------------------------------------------------------------------
-- 3. Upsert master data (dimensions) BEFORE the fact table, so foreign keys
--    on curated.fact_component_health_snapshot always resolve.
-- -----------------------------------------------------------------------------

INSERT INTO curated.dim_supplier (supplier_id, supplier_quality_score)
SELECT DISTINCT supplier_id, supplier_quality_score
FROM raw.component_health_stg
WHERE supplier_id IS NOT NULL
ON CONFLICT (supplier_id) DO UPDATE
    SET supplier_quality_score = EXCLUDED.supplier_quality_score;

INSERT INTO curated.dim_aircraft (
    aircraft_tail_number, aircraft_model, fleet_type, aircraft_age_years,
    operating_region, operating_environment, route_type, avg_daily_utilization_hours
)
SELECT DISTINCT ON (aircraft_tail_number)
    aircraft_tail_number, aircraft_model, fleet_type, aircraft_age_years,
    operating_region, operating_environment, route_type, avg_daily_utilization_hours
FROM raw.component_health_stg
ORDER BY aircraft_tail_number, record_id DESC
ON CONFLICT (aircraft_tail_number) DO UPDATE
    SET aircraft_model = EXCLUDED.aircraft_model,
        fleet_type = EXCLUDED.fleet_type,
        aircraft_age_years = EXCLUDED.aircraft_age_years,
        operating_region = EXCLUDED.operating_region,
        operating_environment = EXCLUDED.operating_environment,
        route_type = EXCLUDED.route_type,
        avg_daily_utilization_hours = EXCLUDED.avg_daily_utilization_hours;

INSERT INTO curated.dim_component (
    component_serial_number, component_type, component_subtype, component_manufacturer,
    part_number, part_cost_usd, installation_date, design_mtbf_hours, supplier_id,
    warranty_status, firmware_version
)
SELECT DISTINCT ON (component_serial_number)
    component_serial_number, component_type, component_subtype, component_manufacturer,
    part_number, part_cost_usd, installation_date, design_mtbf_hours, supplier_id,
    warranty_status, NULLIF(firmware_version, 'N/A - Non-Electronic')
FROM raw.component_health_stg
ORDER BY component_serial_number, record_id DESC
ON CONFLICT (component_serial_number) DO UPDATE
    SET component_type = EXCLUDED.component_type,
        component_subtype = EXCLUDED.component_subtype,
        component_manufacturer = EXCLUDED.component_manufacturer,
        part_number = EXCLUDED.part_number,
        part_cost_usd = EXCLUDED.part_cost_usd,
        design_mtbf_hours = EXCLUDED.design_mtbf_hours,
        supplier_id = EXCLUDED.supplier_id,
        warranty_status = EXCLUDED.warranty_status,
        firmware_version = EXCLUDED.firmware_version;

-- -----------------------------------------------------------------------------
-- 4. Promote to the curated fact table (idempotent re-run via ON CONFLICT)
-- -----------------------------------------------------------------------------

INSERT INTO curated.fact_component_health_snapshot (
    record_id, snapshot_date, aircraft_tail_number, component_serial_number,
    cumulative_flight_hours, cumulative_flight_cycles, flight_hours_since_last_overhaul,
    flight_cycles_since_last_overhaul, flight_hours_since_last_removal,
    prior_removal_count, prior_unscheduled_removal_count, days_since_last_maintenance_event,
    last_maintenance_type, maintenance_events_last_12_months, inspection_finding_severity,
    inspection_technician_id, work_order_number, sensor_vibration_index,
    sensor_temperature_avg_c, sensor_pressure_avg_psi, sensor_oil_debris_index,
    health_monitoring_score, anomaly_count_last_30_days, ambient_temperature_avg_c,
    humidity_avg_pct, corrosion_risk_index, data_quality_flag,
    remaining_useful_life_days, failure_within_30_days, failure_within_90_days,
    record_created_timestamp
)
SELECT
    record_id, snapshot_date, aircraft_tail_number, component_serial_number,
    cumulative_flight_hours, cumulative_flight_cycles, flight_hours_since_last_overhaul,
    flight_cycles_since_last_overhaul, flight_hours_since_last_removal,
    prior_removal_count, prior_unscheduled_removal_count, days_since_last_maintenance_event,
    last_maintenance_type, maintenance_events_last_12_months, inspection_finding_severity,
    inspection_technician_id, work_order_number, sensor_vibration_index,
    sensor_temperature_avg_c, sensor_pressure_avg_psi, sensor_oil_debris_index,
    health_monitoring_score, anomaly_count_last_30_days, ambient_temperature_avg_c,
    humidity_avg_pct, corrosion_risk_index, COALESCE(data_quality_flag, 'Complete'),
    remaining_useful_life_days, failure_within_30_days, failure_within_90_days,
    record_created_timestamp
FROM raw.component_health_stg
ON CONFLICT (record_id, snapshot_date) DO UPDATE SET
    cumulative_flight_hours = EXCLUDED.cumulative_flight_hours,
    health_monitoring_score = EXCLUDED.health_monitoring_score,
    remaining_useful_life_days = EXCLUDED.remaining_useful_life_days,
    failure_within_30_days = EXCLUDED.failure_within_30_days,
    failure_within_90_days = EXCLUDED.failure_within_90_days,
    ingested_at = now();

-- -----------------------------------------------------------------------------
-- 5. Sanity checks
-- -----------------------------------------------------------------------------
SELECT 'dim_aircraft' AS tbl, COUNT(*) FROM curated.dim_aircraft
UNION ALL SELECT 'dim_component', COUNT(*) FROM curated.dim_component
UNION ALL SELECT 'dim_supplier', COUNT(*) FROM curated.dim_supplier
UNION ALL SELECT 'fact_component_health_snapshot', COUNT(*) FROM curated.fact_component_health_snapshot
UNION ALL SELECT 'quarantine', COUNT(*) FROM raw.component_health_quarantine;
