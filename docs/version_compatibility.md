# Offline SQL/version compatibility audit

**未经数据库验证 / NOT VALIDATED AGAINST ACTUAL SOURCE DATABASES.**

- Intended data releases: MIMIC-IV 2.2 and eICU-CRD 2.0, as stated in the manuscript. The actual original installation/version has not been independently inspected.
- Intended SQL engine: PostgreSQL 14 or later. The package is not a BigQuery dialect and is not claimed to run unchanged on BigQuery, MySQL or SQL Server.
- Current offline checks: PostgreSQL AST parsing; single SELECT/no data-modifying construct; relation and column lookup against the bundled official DDL snapshots; CTE projection/alias/correlated-scope references; exact presence of the 22 predictor outputs; conservative inventory of PostgreSQL built-in functions. The reports enumerate source tables, function names and checked column references per query, with SQL hashes.
- Known portability adaptation: the upstream generated hourly grid is expressed with LATERAL generate_series, avoiding a generate_series-in-SELECT/UNNEST mismatch. Blood-gas storetime is retained in the derived projection for first-day predictor availability checks. The original upstream files and MIT notices remain in third_party/.
- Limits: static checks cannot prove installed release identity, runtime data types/units, dictionary coverage, timestamp completeness, execution plans, source permissions, cohort membership or biological correctness. They do not produce source patient records.
- The previous 2026-10-24 PostgreSQL 16.2 empty/synthetic checks are archived only as synthetic evidence. They were not repeated in the current offline task and are not tests against the real research databases.
