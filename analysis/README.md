# Analysis entry point — offline update 2026-10-25

Read ENCODING_CHANGE.md first. The current entry point contains a treatment-encoding correction and has not been refitted in this offline task. The prior code/README/configuration are preserved in archived_before_encoding_fix/. Raw extraction candidates and their unresolved definitions are in the repository root; no actual-source extraction has been validated.

# Sepsis mortality revision analysis

The archived pre-fix workflow was prepared for three author-provided cleaned cohorts. The updated code requires a fresh analysis run before its results can be reported. It does not contain patient records, prediction rows, model objects, raw screening SQL or unavailable clinical extraction logic.

## Run

Use Python 3.12 with the pinned dependencies and R 4.6.1 with svglite 2.2.2. On macOS, LightGBM/XGBoost require a compatible OpenMP runtime, and R Cairo exports require their graphics runtime. Install dependencies in your own environment; do not upload restricted clinical data.

```
python reanalyse.py --data-dir PATH_TO_AUTHORIZED_LOCAL_CLEANED_DATA --out-dir LOCAL_RESULTS
python contrasts.py --out-dir LOCAL_RESULTS
Rscript figures.R LOCAL_RESULTS FIGURES svg
Rscript figures.R LOCAL_RESULTS FIGURES pdf
Rscript figures.R LOCAL_RESULTS FIGURES png
Rscript figures.R LOCAL_RESULTS FIGURES tiff
```

The data directory must contain the three cleaned workbooks with the stored outcome, split labels and predictor/component fields used in the script. MIMIC inputs are the pre-imputation workbook, not the already-imputed workbook. Existing development_80/internal_test_20 labels define 3724/902 patients. Source filenames are located by their non-identifying dataset/version prefixes in the script; adjust only these locators if filenames differ, without changing the analysis rules.

The revised component score is the sum of six exported organ scores. Clinical physiological thresholds and raw timestamp aggregation were not recoverable and must be supplied by the original investigators; this is not a claim of reconstructing standard SOFA. All 5862 cleaned records enter the primary analysis. The timing sensitivity separately removes hospital stays below one day. The single-center archived-total sensitivity uses the alternative stored total only at prediction.

LightGBM was designated primary for the revision; internal outcomes did not tune models or thresholds. Nested CV is 5 outer by 3 inner folds; final development tuning uses 5 folds and log loss. Bootstrap intervals condition on fixed predictions. Local calibrators are evaluated out of fold. AUPRC means average precision. DeLong families are adjusted separately as documented in the manuscript.

The local output subdirectory `private` contains patient-level outcome/prediction arrays and model objects. It must be excluded from any public upload. The supplied aggregate CSV/JSON files contain metrics, curve coordinates, binned calibration, mean absolute SHAP, fold summaries, settings and input hashes only.

Raw cohort-screening and feature-engineering code, source unit and score documentation, verified 24-h eligibility, institution-approved single-center access and a public release URL remain author actions. No public repository is claimed to exist merely because this local package has been prepared.
