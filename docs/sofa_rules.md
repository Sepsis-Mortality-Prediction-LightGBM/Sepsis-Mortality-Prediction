# SOFA calculation rules and source mapping

**未经数据库验证 / NOT VALIDATED AGAINST ACTUAL SOURCE DATABASES.** Classical six-domain candidate reconstruction; not proof of the historical “modified SOFA” algorithm. Main first-day summaries use `[ICU admission, +24h)` and worst qualifying values. Source-availability timestamps are checked where available. Sepsis ascertainment separately uses the pinned upstream rolling hourly SOFA; it is not interchangeable with the predictor's strict first-day score.

| Component | 0 | 1 | 2 | 3 | 4 |
|---|---|---|---|---|---|
| Respiration, PaO2/FiO2 mmHg | ≥400 | <400 | <300 | <200 with invasive support | <100 with invasive support |
| Coagulation, platelets ×10³/µL | ≥150 | <150 | <100 | <50 | <20 |
| Liver, bilirubin mg/dL | <1.2 | ≥1.2 | ≥2.0 | ≥6.0 | ≥12.0 |
| Cardiovascular | MAP≥70, no qualifying drug | MAP<70 | dopamine>0 to5 or dobutamine>0 | dopamine>5 to15, or epinephrine/norepinephrine>0 to0.1 | dopamine>15, or epinephrine/norepinephrine>0.1 |
| CNS, GCS | 15 | 13–14 | 10–12 | 6–9 | <6 |
| Renal, creatinine mg/dL or daily urine mL | Cr<1.2 | Cr≥1.2 | Cr≥2.0 | Cr≥3.5 or urine<500 | Cr≥5.0 or urine<200 |

The score is the highest applicable row category, not sequential summation within an organ. All cardiovascular doses above are **µg/kg/min** and require at least 60 minutes of qualifying continuous coverage; adjacent intervals merge, overlapping time is not counted twice. Zero-dose epinephrine/norepinephrine does not confer three points. The urine cutoffs apply to a 24-hour **total**, never the mean event volume or an assumed mean×24. Exact boundary behavior is tested directly from the SQL CASE expression AST without a database connection.

| Input | MIMIC source | eICU source | Candidate handling |
|---|---|---|---|
| PaO2/FiO2 | pinned `bg`, labevents; ventilation intervals | `lab` paO2 and FiO2 at same offset; respiratorycare airway/vent intervals | no SpO2 replacement; FiO2 as fraction; 3–4 only with time-linked support |
| Platelets/bilirubin/creatinine | labevents 51265/50885/50912 | `platelets x 1000`/`total bilirubin`/`creatinine` | min platelets, max bilirubin/creatinine; mg/dL and documented unit conversions |
| MAP | chartevents 220052/220181/225312 | vitalperiodic systemicmean, aperiodic noninvasivemean | lowest eligible value; noninvasive fallback at unmatched offsets |
| Pressors/inotrope | pinned dose concepts plus raw inputevents availability checks | infusiondrug dose text and units | eICU point records cannot establish continuous infusion duration; unresolved component remains NULL |
| GCS | complete eye/verbal/motor entries at same timestamp | valid recorded nursecharting total | no default-normal CNS predictor; sedation-before-baseline cannot be established |
| Urine | net urine outputevents, irrigation correction | exact upstream urinary I/O label list, individual cell values | sum mL; coverage proxy first≤2h, last≥22h, max gap≤6h; proxy is not proof of complete collection |

If an organ input is missing, its component remains NULL. A strict total is NULL if any component is missing. `sofa_missing0_sensitivity` is separately labelled and may not replace the strict total silently. Creatinine-only renal scores can underestimate unobserved oliguria. RRT is an independent predictor and is not assigned an invented classical SOFA point rule. Respiration without captured support may also understate dysfunction if support recording is incomplete.

The archived `sofa_component_sum` used by the existing ML analysis is the sum of six stored component fields. It is distinct from a verified physiological SOFA reconstruction. Newly computed components must be compared individually, and all dependent models/tables/figures must be rerun if verified corrections change the data.
