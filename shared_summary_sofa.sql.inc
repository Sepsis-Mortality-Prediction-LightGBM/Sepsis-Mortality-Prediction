-- 未经数据库验证 / NOT VALIDATED AGAINST ACTUAL SOURCE DATABASES.

per_time AS (SELECT stay_id,variable,minute,AVG(value) AS value FROM measurements GROUP BY stay_id,variable,minute),
ordered AS (
 SELECT *,ROW_NUMBER() OVER(PARTITION BY stay_id,variable ORDER BY minute) AS first_rn,
 ROW_NUMBER() OVER(PARTITION BY stay_id,variable ORDER BY minute DESC) AS last_rn,
 minute-LAG(minute) OVER(PARTITION BY stay_id,variable ORDER BY minute) AS gap_min FROM per_time
),
stats AS (
 SELECT stay_id,variable,AVG(value) AS mean_value,MIN(value) AS min_value,MAX(value) AS max_value,
 MAX(value) FILTER(WHERE first_rn=1) AS first_value,MAX(value) FILTER(WHERE last_rn=1) AS last_value,
 SUM(value) AS sum_value,COUNT(*) AS measurement_n,MIN(minute) AS first_minute,MAX(minute) AS last_minute,
 MAX(gap_min) AS max_gap_min FROM ordered GROUP BY stay_id,variable
),
wide AS (
 SELECT b.stay_id,
 MAX(mean_value) FILTER(WHERE variable='heart_rate') AS heart_rate_24h_mean,
 MAX(mean_value) FILTER(WHERE variable='map') AS map_24h_mean,
 MAX(mean_value) FILTER(WHERE variable='urine_output') AS urine_output_24h_mean,
 MAX(mean_value) FILTER(WHERE variable='lactate') AS lactate_24h_mean,
 MAX(mean_value) FILTER(WHERE variable='creatinine') AS creatinine_24h_mean,
 MAX(mean_value) FILTER(WHERE variable='glucose') AS glucose_24h_mean,
 MAX(mean_value) FILTER(WHERE variable='inr') AS inr_24h_mean,
 MAX(CASE WHEN measurement_n>=2 THEN last_value-first_value END) FILTER(WHERE variable='lactate') AS lactate_24h_delta,
 MAX(CASE WHEN measurement_n>=2 THEN last_value-first_value END) FILTER(WHERE variable='map') AS map_24h_delta,
 MAX(CASE WHEN measurement_n>=2 THEN last_value-first_value END) FILTER(WHERE variable='urine_output') AS urine_output_24h_delta,
 MAX(min_value) FILTER(WHERE variable='map') AS map_min,
 MAX(min_value) FILTER(WHERE variable='gcs' AND min_value BETWEEN 3 AND 15) AS gcs_min,
 MAX(min_value) FILTER(WHERE variable='platelets') AS platelets_min,
 MAX(max_value) FILTER(WHERE variable='bilirubin') AS bilirubin_max,
 MAX(max_value) FILTER(WHERE variable='creatinine') AS creatinine_max,
 MAX(sum_value) FILTER(WHERE variable='urine_output') AS urine_output_24h_sum,
 MAX(measurement_n) FILTER(WHERE variable='urine_output') AS urine_n,
 MAX(first_minute) FILTER(WHERE variable='urine_output') AS urine_first_minute,
 MAX(last_minute) FILTER(WHERE variable='urine_output') AS urine_last_minute,
 MAX(max_gap_min) FILTER(WHERE variable='urine_output') AS urine_max_gap_min,
 MAX(CASE WHEN first_minute<=120 AND last_minute>=1320 AND max_gap_min<=360 AND sum_value>=0 THEN sum_value END)
 FILTER(WHERE variable='urine_output') AS urine_24h_coverage_proxy_ml
 FROM cohort b LEFT JOIN stats s USING(stay_id) GROUP BY b.stay_id
),
vaso_levels AS (
 SELECT v.*,level,
 CASE WHEN level=4 THEN (drug='dopamine' AND rate>15) OR(drug IN('epinephrine','norepinephrine') AND rate>0.1)
 WHEN level=3 THEN (drug='dopamine' AND rate>5) OR(drug IN('epinephrine','norepinephrine') AND rate>0)
 WHEN level=2 THEN drug IN('dopamine','dobutamine') AND rate>0 ELSE FALSE END AS qualifies
 FROM vaso_intervals v CROSS JOIN(VALUES(2),(3),(4)) l(level) WHERE end_min>start_min
),
vaso_running AS (
 SELECT *,MAX(end_min) OVER(PARTITION BY stay_id,drug,level ORDER BY start_min,end_min ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS previous_end
 FROM vaso_levels WHERE qualifies
),
vaso_islands AS (
 SELECT *,SUM(CASE WHEN previous_end IS NULL OR start_min>previous_end THEN 1 ELSE 0 END)
 OVER(PARTITION BY stay_id,drug,level ORDER BY start_min,end_min) AS island FROM vaso_running
),
vaso_episodes AS (
 SELECT stay_id,drug,level,island,MIN(start_min) AS start_min,MAX(end_min) AS end_min,
 BOOL_AND(duration_recorded) AS duration_recorded FROM vaso_islands GROUP BY stay_id,drug,level,island
),
vaso AS (
 SELECT b.stay_id,MAX(v.level) FILTER(WHERE end_min-start_min>=60 AND v.duration_recorded) AS cv_drug_score,
 EXISTS(SELECT 1 FROM vaso_intervals z WHERE z.stay_id=b.stay_id AND(NOT z.duration_recorded OR z.rate IS NULL)) AS vaso_dose_or_duration_unresolved
 FROM cohort b LEFT JOIN vaso_episodes v USING(stay_id) GROUP BY b.stay_id
),
sofa_inputs AS (
 SELECT w.*,p.pf_supported_min,p.pf_unsupported_min,v.cv_drug_score,v.vaso_dose_or_duration_unresolved
 FROM wide w LEFT JOIN pf p USING(stay_id) LEFT JOIN vaso v USING(stay_id)
),
sofa_components AS (
 SELECT s.*,
 CASE WHEN pf_supported_min<100 THEN 4 WHEN pf_supported_min<200 THEN 3
 WHEN pf_supported_min<300 OR pf_unsupported_min<300 THEN 2
 WHEN pf_supported_min<400 OR pf_unsupported_min<400 THEN 1
 WHEN COALESCE(pf_supported_min,pf_unsupported_min) IS NOT NULL THEN 0 END AS sofa_respiration_24h_new,
 CASE WHEN platelets_min<20 THEN 4 WHEN platelets_min<50 THEN 3 WHEN platelets_min<100 THEN 2
 WHEN platelets_min<150 THEN 1 WHEN platelets_min IS NOT NULL THEN 0 END AS sofa_coagulation_24h_new,
 CASE WHEN bilirubin_max>=12 THEN 4 WHEN bilirubin_max>=6 THEN 3 WHEN bilirubin_max>=2 THEN 2
 WHEN bilirubin_max>=1.2 THEN 1 WHEN bilirubin_max IS NOT NULL THEN 0 END AS sofa_liver_24h_new,
 CASE WHEN vaso_dose_or_duration_unresolved THEN NULL WHEN cv_drug_score IS NOT NULL THEN cv_drug_score
 WHEN map_min<70 THEN 1 WHEN map_min IS NOT NULL THEN 0 END AS sofa_cardiovascular_24h_new,
 CASE WHEN gcs_min<6 THEN 4 WHEN gcs_min<10 THEN 3 WHEN gcs_min<13 THEN 2 WHEN gcs_min<15 THEN 1 WHEN gcs_min=15 THEN 0 END AS sofa_cns_24h,
 CASE WHEN creatinine_max>=5 OR urine_24h_coverage_proxy_ml<200 THEN 4
 WHEN creatinine_max>=3.5 OR urine_24h_coverage_proxy_ml<500 THEN 3
 WHEN creatinine_max>=2 THEN 2 WHEN creatinine_max>=1.2 THEN 1
 WHEN COALESCE(creatinine_max,urine_24h_coverage_proxy_ml) IS NOT NULL THEN 0 END AS sofa_renal_24h_new
 FROM sofa_inputs s
),
sofa_scored AS (
 SELECT s.*,
 sofa_respiration_24h_new+sofa_coagulation_24h_new+sofa_liver_24h_new+sofa_cardiovascular_24h_new+sofa_cns_24h+sofa_renal_24h_new AS sofa_component_sum,
 COALESCE(sofa_respiration_24h_new,0)+COALESCE(sofa_coagulation_24h_new,0)+COALESCE(sofa_liver_24h_new,0)+COALESCE(sofa_cardiovascular_24h_new,0)+COALESCE(sofa_cns_24h,0)+COALESCE(sofa_renal_24h_new,0) AS sofa_missing0_sensitivity,
 (sofa_respiration_24h_new IS NULL)::integer+(sofa_coagulation_24h_new IS NULL)::integer+(sofa_liver_24h_new IS NULL)::integer+
 (sofa_cardiovascular_24h_new IS NULL)::integer+(sofa_cns_24h IS NULL)::integer+(sofa_renal_24h_new IS NULL)::integer AS sofa_missing_components_n
 FROM sofa_components s
)