# HELIOS Aircraft Corporation | Intelligent Predictive Operations Initiative

## Executive Summary

**HELIOS** is an enterprise-grade, SQL-native machine learning platform designed to transform component health monitoring and maintenance planning across commercial aviation fleets. By combining PostgreSQL's advanced analytical capabilities, in-database machine learning, and comprehensive data governance, this system enables **predictive maintenance scheduling, risk-stratified component retirement, and supply-chain optimization** — delivering measurable operational savings and enhanced safety outcomes.

### Business Impact

- **Predictive Maintenance Windows**: Replace reactive maintenance with data-driven forecasting of component failures within 30, 60, and 90-day horizons
- **Asset Utilization Optimization**: Maximize flight hours per component before planned removal, reducing unscheduled downtime by an estimated **15–25%**
- **Supply Chain Efficiency**: Align parts procurement and inventory to predicted demand, reducing carrying costs and stockouts
- **Safety & Compliance**: Automated data quality enforcement and immutable audit trails satisfy regulatory (14 CFR, EASA) and internal compliance requirements
- **Decision Support**: Risk-stratified component rankings and explanatory feature importance for maintenance teams and flight operations

---

## Architecture Overview

### System Design Philosophy

The HELIOS platform follows a **modular, SQL-first architecture** that maximizes PostgreSQL's analytical and ML capabilities:

1. **Landing Zone** (`raw` schema): Untransformed source extracts from MRO, ERP, and health-monitoring systems
2. **Curated Foundation** (`curated` schema): Conformed, governed dimensional and fact tables with automated data quality gates
3. **Feature Engineering** (`features` schema): Versioned, model-ready datasets built entirely with SQL window functions and domain-driven ratios
4. **Model Registry & Lifecycle** (`models` schema): Structured model cards, hyperparameters, and performance metadata
5. **Prediction & Scoring** (`predictions` schema): Batch scoring output with risk tiers and contributing factors for BI consumption
6. **Monitoring & Observability** (`monitoring` schema): Drift detection, performance tracking, and alerting — all SQL-computed

### Technical Stack

- **Language**: PLpgSQL (PostgreSQL 15+)
- **Core Platform**: PostgreSQL with table partitioning, native triggers, and ROLE-based access control
- **ML Runtime**: PostgresML (in-database gradient-boosted trees via XGBoost)
- **Scheduling**: pg_cron for automated feature refresh, drift checks, and retraining triggers
- **Data Quality**: Declarative rule engine with quarantine routing and compliance logging

### Entity-Relationship Design

```
dim_aircraft (one per tail number)
  └─ fact_component_health_snapshot (time-series, partitioned monthly)
       ├─ dim_component (one per serial number)
       │   └─ dim_supplier (one per supplier ID)
       └─ [joins to features & models for inference]
```

---

## Data Pipeline & Workflow

### Phase 1: Data Ingestion & Quality Assurance (Script 01 & 02)

**`01_schema_and_tables.sql`** — Initialize the data warehouse:

- **Schemas**: Establish 7 purpose-built schemas with granular data governance
- **Dimensions**: Master data for aircraft (tail numbers, fleet composition), components (serial numbers, design MTBF), and suppliers
- **Fact Table**: Partitioned monthly fact table tracking component health snapshots across the fleet
- **Data Quality Framework**: Declarative rule catalog with 7 built-in checks (completeness, validity, uniqueness, consistency, referential integrity)
- **Role-Based Access Control**: Four roles (data engineer, ML engineer, BI reader, auditor) with schema-level and table-level permissions
- **Audit Trail**: Immutable, append-only audit log for all mutations to the fact table

**`02_load_and_transform.sql`** — Transform and govern the source extract:

- **CSV Ingestion**: Load from the source Excel/CSV export into the raw staging table
- **Quality Gate**: Execute all 7 DQ rules; failures route to quarantine; pass-rate metrics logged for dashboards
- **Master Data Upsert**: Idempotent inserts/updates for aircraft, components, and suppliers (CONFLICT clauses allow re-runs)
- **Fact Table Promotion**: Transform raw into curated fact table with foreign key references to dimensions
- **Sanity Checks**: Count verifications by table to confirm load completeness

**Key Mechanisms**:
- Temporal partitioning (monthly ranges) for efficient queries and archive/retention
- Quarantine table isolates data quality failures without blocking downstream processing
- Triggers auto-update `updated_at` timestamps on dimension tables

### Phase 2: Feature Engineering & Model Training (Script 03)

**`03_features_and_ml.sql`** — Build ML-ready datasets and train ensemble models:

**Feature Engineering** (SQL window functions, domain-driven ratios):

| Feature | Derivation | Business Meaning |
|---------|-----------|-----------------|
| `pct_of_design_life_consumed` | cumulative_flight_hours / design_mtbf_hours | Lifecycle progression as % of rated MTBF |
| `hours_per_cycle` | cumulative_flight_hours / cumulative_flight_cycles | Mechanical stress intensity per flight |
| `unscheduled_removal_ratio` | prior_unscheduled / prior_removal_count | Reliability indicator (higher → more unexpected failures) |
| `sensor_composite_risk_score` | 0.40×vibration + 0.35×oil_debris + 0.25×anomalies | Weighted health sensor fusion |
| `maintenance_recency_score` | exp(−days_since_maintenance/90) | Exponential decay of maintenance benefit |
| `rolling_30d_component_type_failure_rate` | Window avg of failure_within_90_days by component_type | Cohort-level risk trend |

**Three Production Models** (trained via PostgresML XGBoost):

1. **RUL Regression** (`helios_component_rul_regression`): Predict remaining useful life in days
   - Algorithm: XGBoost (n_estimators=300, max_depth=6, learning_rate=0.05)
   - Target: `remaining_useful_life_days`
   - Use Case: Optimize maintenance scheduling windows
   
2. **90-Day Failure Classifier** (`helios_component_failure_90d_classification`): Probability of failure within 90 days
   - Algorithm: XGBoost (n_estimators=300, max_depth=5)
   - Target: `failure_within_90_days` (binary label)
   - Use Case: Proactive inspection planning
   - Handling: Class imbalance (~9% positive rate); recommend recall-tuned thresholds
   
3. **30-Day Failure Classifier** (`helios_component_failure_30d_classification`): Urgent near-term risk
   - Algorithm: XGBoost (n_estimators=250, max_depth=5)
   - Target: `failure_within_30_days` (binary label)
   - Use Case: Immediate triage and parts pre-positioning
   - Handling: Severe class imbalance (~4% positive rate)

**Train/Validation/Test Split** (Temporal):

- **Train**: All records before MAX(snapshot_date) − 120 days
- **Validation**: Records 120 to 60 days before present
- **Test**: Records within last 60 days
- Rationale: Preserves temporal order; validates out-of-sample performance on recent, unseen data

**Model Registry** (Structured metadata):

Each trained model is registered with:
- Hyperparameters, training data summary (row counts)
- Intended use, known limitations, risk classification
- is_active flag for production eligibility
- Trained_at timestamp and trained_by user attribution

### Phase 3: Scoring & Decision Support (Script 03 Continued)

**Batch Prediction Loop**:

```sql
INSERT INTO predictions.component_rul_predictions
  (record_id, component_serial_number, snapshot_date, model_name, model_version,
   predicted_rul_days, predicted_failure_prob_30d, predicted_failure_prob_90d, risk_tier)
SELECT <features> FROM features.component_health_test t
  WHERE pgml.predict('helios_component_rul_regression', ROW(t.*)) → predicted_rul_days
```

**Risk Tier Logic** (Deterministic in SQL):

```
IF predicted_failure_prob_30d > 0.5  → "High"
ELSE IF predicted_failure_prob_90d > 0.5 → "Elevated"
ELSE IF predicted_failure_prob_90d > 0.2 → "Watch"
ELSE → "Low"
```

**Output Fields**:

- `predicted_rul_days`: Point estimate for maintenance scheduling
- `predicted_failure_prob_30d`, `predicted_failure_prob_90d`: Risk probabilities
- `risk_tier`: Actionable category for dispatch/fleet planning
- `top_contributing_factors`: JSONB-serialized feature importance (Shapley values in extended versions)

### Phase 4: Monitoring, Drift Detection, & Retraining (Script 04)

**`04_monitoring_and_retraining.sql`** — Sustain model accuracy and data quality:

**Model Performance Tracking**:

- **RUL Metrics**: RMSE and MAE against known outcomes in the test set
- **Classifier Metrics**: Precision and Recall @ 0.5 threshold decision boundary
- **Alert Thresholds**:
  - RMSE > 150 days → Warning
  - Recall < 0.60 → Critical (schedule retraining review)
- **Evaluation Window**: Configurable date ranges per model

**Data Drift Detection** (mean-shift test on key features):

Features monitored: `health_monitoring_score`, `sensor_vibration_index`, `sensor_oil_debris_index`, `anomaly_count_last_30_days`

```sql
-- Reference: 90+ days before present
-- Current: Last 30 days
-- Drift Threshold: >15% change triggers alert
```

**Automated Alerting**:

- Alert types: Data Quality, Data Drift, Model Performance, Prediction Volume
- Severity levels: Info, Warning, Critical
- Consumption: Power BI dashboards (executive risk dashboard, reliability-engineering dashboard)
- Human review override: Captured in `models.human_review_overrides` table for feedback loops

**Scheduled Jobs** (via pg_cron):

| Job | Frequency | Action |
|-----|-----------|--------|
| Feature Refresh | Nightly 02:00 UTC | Rebuild component_health_features_v1 from raw + curated data |
| Drift Check | Nightly 02:15 UTC | Run feature distribution tests; log alerts if >15% shift |
| Model Eval | Weekly (Monday 03:00) | Compute RMSE/MAE/Precision/Recall; log to monitoring tables |
| Partition Ensure | Monthly (1st @ 00:00) | Create next month's fact-table partition proactively |

**Retraining Trigger Logic**:

```sql
SELECT model_name, reason FROM mgmt.retraining_required()
-- Returns any model with unacknowledged warnings/critical alerts raised in last 7 days
```

---

## Data Dictionary

### Key Dimensions

#### `curated.dim_aircraft`

| Column | Type | Constraint | Semantics |
|--------|------|-----------|-----------|
| aircraft_tail_number | TEXT | PK | ICAO registration (e.g., N12345) |
| aircraft_model | TEXT | NOT NULL | Airbus/Boeing model (A320, 787, etc.) |
| fleet_type | TEXT | NOT NULL | Narrowbody, Regional, or Specialized-Mission |
| aircraft_age_years | NUMERIC(6,2) | ≥ 0 | Years since manufacture |
| operating_region | TEXT | NOT NULL | Geographic base (e.g., North America, Europe) |
| operating_environment | TEXT | NOT NULL | Desert, Coastal, Temperate, Arctic, Tropical |
| route_type | TEXT | NOT NULL | Short-, Medium-, Long-haul |
| avg_daily_utilization_hours | NUMERIC(6,2) | ≥ 0 | Typical daily flight hours |

#### `curated.dim_component`

| Column | Type | Constraint | Semantics |
|--------|------|-----------|-----------|
| component_serial_number | TEXT | PK | Manufacturer serial number |
| component_type | TEXT | NOT NULL | Engine, APU, Hydraulic, Avionics, Structural, etc. |
| component_subtype | TEXT | NOT NULL | More specific category (e.g., CF6 Engine) |
| design_mtbf_hours | NUMERIC(10,1) | > 0 | Mean time between failures per spec sheet |
| part_cost_usd | NUMERIC(12,2) | ≥ 0 | Acquisition cost (for ROI calculations) |
| warranty_status | TEXT | In Warranty, Out of Warranty, Extended | Coverage classification |
| firmware_version | TEXT | Nullable | For electronic components |

#### `curated.dim_supplier`

| Column | Type | Constraint | Semantics |
|--------|------|-----------|-----------|
| supplier_id | TEXT | PK | Supplier identifier |
| supplier_quality_score | NUMERIC(5,1) | [0, 100] | Current quality rating (internal or OEM) |

### Key Fact Table

#### `curated.fact_component_health_snapshot`

**Partitioning**: RANGE on `snapshot_date` (monthly), e.g., `fact_component_health_snapshot_2023_06`, `fact_component_health_snapshot_2023_07`, …

| Column | Type | Semantics |
|--------|------|-----------|
| record_id, snapshot_date | PK | Composite key; snapshot_date determines partition |
| aircraft_tail_number, component_serial_number | FK | Links to dimensions |
| cumulative_flight_hours, cumulative_flight_cycles | Integer | Total usage since installation |
| flight_hours_since_last_overhaul | Integer | Stress accumulation since major service |
| prior_removal_count, prior_unscheduled_removal_count | Integer | Reliability history |
| sensor_vibration_index, sensor_temperature_avg_c, sensor_pressure_avg_psi, sensor_oil_debris_index | NUMERIC | Health sensor telemetry (raw) |
| health_monitoring_score | NUMERIC [0, 100] | Composite health index |
| anomaly_count_last_30_days | Integer | Number of sensor anomalies detected |
| remaining_useful_life_days | NUMERIC | Known outcome (ground truth for training) |
| failure_within_30_days, failure_within_90_days | SMALLINT (0/1) | Binary label (ground truth) |

### Feature Engineering Table

#### `features.component_health_features_v1`

**Purpose**: Model-ready dataset; one row per component per snapshot_date. Rebuilt nightly by `features.build_component_health_features_v1()`.

**Includes**:
- All raw fact-table columns
- Engineered features (pct_of_design_life_consumed, hours_per_cycle, sensor_composite_risk_score, etc.)
- Labels (remaining_useful_life_days, failure_within_30_days, failure_within_90_days)
- feature_version, computed_at timestamp

### Predictions & Monitoring Tables

#### `predictions.component_rul_predictions`

| Column | Semantics |
|--------|-----------|
| prediction_id | Unique prediction record |
| record_id, component_serial_number, snapshot_date | Joinable to features for evaluation |
| predicted_rul_days | Point estimate in days |
| predicted_failure_prob_30d, predicted_failure_prob_90d | Probability scores [0, 1] |
| risk_tier | Categorical: Low, Watch, Elevated, High |
| scored_at | Timestamp of scoring run |

#### `monitoring.data_quality_rules`

| Column | Semantics |
|--------|-----------|
| rule_name | e.g., "health_score_out_of_range", "negative_usage_hours" |
| rule_category | Completeness, Validity, Consistency, Uniqueness, Referential Integrity |
| rule_sql | WHERE clause identifying failing rows |
| severity | Warning or Critical (Critical blocks promotion to curated) |

#### `monitoring.model_performance_log`

| Column | Semantics |
|--------|-----------|
| model_name, model_version | References models.model_registry |
| metric_name | RMSE, MAE, AUC, F1, Precision, Recall |
| metric_value | Numeric score |
| evaluation_window_start, evaluation_window_end | Date range for metric |

#### `monitoring.alerts`

| Column | Semantics |
|--------|-----------|
| alert_type | Data Quality, Data Drift, Model Performance, Prediction Volume |
| severity | Info, Warning, Critical |
| related_entity | Component ID, feature name, model name, etc. |
| acknowledged, acknowledged_by, acknowledged_at | Human review loop |

---

## Setup & Deployment

### Prerequisites

1. **PostgreSQL 15+** with superuser access for extension installation
   
   ```bash
   SELECT version();  -- Confirm PostgreSQL 15+
   ```

2. **Required Extensions**:
   
   ```sql
   CREATE EXTENSION IF NOT EXISTS pgcrypto;           -- gen_random_uuid(), hashing
   CREATE EXTENSION IF NOT EXISTS pg_stat_statements; -- Query performance analysis
   CREATE EXTENSION IF NOT EXISTS pgml;               -- PostgresML (in-database ML)
   CREATE EXTENSION IF NOT EXISTS pg_cron;            -- Scheduled jobs
   ```

3. **Source Data**: 
   - `Helios_Component_Health_Dataset.xlsx` exported to `component_health_dataset.csv`
   - File must be accessible from the machine running psql (client-side \copy)

### Installation Steps

#### Step 1: Initialize Schema & Data Model (Script 01)

```bash
psql -h <postgres_host> -U <admin_user> -d <database> -f 01_schema_and_tables.sql
```

**Output**: 7 schemas, 9 tables, 3 roles, audit triggers, data quality rules

#### Step 2: Load & Transform Data (Script 02)

```bash
# Adjust the file path in script if needed (line 19: \copy command)
psql -h <postgres_host> -U <admin_user> -d <database> -f 02_load_and_transform.sql
```

**Output**:
- raw.component_health_stg: Raw extract
- curated.dim_aircraft, dim_component, dim_supplier: Master data
- curated.fact_component_health_snapshot: Curated fact table (partitioned)
- monitoring.data_quality_results: QC execution log
- raw.component_health_quarantine: Rows failing critical rules

**Sanity Check**:

```sql
SELECT tbl, COUNT(*) FROM (
  SELECT 'dim_aircraft' tbl, COUNT(*) FROM curated.dim_aircraft
  UNION ALL SELECT 'dim_component', COUNT(*) FROM curated.dim_component
  UNION ALL SELECT 'fact', COUNT(*) FROM curated.fact_component_health_snapshot
) x GROUP BY tbl;
```

#### Step 3: Feature Engineering & Model Training (Script 03)

```bash
psql -h <postgres_host> -U <admin_user> -d <database> -f 03_features_and_ml.sql
```

**Output**:
- features.component_health_features_v1: Engineered dataset
- features.component_health_train/validation/test: Temporal splits
- models.model_registry: 3 trained models with metadata
- predictions.component_rul_predictions: Batch scoring results

**Verify Model Training**:

```sql
SELECT model_name, model_version, is_active FROM models.model_registry;
```

**Check Predictions**:

```sql
SELECT 
  COUNT(*) AS total_predictions,
  COUNT(CASE WHEN risk_tier = 'High' THEN 1 END) AS high_risk,
  COUNT(CASE WHEN risk_tier = 'Elevated' THEN 1 END) AS elevated_risk
FROM predictions.component_rul_predictions;
```

#### Step 4: Monitoring, Drift Detection, & Automation (Script 04)

```bash
psql -h <postgres_host> -U <admin_user> -d <database> -f 04_monitoring_and_retraining.sql
```

**Output**:
- monitoring.model_performance_log: Baseline metrics recorded
- monitoring.data_drift_log: Initial drift baseline
- monitoring.alerts: Open alerts from monitoring jobs
- Scheduled pg_cron jobs (commented out for manual activation)

**Enable Scheduled Jobs** (optional; requires pg_cron):

```sql
CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule('helios_nightly_feature_refresh', '0 2 * * *',
    $$SELECT features.build_component_health_features_v1();$$);

SELECT cron.schedule('helios_nightly_drift_check', '15 2 * * *',
    $$SELECT monitoring.check_feature_drift();$$);

SELECT cron.schedule('helios_weekly_model_eval', '0 3 * * 1',
    $$SELECT monitoring.evaluate_rul_model('helios_component_rul_regression','v1');
      SELECT monitoring.evaluate_classifier('helios_component_failure_90d_classification','predicted_failure_prob_90d','failure_within_90_days');
      SELECT monitoring.evaluate_classifier('helios_component_failure_30d_classification','predicted_failure_prob_30d','failure_within_30_days');$$);

SELECT cron.schedule('helios_monthly_partition', '0 0 1 * *',
    $$SELECT mgmt.ensure_partition((CURRENT_DATE + INTERVAL '1 month')::DATE);$$);
```

---

## Query Examples & Analytics

### 1. Component Risk Ranking (for Maintenance Planning)

```sql
SELECT 
  p.component_serial_number,
  c.component_type, c.component_subtype,
  c.part_cost_usd,
  f.aircraft_tail_number, a.aircraft_model, a.operating_region,
  p.predicted_rul_days,
  p.predicted_failure_prob_30d,
  p.predicted_failure_prob_90d,
  p.risk_tier,
  p.scored_at
FROM predictions.vw_latest_component_risk p
JOIN curated.dim_component c ON c.component_serial_number = p.component_serial_number
JOIN curated.dim_aircraft a ON a.aircraft_tail_number = p.aircraft_tail_number
WHERE p.risk_tier IN ('High', 'Elevated')
ORDER BY p.predicted_failure_prob_30d DESC
LIMIT 50;
```

**Use Case**: Fleet maintenance prioritization; identify components requiring immediate or near-term replacement.

### 2. Aircraft Health Summary

```sql
SELECT 
  a.aircraft_tail_number,
  a.aircraft_model,
  COUNT(*) AS total_components,
  SUM(CASE WHEN p.risk_tier = 'High' THEN 1 ELSE 0 END) AS high_risk_count,
  SUM(CASE WHEN p.risk_tier = 'Elevated' THEN 1 ELSE 0 END) AS elevated_risk_count,
  ROUND(AVG(p.predicted_rul_days), 1) AS avg_rul_days
FROM predictions.vw_latest_component_risk p
JOIN curated.dim_aircraft a ON a.aircraft_tail_number = p.aircraft_tail_number
GROUP BY a.aircraft_tail_number, a.aircraft_model
ORDER BY high_risk_count DESC;
```

**Use Case**: Executive dashboard; fleet-wide health metrics and aircraft grounding risk.

### 3. Supplier Quality Correlation

```sql
SELECT 
  s.supplier_id,
  s.supplier_quality_score,
  COUNT(c.component_serial_number) AS components_supplied,
  COUNT(CASE WHEN p.risk_tier IN ('High', 'Elevated') THEN 1 END) AS at_risk_components,
  ROUND(100.0 * COUNT(CASE WHEN p.risk_tier IN ('High', 'Elevated') THEN 1 END) 
        / NULLIF(COUNT(c.component_serial_number), 0), 2) AS risk_pct
FROM curated.dim_supplier s
LEFT JOIN curated.dim_component c ON c.supplier_id = s.supplier_id
LEFT JOIN predictions.component_rul_predictions p ON p.component_serial_number = c.component_serial_number
  AND p.scored_at = (SELECT MAX(scored_at) FROM predictions.component_rul_predictions)
GROUP BY s.supplier_id, s.supplier_quality_score
ORDER BY risk_pct DESC;
```

**Use Case**: Supply chain risk analysis; identify underperforming suppliers for escalation or corrective action.

### 4. Model Performance Trending

```sql
SELECT 
  model_name,
  metric_name,
  AVG(metric_value) AS avg_metric,
  MIN(metric_value) AS min_metric,
  MAX(metric_value) AS max_metric,
  COUNT(*) AS samples
FROM monitoring.model_performance_log
WHERE logged_at > now() - INTERVAL '90 days'
GROUP BY model_name, metric_name
ORDER BY model_name, metric_name;
```

**Use Case**: Model ops dashboard; track RMSE/MAE/precision/recall trends; identify degradation requiring retraining.

### 5. Data Quality Report

```sql
SELECT 
  r.rule_name,
  r.rule_category,
  r.severity,
  MAX(res.run_at) AS last_run,
  res.rows_checked,
  res.rows_failed,
  res.pass_rate_pct
FROM monitoring.data_quality_results res
JOIN monitoring.data_quality_rules r ON res.rule_id = r.rule_id
WHERE res.run_at = (SELECT MAX(run_at) FROM monitoring.data_quality_results)
ORDER BY r.severity DESC, res.pass_rate_pct ASC;
```

**Use Case**: Data governance reporting; ensure data quality before downstream consumption.

### 6. Active Alerts for Escalation

```sql
SELECT * FROM monitoring.vw_open_alerts
WHERE severity IN ('Warning', 'Critical')
ORDER BY severity DESC, raised_at DESC;
```

**Use Case**: Real-time alerting; escalate critical alerts to operations/maintenance teams.

---

## Access Control & Governance

### Role Definitions

| Role | Privileges | Use Case |
|------|-----------|----------|
| `role_data_engineer` | Full access to raw & curated schemas | Data pipeline ownership; dimension/fact table maintenance |
| `role_ml_engineer` | Read curated/features; full access to models/predictions | Feature engineering, training, scoring, retraining |
| `role_bi_reader` | Read-only curated, features, predictions | BI tool consumption (Power BI, Tableau, Looker) |
| `role_auditor` | Read-only monitoring & mgmt schemas | Compliance auditing; audit trail review |

### Granting Roles

```sql
-- Add users to roles (replace 'username' with actual PostgreSQL user)
GRANT role_data_engineer TO <username>;
GRANT role_ml_engineer TO <username>;
GRANT role_bi_reader TO <username>;
GRANT role_auditor TO <username>;
```

### Audit Trail

Every INSERT, UPDATE, DELETE on `curated.fact_component_health_snapshot` is logged to `mgmt.audit_log`:

```sql
SELECT 
  audit_id, event_time, db_user, operation, row_pk,
  row_hash  -- MD5 hash of row state (for integrity verification)
FROM mgmt.audit_log
WHERE schema_name = 'curated' AND table_name = 'fact_component_health_snapshot'
ORDER BY event_time DESC
LIMIT 100;
```

---

## Advanced Topics

### Feature Versioning

Features are versioned by table (e.g., `component_health_features_v1`, `component_health_features_v2`):

- **Immutable history**: Old feature versions retained for audit and model reproducibility
- **Model Registry tracking**: Each model references its feature table (e.g., `features.component_health_features_v1`)
- **A/B testing**: Train new models on new feature versions; compare performance; promote incrementally

### Handling Class Imbalance

The 30-day and 90-day failure classifiers exhibit severe class imbalance:

- **90-Day Model**: ~9% positive rate → Use recall-tuned decision thresholds; lower threshold → higher recall, more false positives
- **30-Day Model**: ~4% positive rate → Consider SMOTE/class weighting; focus on precision for false-positive costs

**Recommended threshold tuning** (via holdout validation set):

```sql
-- Vary threshold and compute Precision/Recall
SELECT 
  threshold,
  SUM(CASE WHEN p.predicted_failure_prob_30d > threshold AND f.failure_within_30_days = 1 THEN 1 ELSE 0 END)::NUMERIC
  / NULLIF(SUM(CASE WHEN p.predicted_failure_prob_30d > threshold THEN 1 END), 0) AS precision,
  SUM(CASE WHEN p.predicted_failure_prob_30d > threshold AND f.failure_within_30_days = 1 THEN 1 ELSE 0 END)::NUMERIC
  / NULLIF(SUM(CASE WHEN f.failure_within_30_days = 1 THEN 1 END), 0) AS recall
FROM (SELECT 0.2 as threshold UNION ALL SELECT 0.3 UNION ALL SELECT 0.4 UNION ALL SELECT 0.5) t
CROSS JOIN predictions.component_rul_predictions p
JOIN features.component_health_features_v1 f
  ON f.record_id = p.record_id AND f.snapshot_date = p.snapshot_date
WHERE p.model_name = 'helios_component_failure_30d_classification'
GROUP BY threshold
ORDER BY threshold;
```

### Human-in-the-Loop Feedback

High-impact predictions (e.g., flight-critical components) should be reviewed by domain experts:

```sql
-- Record a human override
INSERT INTO models.human_review_overrides
  (record_id, model_id, original_prediction, reviewer_decision, reviewer_id, reviewer_comment)
VALUES
  (12345, 1, '{"risk_tier": "High", "predicted_prob_30d": 0.68}'::jsonb, 
   'Confirmed', 'maint_supervisor_001', 'Component inspection confirms imminent wear');
```

These overrides feed the retraining pipeline:

```sql
-- Sample future training sets stratified by reviewer feedback
SELECT f.* FROM features.component_health_features_v1 f
WHERE EXISTS (
  SELECT 1 FROM models.human_review_overrides h
  WHERE h.record_id = f.record_id 
    AND h.reviewer_decision = 'Confirmed'
)
ORDER BY RANDOM() LIMIT 500;
```

### Partitioning & Retention Policies

Monthly partitions enable efficient archival:

```sql
-- Archive old partition to cold storage (quarterly review)
-- After moving fact_component_health_snapshot_2023_06 offline:
ALTER TABLE curated.fact_component_health_snapshot
DETACH PARTITION curated.fact_component_health_snapshot_2023_06;

-- Validate and compress before long-term storage
VACUUM FULL ANALYZE curated.fact_component_health_snapshot_2023_06;
```

---

## Business Case & ROI

### Key Use Cases

1. **Component Health Assessment & RUL Estimation** ✓ (Implemented)
   - Centralized component health monitoring across fleet
   - Remaining useful life predictions for proactive planning
   - Risk-stratified rankings for prioritized inspection

2. **Maintenance Optimization** (Enabled by Use Case 1)
   - Shift from calendar-based to condition-based maintenance
   - Target: 15–25% reduction in unscheduled downtime
   - Pre-position spare parts 30/60/90 days ahead of predicted failures

3. **Supply Chain Efficiency** (Enabled by Use Cases 1 & 2)
   - Demand forecasting from predicted component retirements
   - Reduce holding costs on excess inventory
   - Minimize stock-outs by aligning procurement to predicted need

4. **Regulatory & Safety Compliance**
   - Immutable audit trail for 14 CFR part 121 / EASA audit requirements
   - Data quality enforcement prevents unsafe operational decisions
   - Model governance and explainability support certification bodies

### Quantified Benefits (Illustrative)

| Metric | Baseline | Target | Driver |
|--------|----------|--------|--------|
| Unscheduled Downtime | 12% of flight hours | 8–10% | Predictive RUL + 30/60-day warning horizon |
| Spare Parts Carrying Cost | $50M annually | $35–40M | Improved demand forecasting |
| Maintenance Margin | 18% cost overage | 8–10% | Condition-based vs. calendar-based scheduling |
| Audit Findings (Compliance) | 2–3 per year | <1 per year | Automated data quality + audit trail |

---

## Support & Maintenance

### Troubleshooting

**Issue**: Feature build is slow (>10 minutes)

→ Add index on `fact_component_health_snapshot(snapshot_date)` and `dim_component(design_mtbf_hours)`

```sql
ANALYZE curated.fact_component_health_snapshot;
ANALYZE curated.dim_component;
```

**Issue**: Data quality rule failing at load time

→ Review `monitoring.data_quality_results` for the specific rule and failing rows:

```sql
SELECT rule_name, rows_checked, rows_failed, pass_rate_pct
FROM monitoring.data_quality_results
WHERE run_at = (SELECT MAX(run_at) FROM monitoring.data_quality_results)
ORDER BY passed, severity DESC;
```

→ Route failing rows to quarantine and inspect:

```sql
SELECT * FROM raw.component_health_quarantine 
WHERE quarantined_at > now() - INTERVAL '1 day'
ORDER BY quarantined_at DESC;
```

**Issue**: Model performance has degraded

→ Check for data drift:

```sql
SELECT * FROM monitoring.data_drift_log 
WHERE evaluated_at > now() - INTERVAL '7 days'
AND drift_flag = TRUE
ORDER BY evaluated_at DESC;
```

→ If drift detected, trigger retraining:

```sql
SELECT model_name, reason FROM mgmt.retraining_required();
```

### Maintenance Schedule

| Task | Frequency | Owner | Notes |
|------|-----------|-------|-------|
| Review open alerts | Daily | Ops/Maintenance | Escalate Critical alerts within 2 hours |
| Model performance review | Weekly | ML Engineer | Check RMSE/Recall trends; adjust thresholds if needed |
| Data drift assessment | Weekly | Data Engineer | Investigate >15% shifts in key features |
| Retraining validation | Monthly | ML Engineer | Retrain if Critical alerts raised; A/B test vs. current model |
| Audit log review | Quarterly | Compliance Officer | Verify immutability; export for regulatory file |
| Partition management | Monthly (1st) | DBA | Ensure next month's partition pre-created |

---

## Integration with BI & Analytics Platforms

### Power BI / Tableau

**Primary Views for BI Consumption**:

1. `predictions.vw_latest_component_risk` — Component risk rankings with joinable aircraft/component/supplier data
2. `monitoring.vw_open_alerts` — Active alerts feed
3. Ad-hoc queries against `curated.dim_*` and `monitoring.model_performance_log`

**Refresh Cadence**:

- Predictions: Batch scored nightly; Power BI dataset refresh at 06:00 UTC
- Monitoring: Real-time queries (if Power BI connected directly to PostgreSQL); refresh every 5 minutes
- Dimensions: Daily (manual or scheduled Pull)

**Authentication**: PostgreSQL role-based (e.g., `role_bi_reader` user via Power BI service principal)

### Export Patterns

For air-gapped environments or external systems:

```sql
-- Export latest predictions for external BI tool
COPY (
  SELECT * FROM predictions.vw_latest_component_risk
  WHERE scored_at >= now() - INTERVAL '1 day'
) TO '/tmp/helios_latest_predictions.csv' WITH (FORMAT csv, HEADER);
```

---

## Future Enhancements & Roadmap

### Phase 2 (Planned)

- **Multi-Model Ensemble**: Combine XGBoost RUL + probabilistic Bayesian model for uncertainty quantification
- **Explainability Layer**: SHAP values computed in SQL (PostgresML extension) to explain individual predictions
- **Real-Time Scoring**: gRPC/REST API wrapper around PostgresML for live component health ingestion
- **Causal Inference**: Estimate maintenance intervention impact on component longevity (instrumental variable estimation)

### Phase 3 (Future)

- **Supply Chain Integration**: Link to OEM parts databases for automatic availability checking
- **Prescriptive Analytics**: Optimization engine for cost-optimal maintenance scheduling across fleet
- **Autonomous Retraining**: Fully automated retraining pipeline with statistical significance tests and canary deployment

---

## Conclusion

HELIOS represents a **production-grade, SQL-native ML platform** built on PostgreSQL that delivers **measurable business value** across maintenance optimization, supply chain efficiency, and regulatory compliance. By bringing data engineering, feature engineering, model training, and monitoring into a single SQL-first system, HELIOS eliminates data silos, ensures auditability, and enables rapid iteration on predictive maintenance use cases.

The modular design allows incremental adoption: start with Use Case A (component health assessment) and scale to fleet-wide predictive maintenance orchestration. The declarative data quality framework and comprehensive audit trail satisfy enterprise governance requirements while maintaining the agility needed for competitive advantage in aviation operations.

---

## License

MIT License — See [LICENSE](LICENSE) file for details.

## Contact & Support

For questions, issues, or contributions:

- **Project Owner**: ANTHONY CHINEDU ECHEM
- **Repository**: [HELIOS_AIRCRAFT_GROUP_IN_DATABASE_ML_PROJECT](https://github.com/ANTHONY-CHINEDU-ECHEM/HELIOS_AIRCRAFT_GROUP_IN_DATABASE_ML_PROJECT)
- **Issues**: GitHub Issues (for bugs, feature requests, documentation)

---

**Last Updated**: September 16, 2026  
**Version**: 1.0 (Production Ready)
