# Future source-database validation workflow

Current status: **未经数据库验证**. No database connection is required or made by `validate_extraction.py`; it operates on files produced in a future authorized environment. Database execution is an optional, separately guarded operation, not part of the offline workflow.

1. Freeze the actual data release, SQL/dictionary revision, extraction date and source schemas in a local run record. The current version labels 2.2/2.0 come from the manuscript and are not proof of the installation’s release.
2. When an authorized environment becomes available, use the SELECT-only runner to export all screening rows, candidate predictor rows and SOFA input/component rows within one repeatable-read, read-only snapshot. `--execute-authorized` is mandatory even for EXPLAIN; no current task invokes it.
3. Run the file validator against the original **pre-imputation** MIMIC workbook and eICU `Modified_data` sheet. Known Yes/No treatment encodings are converted explicitly to 0/1. Missing remains missing; unrecognized encodings stop validation. Native eICU stay keys require a verified one-to-one crosswalk if the archived aliases are artificial.
4. Review `sample_size_comparison.csv`, `screening_flow.csv`, numeric distribution summaries (mean/SD/quantiles/range, standardized mean difference, empirical KS D), categorical counts and proportions, and `missingness_comparison.csv`. Distributions are described for the whole candidate export and the eligible 24h subset separately. They are not statistical tests of equivalence.
5. Review patient-level source membership and first failed inclusion/exclusion stage in the private selection file; compare person/hospital/ICU keys, outcomes, the 22 variables, null masks and all six components in the private difference files. Reuse existing development/test labels by ICU ID, never redraw a favorable split.
6. Classify discrepancies (release, ID mapping, eligibility, timing, units, label dictionary, aggregation, missingness, outcome or SOFA). Record the decision and source evidence in the private resolution form. Intentional corrections may validly differ from the archival data, but they require transparent adjudication and downstream model/table/figure updates. Do not alter rules to force n=4626/1057 or old results.

```bash
# FILE COMPARISONS ONLY — no connection is made by this command:
python scripts/validate_extraction.py --cohort mimic --original LOCAL_PREIMPUTATION_MIMIC.xlsx --reextracted LOCAL_EXPORT/private/mimic_predictors.csv --screening LOCAL_EXPORT/private/mimic_cohort.csv --out LOCAL_VALIDATION
python scripts/validate_extraction.py --cohort eicu --original LOCAL_EICU.xlsx --reextracted LOCAL_EXPORT/private/eicu_predictors.csv --screening LOCAL_EXPORT/private/eicu_cohort.csv --out LOCAL_VALIDATION
```

An exit code 2 indicates failed row-level, sample-size or patient-selection checks. Even a successful file comparison is explicitly labelled as insufficient to establish source-database validation or scientific validity. A supplied execution manifest is recorded as provenance; it is not independently authenticated by the file validator. A future final report must connect an actual source run, agreed definitions and resolved discrepancies.

The aggregate archival reference profiles are supplied as comparison baselines, not validated ground truth. The known MIMIC renal-score and eICU summary inconsistencies remain unresolved source questions. Patient-level differences, crosswalks, prediction rows and models must stay outside the GitHub package.
