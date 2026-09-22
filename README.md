# HELIOS Aircraft Corporation: Intelligent Predictive Operations Initiative

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [Project Rationale: Why HELIOS Exists](#project-rationale-why-helios-exists)
3. [Architecture Overview](#architecture-overview)
4. [Data Pipeline and Workflow](#data-pipeline-and-workflow)
5. [Data Dictionary](#data-dictionary)
6. [Setup and Deployment](#setup-and-deployment)
7. [Query Examples and Analytics](#query-examples-and-analytics)
8. [Access Control and Governance](#access-control-and-governance)
9. [Advanced Topics](#advanced-topics)
10. [Business Case and Return on Investment](#business-case-and-return-on-investment)
11. [Support and Maintenance](#support-and-maintenance)
12. [Integration with BI and Analytics Platforms](#integration-with-bi-and-analytics-platforms)
13. [Future Enhancements and Roadmap](#future-enhancements-and-roadmap)
14. [Conclusion](#conclusion)
15. [License](#license)
16. [Contact and Support](#contact-and-support)

---

## Executive Summary

HELIOS is an enterprise grade, SQL native machine learning platform designed to transform component health monitoring and maintenance planning across commercial aviation fleets. By combining PostgreSQL's advanced analytical capabilities, in database machine learning, and comprehensive data governance, this system enables predictive maintenance scheduling, risk stratified component retirement, and supply chain optimization, delivering measurable operational savings and enhanced safety outcomes.

### Business Impact

- **Predictive maintenance windows.** Replace reactive maintenance with data driven forecasting of component failures within 30, 60, and 90 day horizons.
- **Asset utilization optimization.** Maximize flight hours per component before planned removal, reducing unscheduled downtime by an estimated 15 to 25 percent.
- **Supply chain efficiency.** Align parts procurement and inventory to predicted demand, reducing carrying costs and stockouts.
- **Safety and compliance.** Automated data quality enforcement and immutable audit trails satisfy regulatory (14 CFR, EASA) and internal compliance requirements.
- **Decision support.** Risk stratified component rankings and explanatory feature importance for maintenance teams and flight operations.

---

## Project Rationale: Why HELIOS Exists

### The State of Aircraft Component Maintenance Today

Commercial aviation has historically managed component health through two dominant paradigms, and both leave meaningful value and safety margin on the table. The first is calendar based, or hard time, maintenance, in which a component is removed and overhauled on a fixed schedule regardless of its actual condition. This is safe by design, since it is built around conservative design life assumptions, but it is also wasteful: a large share of components removed under a hard time schedule still have substantial remaining useful life, representing scrapped value and unnecessary labor. The second paradigm is reactive maintenance, in which a component is serviced only after it degrades enough to trigger a fault code, a pilot report, or an outright failure. Reactive maintenance is inexpensive when nothing goes wrong, but it concentrates risk at exactly the wrong moment, since a failure discovered in service, rather than on the ground during a scheduled check, is the costliest and least safe way for a defect to surface.

Predictive maintenance, the paradigm HELIOS is built around, sits between these two extremes. Rather than servicing a component on a fixed calendar or waiting for it to fail, the goal is to estimate, from live operating data, how much useful life a specific component has left, and to schedule its removal proactively, close to the point where risk begins to rise, but before it does. This is not a new idea in principle. What has changed is that modern aircraft generate the telemetry, in the form of vibration, temperature, pressure, and oil debris sensors, that makes a data driven estimate of remaining useful life genuinely more informative than either a fixed calendar or a wait and see approach. The opportunity HELIOS addresses is turning that telemetry, which airlines already collect, into a governed, auditable, and operationally trustworthy prediction that a maintenance planner can act on with confidence.

### Why This Is a Data Engineering Problem, Not Just a Modeling Problem

A recurring failure mode in industrial predictive maintenance initiatives is that a data science team builds an accurate model in a notebook, and the model never makes it into a trustworthy production decision. The reason is rarely the model itself. It is almost always the surrounding infrastructure: the data pipeline feeding the model has no quality gate, so a batch of corrupted sensor readings can silently degrade a live prediction; the feature computation lives in an untracked script, so nobody can reproduce last month's scores; the model has no registered version or documented limitations, so a maintenance planner has no way to know whether to trust it; and there is no audit trail, so a regulator or an internal safety review has no way to reconstruct why a particular component was, or was not, flagged as high risk.

HELIOS is deliberately architected to treat these concerns as first class requirements rather than afterthoughts. The data quality framework, the model registry, the immutable audit log, and the drift monitoring described throughout this document exist because, in an aviation context, an unreliable or unauditable prediction is arguably worse than no prediction at all. A maintenance team that learns to distrust a black box tool will quietly revert to the calendar based schedule it was meant to replace, and the investment in building it will have produced no safety or cost benefit whatsoever. The design priority throughout HELIOS is therefore not only predictive accuracy, but predictive accuracy that a skeptical maintenance engineer, a compliance auditor, and a regulator can all independently verify.

### Why an In Database, SQL Native Architecture

A conventional machine learning stack typically separates the database, which holds the data, from a separate machine learning platform, often built on Python and a collection of external services, where features are engineered, models are trained, and predictions are produced. HELIOS deliberately rejects that separation and instead performs ingestion, data quality enforcement, feature engineering, model training, scoring, and monitoring entirely inside PostgreSQL, using PostgresML for in database gradient boosted tree training. This is an unusual architectural choice, and it was made for specific, defensible reasons rather than as a novelty:

- **A single source of truth for governance.** When features, models, and predictions all live in the same database as the underlying fact and dimension tables, role based access control, audit logging, and data lineage apply uniformly across the entire pipeline, rather than needing to be separately implemented and kept in sync across a database and an external ML service.
- **Lower operational surface area.** There is no separate feature store, model serving cluster, or orchestration layer to provision, secure, monitor, and keep available. For a mid sized aviation MRO or fleet operations team, that translates directly into lower infrastructure cost and fewer systems that can independently fail.
- **Reproducibility by construction.** Because every feature is a versioned SQL function and every model is trained against a specific, queryable feature table snapshot, reproducing a historical prediction, or explaining to an auditor exactly how a given score was produced, is a matter of rerunning a documented SQL statement rather than reconstructing an external pipeline's state at a point in time.
- **A natural fit for the consumption pattern.** The eventual consumers of these predictions are maintenance planners and business intelligence dashboards, both of which already query PostgreSQL directly or through BI tools such as Power BI or Tableau. Keeping predictions in the same database they already query removes an entire integration layer.

The tradeoff, and it is a real one, is that PostgresML's XGBoost implementation and PL/pgSQL are less expressive than a full Python machine learning stack, and this repository is explicit about that limitation rather than hiding it. The [Future Enhancements and Roadmap](#future-enhancements-and-roadmap) section below describes where an external service, for example for SHAP based explainability at scale or for a more sophisticated ensemble, may eventually be justified. The architectural default, however, is to keep everything in SQL until there is a specific, demonstrated reason not to, because every component pulled out of the database is a component that has to be separately governed, secured, and kept consistent with everything else.

### Why Predictive Maintenance Matters Specifically for Aviation

The business case for predictive maintenance exists across many industrial sectors, but the stakes and the constraints are distinctive in commercial aviation, and that distinctiveness shapes several of HELIOS's design decisions:

- **Safety is non negotiable, but it is also not the only variable.** A predictive model that is wrong in the unsafe direction, meaning it fails to flag a component that goes on to fail in service, is unacceptable regardless of how much money it saves elsewhere. This is why the risk tier logic in this system is deliberately conservative and deterministic, why classifier thresholds are tuned toward recall rather than precision for the highest risk tiers, and why every prediction is explicitly framed as decision support for a human maintenance planner rather than as an autonomous removal trigger.
- **The cost of unscheduled downtime is asymmetric and large.** An aircraft grounded unexpectedly does not just cost the price of the repair; it cascades into missed flights, crew repositioning, passenger compensation, and schedule disruption across a hub. This asymmetry is why the business case in this document weights the value of shifting even a modest share of unscheduled removals to scheduled ones so heavily.
- **Regulatory and audit requirements are strict and well defined.** Under frameworks such as 14 CFR Part 121 in the United States and EASA regulations in Europe, maintenance decisions must be traceable, and data used to support them must be demonstrably governed. This is why HELIOS treats its audit trail, its data quality rule catalog, and its model registry as core product features rather than optional add ons; they are what make a predictive maintenance recommendation admissible as part of a documented maintenance decision, rather than an informal suggestion a team is free to ignore or cannot defend under audit.
- **Component economics reward precision.** Aviation components, particularly engines, APUs, and major hydraulic and avionics assemblies, are expensive enough that even a modest improvement in how accurately their remaining useful life is estimated has a direct, quantifiable effect on both maintenance spend and spare parts inventory carrying cost, which is why this document reports specific, itemized financial targets in the [Business Case and Return on Investment](#business-case-and-return-on-investment) section rather than only a qualitative claim of value.

### What Success Looks Like

HELIOS is judged successful not when it produces a model with a strong offline accuracy metric, but when a maintenance planning team routinely uses its risk tier rankings to decide which components to inspect or replace next, when its predictions survive scrutiny from a compliance audit, and when its drift monitoring catches a degrading model before that degradation translates into a missed failure or a wasted early removal. The remainder of this document describes, in technical detail, how the platform is built to meet that bar: a governed data pipeline, versioned features, a registered and monitored set of models, and an audit trail sufficient to satisfy both an internal reliability engineering review and an external regulatory one.

---

## Architecture Overview

### System Design Philosophy

The HELIOS platform follows a modular, SQL first architecture that maximizes PostgreSQL's analytical and machine learning capabilities:

1. **Landing zone** (`raw` schema): untransformed source extracts from MRO, ERP, and health monitoring systems.
2. **Curated foundation** (`curated` schema): conformed, governed dimensional and fact tables with automated data quality gates.
3. **Feature engineering** (`features` schema): versioned, model ready datasets built entirely with SQL window functions and domain driven ratios.
4. **Model registry and lifecycle** (`models` schema): structured model cards, hyperparameters, and performance metadata.
5. **Prediction and scoring** (`predictions` schema): batch scoring output with risk tiers and contributing factors for BI consumption.
6. **Monitoring and observability** (`monitoring` schema): drift detection, performance tracking, and alerting, all computed in SQL.

### Technical Stack

- **Language:** PL/pgSQL (PostgreSQL 15 or later)
- **Core platform:** PostgreSQL, with table partitioning, native triggers, and role based access control
- **ML runtime:** PostgresML (in database gradient boosted trees, via XGBoost)
- **Scheduling:** pg_cron, for automated feature refresh, drift checks, and retraining triggers
- **Data quality:** a declarative rule engine with quarantine routing and compliance logging

### Entity Relationship Design

```
dim_aircraft (one per tail number)
  |- fact_component_health_snapshot (time series, partitioned monthly)
       |- dim_component (one per serial number)
       |    |- dim_supplier (one per supplier ID)
       |- [joins to features and models for inference]
```

---

## Data Pipeline and Workflow

### Phase 1: Data Ingestion and Quality Assurance (Scripts 01 and 02)

**`01_schema_and_tables.sql`: initializes the data warehouse.**

- **Schemas:** establishes 7 purpose built schemas with granular data governance.
- **Dimensions:** master data for aircraft (tail numbers, fleet composition), components (serial numbers, design MTBF), and suppliers.
- **Fact table:** a partitioned monthly fact table tracking component health snapshots across the fleet.
- **Data quality framework:** a declarative rule catalog with 7 built in checks, covering completeness, validity, uniqueness, consistency, and referential integrity.
- **Role based access control:** four roles (data engineer, ML engineer, BI reader, auditor) with schema level and table level permissions.
- **Audit trail:** an immutable, append only audit log for all mutations to the fact table.

**`02_load_and_transform.sql`: transforms and governs the source extract.**

- **CSV ingestion:** loads from the source Excel or CSV export into the raw staging table.
- **The quality gate:** executes all 7 data quality rules; failures route to quarantine, and pass rate metrics are logged for dashboards.
- **Master data upsert:** idempotent inserts and updates for aircraft, components, and suppliers, using CONFLICT clauses that allow safe re runs.
- **Fact table promotion:** transforms raw data into the curated fact table, with foreign key references to the dimensions.
- **Sanity checks:** count verifications by table, to confirm load completeness.

**Key mechanisms:**

- Temporal partitioning (monthly ranges), for efficient queries and archival or retention management.
- A quarantine table that isolates data quality failures without blocking downstream processing.
- Triggers that automatically update `updated_at` timestamps on dimension tables.

### Phase 2: Feature Engineering and Model Training (Script 03)

**`03_features_and_ml.sql`: builds machine learning ready datasets and trains ensemble models.**

**Feature engineering** (SQL window functions and domain driven ratios):

| Feature | Derivation | Business meaning |
|---|---|---|
| `pct_of_design_life_consumed` | cumulative_flight_hours divided by design_mtbf_hours | Lifecycle progression as a percentage of rated MTBF |
| `hours_per_cycle` | cumulative_flight_hours divided by cumulative_flight_cycles | Mechanical stress intensity per flight |
| `unscheduled_removal_ratio` | prior_unscheduled divided by prior_removal_count | A reliability indicator; higher values mean more unexpected failures |
| `sensor_composite_risk_score` | 0.40 times vibration, plus 0.35 times oil debris, plus 0.25 times anomalies | A weighted health sensor fusion |
| `maintenance_recency_score` | exp(negative days_since_maintenance divided by 90) | The exponential decay of maintenance benefit over time |
| `rolling_30d_component_type_failure_rate` | A windowed average of failure_within_90_days by component_type | A cohort level risk trend |

**Three production models**, trained through PostgresML's XGBoost integration:

1. **RUL regression** (`helios_component_rul_regression`): predicts remaining useful life in days.
   - Algorithm: XGBoost, with `n_estimators` of 300, `max_depth` of 6, and a learning rate of 0.05.
   - Target: `remaining_useful_life_days`.
   - Use case: optimizing maintenance scheduling windows.

2. **The 90 day failure classifier** (`helios_component_failure_90d_classification`): estimates the probability of failure within 90 days.
   - Algorithm: XGBoost, with `n_estimators` of 300 and `max_depth` of 5.
   - Target: `failure_within_90_days` (a binary label).
   - Use case: proactive inspection planning.
   - Handling: class imbalance, with an approximately 9 percent positive rate; recall tuned thresholds are recommended.

3. **The 30 day failure classifier** (`helios_component_failure_30d_classification`): estimates urgent, near term risk.
   - Algorithm: XGBoost, with `n_estimators` of 250 and `max_depth` of 5.
   - Target: `failure_within_30_days` (a binary label).
   - Use case: immediate triage and parts pre positioning.
   - Handling: severe class imbalance, with an approximately 4 percent positive rate.

**The train, validation, and test split** (temporal):

- **Train:** all records before the maximum snapshot_date minus 120 days.
- **Validation:** records from 120 to 60 days before the present.
- **Test:** records within the last 60 days.
- **Rationale:** this preserves temporal order and validates out of sample performance on recent, unseen data, rather than allowing information from the future to leak into training.

**The model registry** (structured metadata):

Each trained model is registered with its hyperparameters, a summary of its training data (including row counts), its intended use, its known limitations, its risk classification, an `is_active` flag governing production eligibility, and a `trained_at` timestamp together with `trained_by` user attribution.

### Phase 3: Scoring and Decision Support (Script 03, Continued)

**The batch prediction loop:**

```sql
INSERT INTO predictions.component_rul_predictions
  (record_id, component_serial_number, snapshot_date, model_name, model_version,
   predicted_rul_days, predicted_failure_prob_30d, predicted_failure_prob_90d, risk_tier)
SELECT <features> FROM features.component_health_test t
  WHERE pgml.predict('helios_component_rul_regression', ROW(t.*)) -> predicted_rul_days
```

**The risk tier logic** (deterministic, computed in SQL):

```
IF predicted_failure_prob_30d > 0.5  -> "High"
ELSE IF predicted_failure_prob_90d > 0.5 -> "Elevated"
ELSE IF predicted_failure_prob_90d > 0.2 -> "Watch"
ELSE -> "Low"
```

**Output fields:**

- `predicted_rul_days`: a point estimate used for maintenance scheduling.
- `predicted_failure_prob_30d`, `predicted_failure_prob_90d`: risk probabilities.
- `risk_tier`: an actionable category for dispatch and fleet planning.
- `top_contributing_factors`: JSONB serialized feature importance (Shapley values, in extended versions of the platform).

### Phase 4: Monitoring, Drift Detection, and Retraining (Script 04)

**`04_monitoring_and_retraining.sql`: sustains model accuracy and data quality.**

**Model performance tracking:**

- **RUL metrics:** RMSE and MAE, computed against known outcomes in the test set.
- **Classifier metrics:** precision and recall, at a 0.5 threshold decision boundary.
- **Alert thresholds:**
  - RMSE above 150 days triggers a Warning.
  - Recall below 0.60 triggers a Critical alert, prompting a retraining review.
- **The evaluation window** is configurable per model, allowing date ranges to be adjusted as needed.

**Data drift detection** (a mean shift test on key features):

Features monitored: `health_monitoring_score`, `sensor_vibration_index`, `sensor_oil_debris_index`, and `anomaly_count_last_30_days`.

```sql
-- Reference: 90 or more days before present
-- Current: the last 30 days
-- Drift threshold: a change greater than 15 percent triggers an alert
```

**Automated alerting:**

- Alert types: Data Quality, Data Drift, Model Performance, Prediction Volume.
- Severity levels: Info, Warning, Critical.
- Consumption: Power BI dashboards (an executive risk dashboard and a reliability engineering dashboard).
- Human review override: captured in the `models.human_review_overrides` table, to support feedback loops.

**Scheduled jobs**, run through pg_cron:

| Job | Frequency | Action |
|---|---|---|
| Feature refresh | Nightly, 02:00 UTC | Rebuild `component_health_features_v1` from raw and curated data |
| Drift check | Nightly, 02:15 UTC | Run feature distribution tests; log alerts if the shift exceeds 15 percent |
| Model evaluation | Weekly, Monday 03:00 | Compute RMSE, MAE, precision, and recall; log to the monitoring tables |
| Partition ensure | Monthly, the 1st at 00:00 | Proactively create next month's fact table partition |

**Retraining trigger logic:**

```sql
SELECT model_name, reason FROM mgmt.retraining_required()
-- Returns any model with unacknowledged warning or critical alerts raised in the last 7 days
```

---

## Data Dictionary

### Key Dimensions

#### `curated.dim_aircraft`

| Column | Type | Constraint | Semantics |
|---|---|---|---|
| aircraft_tail_number | TEXT | Primary key | ICAO registration (for example, N12345) |
| aircraft_model | TEXT | Not null | Airbus or Boeing model (A320, 787, and so on) |
| fleet_type | TEXT | Not null | Narrowbody, Regional, or Specialized Mission |
| aircraft_age_years | NUMERIC(6,2) | 0 or greater | Years since manufacture |
| operating_region | TEXT | Not null | Geographic base (for example, North America, Europe) |
| operating_environment | TEXT | Not null | Desert, Coastal, Temperate, Arctic, or Tropical |
| route_type | TEXT | Not null | Short, medium, or long haul |
| avg_daily_utilization_hours | NUMERIC(6,2) | 0 or greater | Typical daily flight hours |

#### `curated.dim_component`

| Column | Type | Constraint | Semantics |
|---|---|---|---|
| component_serial_number | TEXT | Primary key | Manufacturer serial number |
| component_type | TEXT | Not null | Engine, APU, Hydraulic, Avionics, Structural, and so on |
| component_subtype | TEXT | Not null | A more specific category (for example, CF6 Engine) |
| design_mtbf_hours | NUMERIC(10,1) | Greater than 0 | Mean time between failures per specification sheet |
| part_cost_usd | NUMERIC(12,2) | 0 or greater | Acquisition cost, used for return on investment calculations |
| warranty_status | TEXT | In Warranty, Out of Warranty, or Extended | Coverage classification |
| firmware_version | TEXT | Nullable | For electronic components |

#### `curated.dim_supplier`

| Column | Type | Constraint | Semantics |
|---|---|---|---|
| supplier_id | TEXT | Primary key | Supplier identifier |
| supplier_quality_score | NUMERIC(5,1) | 0 to 100 | Current quality rating (internal or OEM sourced) |

### Key Fact Table

#### `curated.fact_component_health_snapshot`

**Partitioning:** by range on `snapshot_date` (monthly), for example `fact_component_health_snapshot_2023_06`, `fact_component_health_snapshot_2023_07`, and so on.

| Column | Type | Semantics |
|---|---|---|
| record_id, snapshot_date | Primary key | A composite key; snapshot_date determines the partition |
| aircraft_tail_number, component_serial_number | Foreign key | Links to the dimension tables |
| cumulative_flight_hours, cumulative_flight_cycles | Integer | Total usage since installation |
| flight_hours_since_last_overhaul | Integer | Stress accumulation since the last major service |
| prior_removal_count, prior_unscheduled_removal_count | Integer | Reliability history |
| sensor_vibration_index, sensor_temperature_avg_c, sensor_pressure_avg_psi, sensor_oil_debris_index | NUMERIC | Raw health sensor telemetry |
| health_monitoring_score | NUMERIC, 0 to 100 | A composite health index |
| anomaly_count_last_30_days | Integer | Number of sensor anomalies detected |
| remaining_useful_life_days | NUMERIC | The known outcome, used as ground truth for training |
| failure_within_30_days, failure_within_90_days | SMALLINT (0 or 1) | Binary labels, used as ground truth |

### The Feature Engineering Table

#### `features.component_health_features_v1`

**Purpose:** a model ready dataset, with one row per component per snapshot_date. Rebuilt nightly by `features.build_component_health_features_v1()`.

**Includes:**

- All raw fact table columns.
- Engineered features (`pct_of_design_life_consumed`, `hours_per_cycle`, `sensor_composite_risk_score`, and others).
- Labels (`remaining_useful_life_days`, `failure_within_30_days`, `failure_within_90_days`).
- A `feature_version` field and a `computed_at` timestamp.

### Predictions and Monitoring Tables

#### `predictions.component_rul_predictions`

| Column | Semantics |
|---|---|
| prediction_id | A unique prediction record |
| record_id, component_serial_number, snapshot_date | Joinable to features for evaluation |
| predicted_rul_days | A point estimate, in days |
| predicted_failure_prob_30d, predicted_failure_prob_90d | Probability scores, from 0 to 1 |
| risk_tier | Categorical: Low, Watch, Elevated, or High |
| scored_at | The timestamp of the scoring run |

#### `monitoring.data_quality_rules`

| Column | Semantics |
|---|---|
| rule_name | For example, "health_score_out_of_range" or "negative_usage_hours" |
| rule_category | Completeness, Validity, Consistency, Uniqueness, or Referential Integrity |
| rule_sql | The WHERE clause identifying failing rows |
| severity | Warning or Critical (a Critical rule blocks promotion to curated) |

#### `monitoring.model_performance_log`

| Column | Semantics |
|---|---|
| model_name, model_version | References `models.model_registry` |
| metric_name | RMSE, MAE, AUC, F1, Precision, or Recall |
| metric_value | The numeric score |
| evaluation_window_start, evaluation_window_end | The date range covered by the metric |

#### `monitoring.alerts`

| Column | Semantics |
|---|---|
| alert_type | Data Quality, Data Drift, Model Performance, or Prediction Volume |
| severity | Info, Warning, or Critical |
| related_entity | Component ID, feature name, model name, and so on |
| acknowledged, acknowledged_by, acknowledged_at | The human review loop |

---

## Setup and Deployment

### Prerequisites

1. **PostgreSQL 15 or later**, with superuser access for extension installation.

   ```bash
   SELECT version();  -- confirm PostgreSQL 15 or later
   ```

2. **Required extensions:**

   ```sql
   CREATE EXTENSION IF NOT EXISTS pgcrypto;           -- gen_random_uuid(), hashing
   CREATE EXTENSION IF NOT EXISTS pg_stat_statements; -- query performance analysis
   CREATE EXTENSION IF NOT EXISTS pgml;               -- PostgresML (in-database ML)
   CREATE EXTENSION IF NOT EXISTS pg_cron;            -- scheduled jobs
   ```

3. **Source data:**
   - `Helios_Component_Health_Dataset.xlsx`, exported to `component_health_dataset.csv`.
   - The file must be accessible from the machine running `psql` (client side `\copy`).

### Installation Steps

#### Step 1: Initialize the Schema and Data Model (Script 01)

```bash
psql -h <postgres_host> -U <admin_user> -d <database> -f 01_schema_and_tables.sql
```

**Output:** 7 schemas, 9 tables, 3 roles, audit triggers, and the data quality rule set.

#### Step 2: Load and Transform Data (Script 02)

```bash
# Adjust the file path in the script if needed (line 19: the \copy command)
psql -h <postgres_host> -U <admin_user> -d <database> -f 02_load_and_transform.sql
```

**Output:**

- `raw.component_health_stg`: the raw extract.
- `curated.dim_aircraft`, `dim_component`, `dim_supplier`: master data.
- `curated.fact_component_health_snapshot`: the curated, partitioned fact table.
- `monitoring.data_quality_results`: the quality control execution log.
- `raw.component_health_quarantine`: rows that failed critical rules.

**Sanity check:**

```sql
SELECT tbl, COUNT(*) FROM (
  SELECT 'dim_aircraft' tbl, COUNT(*) FROM curated.dim_aircraft
  UNION ALL SELECT 'dim_component', COUNT(*) FROM curated.dim_component
  UNION ALL SELECT 'fact', COUNT(*) FROM curated.fact_component_health_snapshot
) x GROUP BY tbl;
```

#### Step 3: Feature Engineering and Model Training (Script 03)

```bash
psql -h <postgres_host> -U <admin_user> -d <database> -f 03_features_and_ml.sql
```

**Output:**

- `features.component_health_features_v1`: the engineered dataset.
- `features.component_health_train` / `validation` / `test`: the temporal splits.
- `models.model_registry`: 3 trained models, with metadata.
- `predictions.component_rul_predictions`: batch scoring results.

**Verify model training:**

```sql
SELECT model_name, model_version, is_active FROM models.model_registry;
```

**Check predictions:**

```sql
SELECT
  COUNT(*) AS total_predictions,
  COUNT(CASE WHEN risk_tier = 'High' THEN 1 END) AS high_risk,
  COUNT(CASE WHEN risk_tier = 'Elevated' THEN 1 END) AS elevated_risk
FROM predictions.component_rul_predictions;
```

#### Step 4: Monitoring, Drift Detection, and Automation (Script 04)

```bash
psql -h <postgres_host> -U <admin_user> -d <database> -f 04_monitoring_and_retraining.sql
```

**Output:**

- `monitoring.model_performance_log`: baseline metrics recorded.
- `monitoring.data_drift_log`: the initial drift baseline.
- `monitoring.alerts`: open alerts raised by the monitoring jobs.
- Scheduled pg_cron jobs (commented out by default, pending manual activation).

**Enable scheduled jobs** (optional, requires pg_cron):

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

## Query Examples and Analytics

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

**Use case:** fleet maintenance prioritization, identifying components requiring immediate or near term replacement.

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

**Use case:** an executive dashboard, showing fleet wide health metrics and aircraft grounding risk.

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

**Use case:** supply chain risk analysis, identifying underperforming suppliers for escalation or corrective action.

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

**Use case:** a model operations dashboard, tracking RMSE, MAE, precision, and recall trends, and identifying degradation that requires retraining.

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

**Use case:** data governance reporting, ensuring data quality before downstream consumption.

### 6. Active Alerts for Escalation

```sql
SELECT * FROM monitoring.vw_open_alerts
WHERE severity IN ('Warning', 'Critical')
ORDER BY severity DESC, raised_at DESC;
```

**Use case:** real time alerting, escalating critical alerts to operations and maintenance teams.

---

## Access Control and Governance

### Role Definitions

| Role | Privileges | Use case |
|---|---|---|
| `role_data_engineer` | Full access to the raw and curated schemas | Data pipeline ownership; dimension and fact table maintenance |
| `role_ml_engineer` | Read access to curated and features; full access to models and predictions | Feature engineering, training, scoring, and retraining |
| `role_bi_reader` | Read only access to curated, features, and predictions | BI tool consumption (Power BI, Tableau, Looker) |
| `role_auditor` | Read only access to the monitoring and mgmt schemas | Compliance auditing and audit trail review |

### Granting Roles

```sql
-- Add users to roles (replace 'username' with an actual PostgreSQL user)
GRANT role_data_engineer TO <username>;
GRANT role_ml_engineer TO <username>;
GRANT role_bi_reader TO <username>;
GRANT role_auditor TO <username>;
```

### Audit Trail

Every INSERT, UPDATE, and DELETE on `curated.fact_component_health_snapshot` is logged to `mgmt.audit_log`:

```sql
SELECT
  audit_id, event_time, db_user, operation, row_pk,
  row_hash  -- an MD5 hash of the row state, for integrity verification
FROM mgmt.audit_log
WHERE schema_name = 'curated' AND table_name = 'fact_component_health_snapshot'
ORDER BY event_time DESC
LIMIT 100;
```

---

## Advanced Topics

### Feature Versioning

Features are versioned by table (for example, `component_health_features_v1`, `component_health_features_v2`):

- **Immutable history:** old feature versions are retained for audit purposes and model reproducibility.
- **Model registry tracking:** each model references its feature table (for example, `features.component_health_features_v1`).
- **A/B testing:** new models can be trained on new feature versions, compared against existing models, and promoted incrementally.

### Handling Class Imbalance

The 30 day and 90 day failure classifiers exhibit severe class imbalance:

- **The 90 day model** has an approximately 9 percent positive rate; recall tuned decision thresholds are recommended, since a lower threshold produces higher recall at the cost of more false positives.
- **The 30 day model** has an approximately 4 percent positive rate; approaches such as SMOTE or class weighting should be considered, with attention paid to precision given the cost of false positives.

**Recommended threshold tuning**, through a holdout validation set:

```sql
-- Vary the threshold and compute precision and recall
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

### Human in the Loop Feedback

High impact predictions, for example those concerning flight critical components, should be reviewed by domain experts:

```sql
-- Record a human override
INSERT INTO models.human_review_overrides
  (record_id, model_id, original_prediction, reviewer_decision, reviewer_id, reviewer_comment)
VALUES
  (12345, 1, '{"risk_tier": "High", "predicted_prob_30d": 0.68}'::jsonb,
   'Confirmed', 'maint_supervisor_001', 'Component inspection confirms imminent wear');
```

These overrides feed directly into the retraining pipeline:

```sql
-- Sample future training sets, stratified by reviewer feedback
SELECT f.* FROM features.component_health_features_v1 f
WHERE EXISTS (
  SELECT 1 FROM models.human_review_overrides h
  WHERE h.record_id = f.record_id
    AND h.reviewer_decision = 'Confirmed'
)
ORDER BY RANDOM() LIMIT 500;
```

### Partitioning and Retention Policies

Monthly partitions enable efficient archival:

```sql
-- Archive an old partition to cold storage (as part of a quarterly review)
-- After moving fact_component_health_snapshot_2023_06 offline:
ALTER TABLE curated.fact_component_health_snapshot
DETACH PARTITION curated.fact_component_health_snapshot_2023_06;

-- Validate and compress before long term storage
VACUUM FULL ANALYZE curated.fact_component_health_snapshot_2023_06;
```

---

## Business Case and Return on Investment

### Key Use Cases

1. **Component health assessment and RUL estimation** (implemented):
   - Centralized component health monitoring across the fleet.
   - Remaining useful life predictions, supporting proactive planning.
   - Risk stratified rankings, for prioritized inspection.

2. **Maintenance optimization** (enabled by use case 1):
   - A shift from calendar based to condition based maintenance.
   - Target: a 15 to 25 percent reduction in unscheduled downtime.
   - Pre positioning spare parts 30, 60, or 90 days ahead of predicted failures.

3. **Supply chain efficiency** (enabled by use cases 1 and 2):
   - Demand forecasting, based on predicted component retirements.
   - Reduced holding costs on excess inventory.
   - Minimized stockouts, by aligning procurement to predicted need.

4. **Regulatory and safety compliance:**
   - An immutable audit trail, supporting 14 CFR Part 121 and EASA audit requirements.
   - Data quality enforcement, which helps prevent unsafe operational decisions.
   - Model governance and explainability, supporting certification bodies.

### Quantified Benefits (Illustrative)

| Metric | Baseline | Target | Driver |
|---|---|---|---|
| Unscheduled downtime | 12 percent of flight hours | 8 to 10 percent | Predictive RUL, combined with a 30 to 60 day warning horizon |
| Spare parts carrying cost | $50 million annually | $35 to $40 million | Improved demand forecasting |
| Maintenance margin | An 18 percent cost overage | 8 to 10 percent | Condition based scheduling, rather than calendar based scheduling |
| Audit findings (compliance) | 2 to 3 per year | Fewer than 1 per year | Automated data quality, together with the audit trail |

---

## Support and Maintenance

### Troubleshooting

**Issue: the feature build is slow, taking more than 10 minutes.**

Add an index on `fact_component_health_snapshot(snapshot_date)` and `dim_component(design_mtbf_hours)`:

```sql
ANALYZE curated.fact_component_health_snapshot;
ANALYZE curated.dim_component;
```

**Issue: a data quality rule is failing at load time.**

Review `monitoring.data_quality_results` for the specific rule and its failing rows:

```sql
SELECT rule_name, rows_checked, rows_failed, pass_rate_pct
FROM monitoring.data_quality_results
WHERE run_at = (SELECT MAX(run_at) FROM monitoring.data_quality_results)
ORDER BY passed, severity DESC;
```

Route the failing rows to quarantine and inspect them:

```sql
SELECT * FROM raw.component_health_quarantine
WHERE quarantined_at > now() - INTERVAL '1 day'
ORDER BY quarantined_at DESC;
```

**Issue: model performance has degraded.**

Check for data drift:

```sql
SELECT * FROM monitoring.data_drift_log
WHERE evaluated_at > now() - INTERVAL '7 days'
AND drift_flag = TRUE
ORDER BY evaluated_at DESC;
```

If drift is detected, trigger retraining:

```sql
SELECT model_name, reason FROM mgmt.retraining_required();
```

### Maintenance Schedule

| Task | Frequency | Owner | Notes |
|---|---|---|---|
| Review open alerts | Daily | Operations and maintenance | Escalate Critical alerts within 2 hours |
| Model performance review | Weekly | ML engineer | Check RMSE and recall trends; adjust thresholds if needed |
| Data drift assessment | Weekly | Data engineer | Investigate shifts greater than 15 percent in key features |
| Retraining validation | Monthly | ML engineer | Retrain if Critical alerts have been raised; A/B test against the current model |
| Audit log review | Quarterly | Compliance officer | Verify immutability; export for the regulatory file |
| Partition management | Monthly, the 1st | Database administrator | Ensure next month's partition has been pre created |

---

## Integration with BI and Analytics Platforms

### Power BI and Tableau

**Primary views for BI consumption:**

1. `predictions.vw_latest_component_risk`: component risk rankings, joinable with aircraft, component, and supplier data.
2. `monitoring.vw_open_alerts`: the active alerts feed.
3. Ad hoc queries against `curated.dim_*` and `monitoring.model_performance_log`.

**Refresh cadence:**

- **Predictions:** batch scored nightly; the Power BI dataset refreshes at 06:00 UTC.
- **Monitoring:** near real time queries, if Power BI is connected directly to PostgreSQL, refreshed every 5 minutes.
- **Dimensions:** refreshed daily, either manually or on a scheduled pull.

**Authentication:** PostgreSQL role based access, for example a `role_bi_reader` user accessed through a Power BI service principal.

### Export Patterns

For air gapped environments or external systems:

```sql
-- Export the latest predictions for an external BI tool
COPY (
  SELECT * FROM predictions.vw_latest_component_risk
  WHERE scored_at >= now() - INTERVAL '1 day'
) TO '/tmp/helios_latest_predictions.csv' WITH (FORMAT csv, HEADER);
```

---

## Future Enhancements and Roadmap

### Phase 2 (Planned)

- **A multi model ensemble.** Combine the XGBoost RUL model with a probabilistic Bayesian model, for uncertainty quantification.
- **An explainability layer.** SHAP values computed directly in SQL, through a PostgresML extension, to explain individual predictions.
- **Real time scoring.** A gRPC or REST API wrapper around PostgresML, for live component health ingestion.
- **Causal inference.** Estimating the impact of a maintenance intervention on component longevity, using instrumental variable estimation.

### Phase 3 (Future)

- **Supply chain integration.** Links to OEM parts databases, for automatic availability checking.
- **Prescriptive analytics.** An optimization engine for cost optimal maintenance scheduling across the fleet.
- **Autonomous retraining.** A fully automated retraining pipeline, incorporating statistical significance tests and canary deployment.

---

## Conclusion

HELIOS represents a production grade, SQL native machine learning platform built on PostgreSQL that delivers measurable business value across maintenance optimization, supply chain efficiency, and regulatory compliance. By bringing data engineering, feature engineering, model training, and monitoring into a single SQL first system, HELIOS eliminates data silos, ensures auditability, and enables rapid iteration on predictive maintenance use cases.

The modular design allows incremental adoption: a team can start with use case one, component health assessment, and scale toward fleet wide predictive maintenance orchestration. The declarative data quality framework and the comprehensive audit trail satisfy enterprise governance requirements while maintaining the agility needed for competitive advantage in aviation operations.

---

## License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.

## Contact and Support

For questions, issues, or contributions:

- **Project owner:** Anthony Chinedu Echem
- **Repository:** [HELIOS_AIRCRAFT_GROUP_IN_DATABASE_ML_PROJECT](https://github.com/ANTHONY-CHINEDU-ECHEM/HELIOS_AIRCRAFT_GROUP_IN_DATABASE_ML_PROJECT)
- **Issues:** GitHub Issues, for bugs, feature requests, and documentation.

---

**Last updated:** September 16, 2026
**Version:** 1.0 (Production Ready)
