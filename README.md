# Sepsis mortality reproducibility package — v0.2-offline

**未经数据库验证 / NOT VALIDATED AGAINST THE ACTUAL SOURCE DATABASES.**

This repository contains the offline work for reviewer R3.3: cohort-screening and 22-predictor SQL, SOFA rules, machine-learning/figure code, dependencies, aggregate archival reference profiles and future file-validation scripts. The SQL is reconstructed from the manuscript and available cleaned files; it is not the recovered historical extraction code. No source-database run, source-data replication or completed public GitHub deposit is claimed.

## Start here — offline only

```bash
python -m venv .venv-offline
# Activate the environment for your OS, then:
python -m pip install -r requirements.txt
python scripts/static_sql_audit.py
python scripts/run_offline_checks.py
```

These commands use no database service or clinical records. `run_offline_checks.py` rejects all socket creation while running the tests. The default GitHub Actions workflow runs only these offline checks; it has no database service, credential or patient dataset. Installing dependencies in a future environment may use the package index; the authoring task itself performed the current checks with existing local dependencies.

## Package map

| File/folder | Purpose |
|---|---|
| `sql/01_mimic_cohort.sql`, `02_eicu_cohort.sql` | all-stay screening exports with sequential eligibility evidence |
| `sql/03_mimic_22_predictors.sql`, `04_eicu_22_predictors.sql` | 22 predictor fields plus eligibility, timing and provenance diagnostics |
| `sql/05_mimic_sofa.sql`, `06_eicu_sofa.sql` | physiological summaries, six components and strict/missing-as-zero sensitivity totals |
| `feature_contract.csv`, `docs/predictor_definitions.md` | units, aggregation, coding and unresolved historical-equivalence boundaries |
| `docs/cohort_definitions.md`, `docs/sofa_rules.md` | cohort criteria and explicit organ-score rules |
| `scripts/static_sql_audit.py` | PostgreSQL parser, table/column/CTE/output checks against bundled DDL |
| `scripts/validate_extraction.py`, `reconcile.py` | future exported-file comparisons; no database connection |
| `scripts/run_postgres.py` | future optional read-only export; explicit `--execute-authorized` required |
| `reference/` | aggregate summaries of existing cleaned cohorts, labelled archival comparators |
| `analysis/` | current analysis entry point, figure script, dependencies and pre-fix provenance snapshot |
| `analysis/ENCODING_CHANGE.md` | treatment-encoding correction and need for an analysis rerun |
| `docs/R3_3_response.md` | English author response with precise completed/pending status |
| `validation/`, `VALIDATION_STATUS.json` | static/offline checks and status, not real source-run evidence |
| `third_party/`, `upstream_provenance.json` | pinned source concepts and MIT notices |

## Data and dialect

The manuscript specifies **MIMIC-IV 2.2** and **eICU-CRD 2.0**; actual original source-release identity still requires extraction records. Official access is through [MIMIC-IV 2.2](https://physionet.org/content/mimiciv/2.2/) and [eICU-CRD 2.0](https://physionet.org/content/eicu-crd/2.0/), with credentialing, required training and the applicable DUA. The code package contains no patient-level datasets, crosswalks, predictions, models or connection credentials.

Target SQL engine: PostgreSQL 14+. Source schemas default to `mimiciv_hosp`, `mimiciv_icu`, `eicu_crd`; all MIMIC derived dependencies are inlined as CTEs, so the shipping queries require only SELECT permissions and no derived-table creation. Original reference SQL in third_party/ and schema fixtures may contain DDL; they are not production extraction commands. PostgreSQL-to-BigQuery translation is not provided. See docs/version_compatibility.md for the exact scope and limits of offline compatibility checks.

## Historical-equivalence limits

The exact historical core-completeness rule, infection-site mapping, dynamic-feature definitions and modified-SOFA source algorithm are unavailable. Candidate choices are explicit. MIMIC infection_source stays Unknown without a verified first-day source; the discharge-ICD candidate is audit-only. MIMIC CCI uses diagnoses from completed prior admissions; absent history remains missing. eICU first ICU is identifiable within a hospital episode, not globally across all hospitalizations. Means and last-minus-first deltas use timestamp means; urine event means are never treated as daily totals. SOFA preserves missing components and uses explicit urine coverage, invasive-support and qualifying drug-duration rules. See the cohort, predictor and SOFA documents before interpreting a field as equivalent to the original study variable.

The archival reference counts are 4,626 MIMIC patients/1,447 deaths and 1,057 eICU patients/312 deaths. Existing MIMIC split labels are 3,724/902. These are comparison values, not SQL inclusion filters. The prior local audit found a MIMIC renal-score pattern consistent with an invalid mean-volume substitution and eICU summary inconsistencies. The archival profiles are therefore not validated ground truth.

## Analysis code and environments

The original cleaned-workbook analysis source is preserved in `analysis/archived_before_encoding_fix/`. The current `analysis/reanalyse.py` adds explicit normalization of eICU Yes/No treatment flags, which would otherwise be coerced to missing by the previous code. Original workbooks are unchanged. **Model outputs have not been regenerated after this correction**, and old metrics/figures must not be attributed to the corrected entry point.

Use a separate Python 3.12 environment with `analysis/requirements.txt`; its recorded analysis dependencies differ from the offline validator environment. R figure generation uses the recorded R 4.6.1 and svglite 2.2.2; `analysis/requirements.R` checks versions and installs nothing. Cairo/font/OpenMP requirements are documented in analysis/README.md. No dependency installation or ML refit is needed for offline package checks.

```bash
# Separate analysis environment, locally held cleaned workbooks only:
python analysis/reanalyse.py --data-dir LOCAL_CLEANED_WORKBOOKS --out-dir LOCAL_ANALYSIS_RESULTS
python analysis/contrasts.py --out-dir LOCAL_ANALYSIS_RESULTS
Rscript analysis/figures.R LOCAL_ANALYSIS_RESULTS LOCAL_FIGURES svg
```

Inputs: the pre-imputation MIMIC workbook, eICU Modified_data workbook and institutional 179-patient workbook. File locators use documented prefixes; no private path is hard-coded. The existing analysis expects the archived split labels. Applying newly reconstructed SQL outputs requires resolved definitions, aligned IDs and a documented updated analysis plan; do not rename CSVs to bypass that review. Clinical results still require resolution of the source-data questions.

## Future source execution and automatic validation

No current workflow connects to a database. Optional future execution requires a legal institution-approved environment and separate dependencies from `requirements-database.txt`; the runner uses local libpq configuration and never accepts a password in the command line. It is disabled unless `--execute-authorized` is supplied. Do not run the optional database tests as part of offline checking.

The normal validation entry point operates only on future locally exported files:

```bash
python scripts/validate_extraction.py --cohort mimic --original LOCAL_PREIMPUTATION_MIMIC.xlsx --reextracted LOCAL_EXPORT/private/mimic_predictors.csv --screening LOCAL_EXPORT/private/mimic_cohort.csv --out LOCAL_VALIDATION
```

It reports candidate and 24h-subset n/deaths, sequential inclusion/exclusion counts, original-patient source membership, numeric distributions, categorical counts, missingness, ID sets and individual value/component differences. Patient-level output stays in private/. Known Yes/No encodings are normalized without treating missing as zero. Optional verified crosswalks must be one-to-one. See docs/validation_workflow.md for the full workflow, exit codes and discrepancy resolution. Even successful file comparisons do not establish that the original raw extraction has been reproduced.

## Publication status

The local ZIP `Supplementary_Code_R3_3_v0.2.zip` is ready for repository review/upload. A local archive is not a public GitHub deposit. Actual repository URL/release metadata and project-specific licensing/attribution are still pending; no URL, DOI or license grant is invented. Retain all upstream notices. Exclude clinical files, private comparisons, trained models and connection settings from public uploads. The R3.3 response states precisely that code packaging/offline checks are complete while public deposition and actual-source validation remain outstanding.
