# The 22 predictors

**未经数据库验证 / NOT VALIDATED.** Definitions below describe the reconstructed candidate code. Historical equivalence remains unverified for every extracted field. No post-extraction imputation is applied by SQL.

| # | Field | Unit | Candidate definition |
|---:|---|---|---|
| 1 | `age` | years | MIMIC: anchor_age + ICU calendar year - anchor_year; eICU age >89 mapped to 91, topcoding retained in cohort output |
| 2 | `bmi_model` | kg/m2 | earliest first-day weight and height, kg/(cm/100)^2; eICU admission values; no clipping/imputation |
| 3 | `charlson_comorbidity_index` | points | MIMIC: maximum Quan disease flags across prior hospitalizations discharged before ICU admission, age points excluded; no prior history -> NULL; index-discharge score exported as audit candidate only. eICU: first24 documented past-history candidate mapping. |
| 4 | `heart_rate_24h_mean` | beats/min | arithmetic mean of timestamp means in [0,1440) minutes; no imputation or distribution-based clipping |
| 5 | `map_24h_mean` | mmHg | arithmetic mean of timestamp means in [0,1440) minutes; no imputation or distribution-based clipping |
| 6 | `urine_output_24h_mean` | mL per recorded event (not mL/h) | arithmetic mean of timestamp-level net urine volumes; true total retained separately; never use mean as 24-h total for SOFA |
| 7 | `lactate_24h_mean` | mmol/L | arithmetic mean of timestamp means in [0,1440) minutes; no imputation or distribution-based clipping |
| 8 | `creatinine_24h_mean` | mg/dL | arithmetic mean of timestamp means in [0,1440) minutes; no imputation or distribution-based clipping |
| 9 | `glucose_24h_mean` | mg/dL | arithmetic mean of timestamp means in [0,1440) minutes; no imputation or distribution-based clipping |
| 10 | `inr_24h_mean` | ratio | arithmetic mean of timestamp means in [0,1440) minutes; no imputation or distribution-based clipping |
| 11 | `mechanical_ventilation_24h` | 0/1 | any documented first24 evidence / interval overlap; 0 means no captured evidence; antibiotic is an order proxy, not confirmed administration |
| 12 | `vasopressor_24h` | 0/1 | any documented first24 evidence / interval overlap; 0 means no captured evidence; antibiotic is an order proxy, not confirmed administration |
| 13 | `rrt_24h` | 0/1 (documented treatment) | any documented first24 evidence / interval overlap; 0 means no captured evidence; antibiotic is an order proxy, not confirmed administration |
| 14 | `antibiotic_24h` | 0/1 (order proxy) | any documented first24 evidence / interval overlap; 0 means no captured evidence; antibiotic is an order proxy, not confirmed administration |
| 15 | `fluid_resuscitation_24h_ml` | mL | documented selected crystalloid/albumin volumes; MIMIC overlap-prorated intervals, eICU individual I/O rows; absence NULL, not automatically zero |
| 16 | `lactate_24h_delta` | mmol/L | last minus first timestamp mean in [0,1440); at least 2 timestamps required; single measurement yields NULL (archival rule unverified) |
| 17 | `map_24h_delta` | mmHg | last minus first timestamp mean in [0,1440); at least 2 timestamps required; single measurement yields NULL (archival rule unverified) |
| 18 | `urine_output_24h_delta` | mL per recorded event | last minus first timestamp mean in [0,1440); at least 2 timestamps required; single measurement yields NULL (archival rule unverified) |
| 19 | `sofa_component_sum` | points | six worst first24 components, each 0–4; missing component yields NULL; missing0 sensitivity exported separately |
| 20 | `sex` | category | F/M/Unknown, same categories as prior model |
| 21 | `admission_source` | category | same harmonization as prior reanalysis, from hospital admission source |
| 22 | `infection_source` | category | MIMIC: Unknown until a first24 source-confirmed infection-site crosswalk is available; discharge-ICD candidate exported only for audit. eICU: first24 diagnosis keyword candidate, fixed site priority; original algorithm unavailable. |

MIMIC infection_source intentionally remains Unknown without an available-at-landmark source; a discharge-diagnosis candidate is exported separately for audit. Prior-admission CCI and eICU past-history candidate mappings are explicit replacements for unavailable original logic. These decisions must not be represented as exact recovery of the paper’s historical variables.

Mean values are arithmetic means across timestamp-level means. Delta is last minus first with at least two timestamps; it is neither a percentage nor a 6h-to24h difference. Urine is mL per recorded event; a true daily sum is separately exported for SOFA. Antibiotic features are order proxies, and the shared name dictionary includes anti-infectives such as antifungals. Fluid volume cannot establish the indication “resuscitation” without additional documentation.
