# v0.2-offline — 2026-10-25

- Added no-connection static PostgreSQL/schema/CTE/22-output audit and socket-blocked offline tests.
- Added automatic file validation of sample counts, sequential screening, original patient membership, numeric/categorical distributions, missingness, outcomes and paired values.
- Added aggregate archival reference profiles with explicit comparator-only status.
- Made all six extraction queries explicitly “未经数据库验证”; documented cohort, predictor, SOFA and version limitations.
- Organized separate offline, analysis, future database and optional synthetic-test dependencies; default CI is offline only.
- Corrected eICU Yes/No treatment encoding in the main analysis entry point; preserved exact earlier source. No model results were rerun or replaced.
- Added an English R3.3 response without a fabricated public URL or extraction-replication claim.
- No database connection, source-data extraction, public repository upload or patient-level publication was performed in this task.
