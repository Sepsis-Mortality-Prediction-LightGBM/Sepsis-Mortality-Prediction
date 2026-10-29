# Cohort definitions and screening flow

**未经数据库验证 / NOT VALIDATED AGAINST ACTUAL SOURCE DATABASES.** The methods and cleaned datasets do not uniquely determine the unavailable historical extraction algorithm. These scripts are a transparent reconstruction. Target counts are archival comparators, never filters or optimization targets.

| Rule | Manuscript | MIMIC-IV SQL | eICU SQL | Remaining boundary |
|---|---|---|---|---|
| Adult | age ≥18 | ICU year − anchor_year + anchor_age | numeric age; >89 maps to 91 with flag | original age construction not proven |
| First ICU | first admission | first chronological ICU per person before adult/sepsis filtering | first unit within hospital episode by hospital-admission offset | global chronological first eICU hospitalization not identifiable |
| Sepsis | MIMIC Sepsis-3; eICU diagnosis/ICD-9 | pinned suspicion-of-infection + hourly SOFA≥2; event times in first24; baseline assumed 0 | diagnostic text/ICD-9, captured separately from timing | observed baseline SOFA increase unavailable; later confirmation flagged |
| Outcome | hospital mortality present | hospital_expire_flag 0/1 | hospital discharge status Alive/Expired | source outcome must be compared by ID |
| Timestamps | exclude abnormal timestamps | hospitalization and ICU timestamp checks | admission/discharge offset checks | actual timestamp quality unverified |
| First24 observation | predictors available 0–24h; eICU ICU LOS≥24h | ICU observation ≥24h; hospital observation/death beyond landmark | analogous offset rules | retain failing candidates with flags for audit |
| Core predictors | sufficient core data | proposed HR+MAP completeness flag, exported only | same | exact historical core-variable list and threshold absent; not invented |

`eligible_pre_landmark` marks candidate adult first-ICU sepsis records. Predictor SQL exports these candidates with `eligible_24h`; it does not silently discard failed landmark records. The future file validator reports: all ICU stays → first stay as observable → adult → operational sepsis → known outcome → valid timestamps → 24h landmark. The original unspecified core-completeness filter is not claimed to be reconstructed.

Final archival counts: MIMIC 4,626/1,447 deaths; eICU 1,057/312 deaths. Existing MIMIC split labels are 3,724 development/902 internal test. Counts are checked, not hard-coded into cohort membership. Full participant-level outcomes and private difference tables must stay within the authorized local environment.
