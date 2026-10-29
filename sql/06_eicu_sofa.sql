-- 未经数据库验证 / NOT VALIDATED AGAINST THE ACTUAL SOURCE DATABASES.
-- Offline reconstruction v0.2 (2026-10-25); no original extraction reproduction is claimed.
-- Reconstructed extraction pipeline v0.1 (2026-10-24); PostgreSQL 14+.
-- MIMIC-IV 2.2 / eICU-CRD 2.0. No patient identifiers are hard-coded.
-- Read-only SELECT. Definitions/provenance limits are in README and feature_contract.csv.
-- This is newly reconstructed code, not the unavailable original extraction script.
WITH

base AS (
 SELECT p.*,
 CASE WHEN TRIM(p.age) IN('> 89','>89') THEN 91
 WHEN TRIM(p.age) ~ '^[0-9]+$' THEN TRIM(p.age)::integer ELSE NULL END AS age_numeric,
 ROW_NUMBER() OVER(PARTITION BY patienthealthsystemstayid ORDER BY hospitaladmitoffset DESC,unitvisitnumber,patientunitstayid) AS first_hospital_icu_rn,
 COUNT(*) OVER(PARTITION BY uniquepid) AS recorded_unit_count_per_person
 FROM eicu_crd.patient p
),
sepsis_events AS (
 SELECT d.patientunitstayid, MIN(d.diagnosisoffset) AS sepsis_first_offset,
 COUNT(*) FILTER(WHERE d.diagnosisoffset>=0 AND d.diagnosisoffset<1440) AS first24_sepsis_records
 FROM eicu_crd.diagnosis d
 WHERE LOWER(d.diagnosisstring) ~ '(^|[| /])(sepsis|septic shock|septicemia)([| /]|$)'
 OR REPLACE(COALESCE(d.icd9code,''),'.','') ~ '(^|[,; ]+)(038[0-9]*|99591|99592|78552)([,; ]|$)'
 GROUP BY d.patientunitstayid
),
cohort AS (
 SELECT 'eicu'::text AS data_source,b.uniquepid::text AS subject_id,b.patienthealthsystemstayid::bigint AS hadm_id,
 b.patientunitstayid::bigint AS stay_id,b.hospitalid,
 CASE WHEN b.gender='Female' THEN 'F' WHEN b.gender='Male' THEN 'M' ELSE 'Unknown' END AS gender,
 b.age_numeric AS age,b.age AS age_original,(TRIM(b.age) IN('> 89','>89')) AS age_topcoded,
 b.admissionweight,b.admissionheight,b.hospitaladmitsource AS admission_location,
 b.hospitaladmitoffset,b.unitdischargeoffset,b.hospitaldischargeoffset,
 CASE WHEN b.hospitaldischargestatus='Expired' THEN 1
 WHEN b.hospitaldischargestatus='Alive' THEN 0 ELSE NULL END AS inhospital_mortality,
 b.first_hospital_icu_rn,b.recorded_unit_count_per_person,s.sepsis_first_offset,s.first24_sepsis_records,
 (b.first_hospital_icu_rn=1 AND b.age_numeric>=18 AND s.patientunitstayid IS NOT NULL) AS eligible_pre_landmark,
 (b.first_hospital_icu_rn=1 AND b.age_numeric>=18 AND s.patientunitstayid IS NOT NULL
 AND b.hospitaldischargestatus IN('Alive','Expired') AND b.hospitaladmitoffset<=0
 AND b.unitdischargeoffset>=1440 AND b.hospitaldischargeoffset>1440) AS eligible_24h,
 (b.hospitaldischargeoffset-b.hospitaladmitoffset)/1440.0 AS hospital_los_days,
 b.unitdischargeoffset/1440.0 AS icu_los_days
 FROM base b LEFT JOIN sepsis_events s ON b.patientunitstayid=s.patientunitstayid
),
ec_uo AS (
with uo as
(
select
  patientunitstayid
  , intakeoutputoffset
  , outputtotal
  , cellvaluenumeric
  , case
    when cellpath not like 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|%' then 0
    when cellpath in
    (
      'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|Urine' -- most data is here
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|3 way foley'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|3 Way Foley'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|Actual Urine'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|Adjusted total UO NOC end shift'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|BRP (urine)'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|BRP (Urine)'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|condome cath urine'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|diaper urine'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|inc of urine'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|incontient urine'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|Incontient urine'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|Incontient Urine'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|incontinence of urine'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|Incontinence-urine'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|incontinence/ voids urine'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|incontinent of urine'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|INCONTINENT OF URINE'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|Incontinent UOP'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|incontinent urine'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|Incontinent (urine)'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|Incontinent Urine'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|incontinent urine counts'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|incont of urine'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|incont. of urine'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|incont. of urine count'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|incont. of urine count'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|incont urine'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|incont. urine'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|Incont. urine'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|Incont. Urine'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|inc urine'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|inc. urine'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|Inc. urine'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|Inc Urine'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|indwelling foley'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|Indwelling Foley'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|Straight Catheter-Foley'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|Straight Catheterization Urine'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|Straight Cath UOP'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|straight cath urine'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|Straight Cath Urine'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|strait cath Urine'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|Suprapubic Urine Output'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|true urine'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|True Urine'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|True Urine out'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|unmeasured urine'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|Unmeasured Urine'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|unmeasured urine output'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|Urethal Catheter'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|Urethral Catheter'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|urinary output 7AM - 7 PM'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|urinary output 7AM-7PM'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|urine'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|URINE'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|URINE'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|URINE CATHETER'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|Intermittent/Straight Cath (mL)'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|straightcath'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|straight cath'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|Straight cath'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|Straight  cath'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|Straight Cath'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|Straight  Cath'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|Straight Cath'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|Straight Cath''d'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|straight cath daily'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|straight cathed'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|Straight Cathed'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|Straight Catheter-Foley'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|Straight catheterization'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|Straight Catheterization Urine'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|Straight Catheter Output'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|Straight Catheter-Straight Catheter'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|straight cath ml''s'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|Straight cath ml''s'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|Straight Cath Q6hrs'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|Straight caths'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|Straight Cath UOP'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|straight cath urine'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|Straight Cath Urine'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|Urine Output-straight cath'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|Urine-straight cath'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|Urine Straight Cath'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|Condom Catheter'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|condom catheter'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|condome cath urine'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|condom cath'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|Condom Cath'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|CONDOM CATHETER OUTPUT'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|Urine via condom catheter'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|Urine-foley'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|Urine- foley'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|Urine- Foley'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|Urine foley catheter'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|Urine, L neph:'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|Urine (measured)'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|urine output'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|Urine Output-external catheter'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|Urine Output-foley'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|Urine Output-Foley'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|Urine Output-Foley'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|Urine Output-FOLEY'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|Urine Output-Foley cath'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|Urine Output-FOLEY CATH'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|Urine Output-foley catheter'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|Urine Output-Foley Catheter'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|Urine Output-FOLEY CATHETER'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|Urine Output-Foley Output'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|Urine Output-Fpley'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|Urine Output-Ileoconduit'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|Urine Output-left nephrostomy'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|Urine Output-Left Nephrostomy'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|Urine Output-Left Nephrostomy Tube'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|Urine Output-LEFT PCN TUBE'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|Urine Output-L Nephrostomy'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|Urine Output-L Nephrostomy Tube'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|Urine Output-Nephrostomy'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|Urine Output-right nephrostomy'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|Urine Output-RIGHT Nephrouretero Stent Urine Output'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|Urine Output-R nephrostomy'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|Urine Output-R Nephrostomy'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|Urine Output-R. Nephrostomy'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|Urine Output-R Nephrostomy Tube'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|Urine Output-Rt Nephrectomy'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|Urine Output-stent'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|Urine Output-straight cath'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|Urine Output-suprapubic'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|Urine Output-Texas Cath'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|Urine Output-Urine'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|Urine Output-Urine Output'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|Urine, R neph:'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|Urine-straight cath'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|Urine Straight Cath'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|urine (void)'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|Urine- void'
    , 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|Urine, void:'
    ) then 1
    when cellpath ilike 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|foley%'
    AND lower(cellpath) not like '%pacu%'
    AND lower(cellpath) not like '%or%'
    AND lower(cellpath) not like '%ir%'
      then 1
    when cellpath like 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|Output%Urinary Catheter%' then 1
    when cellpath like 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|Output%Urethral Catheter%' then 1
    when cellpath like 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|Urine Output (mL)%' then 1
    when cellpath like 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|Output%External Urethral%' then 1
    when cellpath like 'flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|Urinary Catheter Output%' then 1
  else 0 end as cellpath_is_uo
from eicu_crd.intakeoutput WHERE intakeoutputentryoffset<=1440
)
select
  patientunitstayid
  , intakeoutputoffset as chartoffset
  , max(outputtotal) as outputtotal
  , sum(cellvaluenumeric) as urineoutput
from uo
where uo.cellpath_is_uo = 1
and cellvaluenumeric is not null
group by patientunitstayid, intakeoutputoffset
order by patientunitstayid, intakeoutputoffset
),
ec_history AS (SELECT patientunitstayid,LOWER(CONCAT_WS(' ',pasthistorypath,pasthistoryvalue,pasthistoryvaluetext)) AS history_text FROM eicu_crd.pasthistory WHERE pasthistoryoffset<=1440 AND pasthistoryenteredoffset<=1440 AND LOWER(COALESCE(pasthistoryvalue,'')) NOT IN('no','not performed','not obtainable','no health problems')),
ec_flags AS (SELECT patientunitstayid,
MAX(CASE WHEN history_text ~ 'myocardial infarct|(^|[^a-z])mi([^a-z]|$)' THEN 1 ELSE 0 END) AS myocardial_infarct,
MAX(CASE WHEN history_text ~ 'congestive heart failure|(^|[^a-z])chf([^a-z]|$)' THEN 1 ELSE 0 END) AS congestive_heart_failure,
MAX(CASE WHEN history_text ~ 'peripheral vascular|peripheral arterial|aortic aneurysm' THEN 1 ELSE 0 END) AS peripheral_vascular_disease,
MAX(CASE WHEN history_text ~ 'cerebrovascular|stroke|transient ischemic' THEN 1 ELSE 0 END) AS cerebrovascular_disease,
MAX(CASE WHEN history_text ~ 'dementia|alzheimer' THEN 1 ELSE 0 END) AS dementia,
MAX(CASE WHEN history_text ~ 'copd|chronic obstructive|chronic pulmonary' THEN 1 ELSE 0 END) AS chronic_pulmonary_disease,
MAX(CASE WHEN history_text ~ 'rheumatoid|lupus|scleroderma|connective tissue' THEN 1 ELSE 0 END) AS rheumatic_disease,
MAX(CASE WHEN history_text ~ 'peptic ulcer|gastric ulcer|duodenal ulcer' THEN 1 ELSE 0 END) AS peptic_ulcer_disease,
MAX(CASE WHEN history_text ~ 'cirrhosis|chronic hepatitis' THEN 1 ELSE 0 END) AS mild_liver_disease,
MAX(CASE WHEN history_text ~ 'diabetes' THEN 1 ELSE 0 END) AS diabetes_without_cc,
MAX(CASE WHEN history_text ~ 'diabetes.*(nephropathy|retinopathy|neuropathy|organ damage)' THEN 1 ELSE 0 END) AS diabetes_with_cc,
MAX(CASE WHEN history_text ~ 'paraplegia|hemiplegia|quadriplegia' THEN 1 ELSE 0 END) AS paraplegia,
MAX(CASE WHEN history_text ~ 'chronic renal failure|end.?stage renal|chronic kidney disease|dialysis dependent' THEN 1 ELSE 0 END) AS renal_disease,
MAX(CASE WHEN history_text ~ 'cancer|malignan|leukemia|lymphoma' THEN 1 ELSE 0 END) AS malignant_cancer,
MAX(CASE WHEN history_text ~ 'portal hypertension|hepatic failure|esophageal varices' THEN 1 ELSE 0 END) AS severe_liver_disease,
MAX(CASE WHEN history_text ~ 'metasta' THEN 1 ELSE 0 END) AS metastatic_solid_tumor,
MAX(CASE WHEN history_text ~ '(^|[^a-z])aids([^a-z]|$)|hiv.*(disease|complication)' THEN 1 ELSE 0 END) AS aids
FROM ec_history GROUP BY patientunitstayid),
ec_cci AS (SELECT *, myocardial_infarct+congestive_heart_failure+peripheral_vascular_disease+cerebrovascular_disease+dementia+chronic_pulmonary_disease+rheumatic_disease+peptic_ulcer_disease+GREATEST(mild_liver_disease,3*severe_liver_disease)+GREATEST(diabetes_without_cc,2*diabetes_with_cc)+2*paraplegia+2*renal_disease+GREATEST(2*malignant_cancer,6*metastatic_solid_tumor)+6*aids AS cci_no_age FROM ec_flags),

lab_ranked AS (
 SELECT l.*,ROW_NUMBER() OVER(PARTITION BY patientunitstayid,labname,labresultoffset
 ORDER BY labresultrevisedoffset DESC,labid DESC) AS rn
 FROM eicu_crd.lab l WHERE labresultoffset>=0 AND labresultoffset<1440 AND labresultrevisedoffset<=1440
),
measurements AS (
 SELECT v.patientunitstayid::bigint AS stay_id,v.observationoffset::double precision AS minute,x.variable,x.value::double precision AS value
 FROM eicu_crd.vitalperiodic v CROSS JOIN LATERAL(VALUES('heart_rate',v.heartrate),('map',v.systemicmean)) x(variable,value)
 WHERE v.observationoffset>=0 AND v.observationoffset<1440 AND x.value>0
 UNION ALL
 SELECT v.patientunitstayid,v.observationoffset,'map',v.noninvasivemean
 FROM eicu_crd.vitalaperiodic v WHERE v.observationoffset>=0 AND v.observationoffset<1440 AND v.noninvasivemean>0
 AND NOT EXISTS(SELECT 1 FROM eicu_crd.vitalperiodic x WHERE x.patientunitstayid=v.patientunitstayid
 AND x.observationoffset=v.observationoffset AND x.systemicmean>0)
 UNION ALL
 SELECT l.patientunitstayid,l.labresultoffset,
 CASE l.labname WHEN 'lactate' THEN 'lactate' WHEN 'creatinine' THEN 'creatinine' WHEN 'glucose' THEN 'glucose'
 WHEN 'PT - INR' THEN 'inr' WHEN 'platelets x 1000' THEN 'platelets' WHEN 'total bilirubin' THEN 'bilirubin' END,
 CASE WHEN l.labname='creatinine' AND LOWER(COALESCE(l.labmeasurenamesystem,'')) ~ '(umol|µmol|μmol)' THEN l.labresult/88.4
 WHEN l.labname='total bilirubin' AND LOWER(COALESCE(l.labmeasurenamesystem,'')) ~ '(umol|µmol|μmol)' THEN l.labresult/17.1
 WHEN l.labname='glucose' AND LOWER(COALESCE(l.labmeasurenamesystem,'')) LIKE '%mmol%' THEN l.labresult*18.0182
 WHEN l.labname='lactate' AND LOWER(COALESCE(l.labmeasurenamesystem,'')) LIKE '%mg/dl%' THEN l.labresult/9.008
 ELSE l.labresult END
 FROM lab_ranked l WHERE rn=1 AND l.labname IN('lactate','creatinine','glucose','PT - INR','platelets x 1000','total bilirubin') AND l.labresult>=0
 UNION ALL
 SELECT n.patientunitstayid,n.nursingchartoffset,'gcs',n.nursingchartvalue::double precision
 FROM eicu_crd.nursecharting n WHERE n.nursingchartoffset>=0 AND n.nursingchartoffset<1440
 AND n.nursingchartentryoffset<=1440 AND n.nursingchartvalue ~ '^[0-9]+([.][0-9]+)?$'
 AND ((n.nursingchartcelltypevallabel='Glasgow coma score' AND n.nursingchartcelltypevalname='GCS Total')
 OR(n.nursingchartcelltypevallabel='Score (Glasgow Coma Scale)' AND n.nursingchartcelltypevalname='Value'))
 UNION ALL
 SELECT u.patientunitstayid,u.chartoffset,'urine_output',u.urineoutput FROM ec_uo u
 WHERE u.chartoffset>=0 AND u.chartoffset<1440
),
bg AS (
 SELECT patientunitstayid,labresultoffset,
 MAX(labresult) FILTER(WHERE labname='paO2') AS pao2,
 MAX(CASE WHEN labresult BETWEEN 20 AND 100 THEN labresult/100.0 WHEN labresult BETWEEN 0.2 AND 1 THEN labresult END) FILTER(WHERE labname='FiO2') AS fio2
 FROM lab_ranked WHERE rn=1 AND labname IN('paO2','FiO2') GROUP BY patientunitstayid,labresultoffset
),
ec_vent AS (
 SELECT DISTINCT patientunitstayid,ventstartoffset,ventendoffset FROM eicu_crd.respiratorycare
 WHERE ventendoffset>ventstartoffset AND LOWER(airwaytype) ~ '(endotracheal|ett|tracheostom)'
),
pf AS (
 SELECT bg.patientunitstayid::bigint AS stay_id,
 MIN(bg.pao2/bg.fio2) FILTER(WHERE EXISTS(SELECT 1 FROM ec_vent r
 WHERE r.patientunitstayid=bg.patientunitstayid AND bg.labresultoffset>=r.ventstartoffset AND bg.labresultoffset<r.ventendoffset)) AS pf_supported_min,
 MIN(bg.pao2/bg.fio2) FILTER(WHERE NOT EXISTS(SELECT 1 FROM ec_vent r
 WHERE r.patientunitstayid=bg.patientunitstayid AND bg.labresultoffset>=r.ventstartoffset AND bg.labresultoffset<r.ventendoffset)) AS pf_unsupported_min
 FROM bg WHERE pao2 BETWEEN 15 AND 720 AND fio2 BETWEEN 0.2 AND 1 GROUP BY patientunitstayid
),
infusions AS (
 SELECT i.*,
 CASE WHEN LOWER(drugname) LIKE '%norepinephrine%' OR LOWER(drugname) LIKE '%levophed%' THEN 'norepinephrine'
 WHEN LOWER(drugname) LIKE '%epinephrine%' THEN 'epinephrine'
 WHEN LOWER(drugname) LIKE '%dopamine%' THEN 'dopamine'
 WHEN LOWER(drugname) LIKE '%dobu%' THEN 'dobutamine' ELSE 'other_vasopressor' END AS drug,
 CASE WHEN TRIM(drugrate) ~ '^[0-9]+([.][0-9]+)?$' THEN TRIM(drugrate)::double precision END AS raw_rate,
 LEAD(infusionoffset) OVER(PARTITION BY patientunitstayid,drugname ORDER BY infusionoffset,infusiondrugid) AS next_offset
 FROM eicu_crd.infusiondrug i WHERE infusionoffset>=0 AND infusionoffset<1440
 AND LOWER(drugname) ~ '(norepinephrine|levophed|epinephrine|dopamine|dobu|vasopressin|phenylephrine|neosynephrine)'
),
vaso_intervals AS (
 SELECT patientunitstayid::bigint AS stay_id,drug,infusionoffset::double precision AS start_min,
 LEAST(COALESCE(next_offset,infusionoffset),infusionoffset+60,1440)::double precision AS end_min,
 CASE WHEN LOWER(drugname) ~ '(mcg/kg/min|ug/kg/min)' THEN raw_rate
 WHEN LOWER(drugname) LIKE '%mcg/min%' AND TRIM(patientweight) ~ '^[0-9]+([.][0-9]+)?$'
 THEN raw_rate/NULLIF(TRIM(patientweight)::double precision,0)
 WHEN LOWER(drugname) LIKE '%mcg/kg/hr%' THEN raw_rate/60.0
 ELSE NULL END AS rate,FALSE AS duration_recorded
 FROM infusions WHERE raw_rate>0 OR raw_rate IS NULL
),
treatments AS (
 SELECT b.stay_id,
 EXISTS(SELECT 1 FROM ec_vent v WHERE v.patientunitstayid=b.stay_id AND v.ventstartoffset<1440 AND v.ventendoffset>0)::integer AS mechanical_ventilation_24h,
 CASE WHEN EXISTS(SELECT 1 FROM infusions i WHERE i.patientunitstayid=b.stay_id AND i.raw_rate>0 AND i.drug<>'dobutamine') THEN 1 WHEN EXISTS(SELECT 1 FROM infusions i WHERE i.patientunitstayid=b.stay_id AND i.raw_rate IS NULL AND i.drug<>'dobutamine') THEN NULL ELSE 0 END AS vasopressor_24h,
 EXISTS(SELECT 1 FROM eicu_crd.treatment t WHERE t.patientunitstayid=b.stay_id AND t.treatmentoffset>=0 AND t.treatmentoffset<1440
 AND LOWER(t.treatmentstring) ~ '(hemodialysis|continuous renal replacement|cvvh|peritoneal dialysis)')::integer AS rrt_24h,
 EXISTS(SELECT 1 FROM eicu_crd.medication m WHERE m.patientunitstayid=b.stay_id AND m.drugstartoffset<1440 AND COALESCE(m.drugstopoffset,m.drugstartoffset)>=0
 AND m.drugorderoffset<=1440 AND COALESCE(LOWER(m.drugordercancelled),'no') NOT IN('yes','true','1')
 AND (LOWER(m.drugname) LIKE '%adoxa%' OR LOWER(m.drugname) LIKE '%ala-tet%' OR LOWER(m.drugname) LIKE '%alodox%' OR LOWER(m.drugname) LIKE '%amikacin%' OR LOWER(m.drugname) LIKE '%amikin%' OR LOWER(m.drugname) LIKE '%amoxicill%' OR LOWER(m.drugname) LIKE '%amphotericin%' OR LOWER(m.drugname) LIKE '%ampicillin%' OR LOWER(m.drugname) LIKE '%ancef%' OR LOWER(m.drugname) LIKE '%anidulafungin%' OR LOWER(m.drugname) LIKE '%augmentin%' OR LOWER(m.drugname) LIKE '%avelox%' OR LOWER(m.drugname) LIKE '%avidoxy%' OR LOWER(m.drugname) LIKE '%axetil%' OR LOWER(m.drugname) LIKE '%azactam%' OR LOWER(m.drugname) LIKE '%azithromycin%' OR LOWER(m.drugname) LIKE '%aztreonam%' OR LOWER(m.drugname) LIKE '%bactocill%' OR LOWER(m.drugname) LIKE '%bactrim%' OR LOWER(m.drugname) LIKE '%bactroban%' OR LOWER(m.drugname) LIKE '%bethkis%' OR LOWER(m.drugname) LIKE '%biaxin%' OR LOWER(m.drugname) LIKE '%bicillin l-a%' OR LOWER(m.drugname) LIKE '%cayston%' OR LOWER(m.drugname) LIKE '%cedax%' OR LOWER(m.drugname) LIKE '%cefaclor%' OR LOWER(m.drugname) LIKE '%cefadroxil%' OR LOWER(m.drugname) LIKE '%cefazolin%' OR LOWER(m.drugname) LIKE '%cefdinir%' OR LOWER(m.drugname) LIKE '%cefditoren%' OR LOWER(m.drugname) LIKE '%cefepime%' OR LOWER(m.drugname) LIKE '%cefotan%' OR LOWER(m.drugname) LIKE '%cefotaxime%' OR LOWER(m.drugname) LIKE '%cefotetan%' OR LOWER(m.drugname) LIKE '%cefoxitin%' OR LOWER(m.drugname) LIKE '%cefpirome%' OR LOWER(m.drugname) LIKE '%cefpodoxime%' OR LOWER(m.drugname) LIKE '%cefprozil%' OR LOWER(m.drugname) LIKE '%ceftaroline%' OR LOWER(m.drugname) LIKE '%ceftazidime%' OR LOWER(m.drugname) LIKE '%ceftibuten%' OR LOWER(m.drugname) LIKE '%ceftin%' OR LOWER(m.drugname) LIKE '%ceftriaxone%' OR LOWER(m.drugname) LIKE '%cefuroxime%' OR LOWER(m.drugname) LIKE '%cephalexin%' OR LOWER(m.drugname) LIKE '%cephalothin%' OR LOWER(m.drugname) LIKE '%cephapririn%' OR LOWER(m.drugname) LIKE '%chloramphenicol%' OR LOWER(m.drugname) LIKE '%cipro%' OR LOWER(m.drugname) LIKE '%ciprofloxacin%' OR LOWER(m.drugname) LIKE '%claforan%' OR LOWER(m.drugname) LIKE '%clarithromycin%' OR LOWER(m.drugname) LIKE '%clavulanate%' OR LOWER(m.drugname) LIKE '%cleocin%' OR LOWER(m.drugname) LIKE '%clindamycin%' OR LOWER(m.drugname) LIKE '%cubicin%' OR LOWER(m.drugname) LIKE '%dicloxacillin%' OR LOWER(m.drugname) LIKE '%dirithromycin%' OR LOWER(m.drugname) LIKE '%doryx%' OR LOWER(m.drugname) LIKE '%doxycy%' OR LOWER(m.drugname) LIKE '%duricef%' OR LOWER(m.drugname) LIKE '%dynacin%' OR LOWER(m.drugname) LIKE '%ery-tab%' OR LOWER(m.drugname) LIKE '%eryc%' OR LOWER(m.drugname) LIKE '%eryped%' OR LOWER(m.drugname) LIKE '%erythrocin%' OR LOWER(m.drugname) LIKE '%erythromycin%' OR LOWER(m.drugname) LIKE '%factive%' OR LOWER(m.drugname) LIKE '%flagyl%' OR LOWER(m.drugname) LIKE '%fortaz%' OR LOWER(m.drugname) LIKE '%furadantin%' OR LOWER(m.drugname) LIKE '%garamycin%' OR LOWER(m.drugname) LIKE '%gentamicin%' OR LOWER(m.drugname) LIKE '%kanamycin%' OR LOWER(m.drugname) LIKE '%keflex%' OR LOWER(m.drugname) LIKE '%kefzol%' OR LOWER(m.drugname) LIKE '%ketek%' OR LOWER(m.drugname) LIKE '%levaquin%' OR LOWER(m.drugname) LIKE '%levofloxacin%' OR LOWER(m.drugname) LIKE '%lincocin%' OR LOWER(m.drugname) LIKE '%linezolid%' OR LOWER(m.drugname) LIKE '%macrobid%' OR LOWER(m.drugname) LIKE '%macrodantin%' OR LOWER(m.drugname) LIKE '%maxipime%' OR LOWER(m.drugname) LIKE '%mefoxin%' OR LOWER(m.drugname) LIKE '%meropenem%' OR LOWER(m.drugname) LIKE '%methicillin%' OR LOWER(m.drugname) LIKE '%metronidazole%' OR LOWER(m.drugname) LIKE '%minocin%' OR LOWER(m.drugname) LIKE '%minocycline%' OR LOWER(m.drugname) LIKE '%monodox%' OR LOWER(m.drugname) LIKE '%monurol%' OR LOWER(m.drugname) LIKE '%morgidox%' OR LOWER(m.drugname) LIKE '%moxatag%' OR LOWER(m.drugname) LIKE '%moxifloxacin%' OR LOWER(m.drugname) LIKE '%mupirocin%' OR LOWER(m.drugname) LIKE '%myrac%' OR LOWER(m.drugname) LIKE '%nafcillin%' OR LOWER(m.drugname) LIKE '%neomycin%' OR LOWER(m.drugname) LIKE '%nicazel doxy 30%' OR LOWER(m.drugname) LIKE '%nitrofurantoin%' OR LOWER(m.drugname) LIKE '%norfloxacin%' OR LOWER(m.drugname) LIKE '%noroxin%' OR LOWER(m.drugname) LIKE '%ocudox%' OR LOWER(m.drugname) LIKE '%ofloxacin%' OR LOWER(m.drugname) LIKE '%omnicef%' OR LOWER(m.drugname) LIKE '%oracea%' OR LOWER(m.drugname) LIKE '%oraxyl%' OR LOWER(m.drugname) LIKE '%oxacillin%' OR LOWER(m.drugname) LIKE '%panixine%' OR LOWER(m.drugname) LIKE '%pc pen vk%' OR LOWER(m.drugname) LIKE '%pce dispertab%' OR LOWER(m.drugname) LIKE '%pediazole%' OR LOWER(m.drugname) LIKE '%penicillin%' OR LOWER(m.drugname) LIKE '%periostat%' OR LOWER(m.drugname) LIKE '%pfizerpen%' OR LOWER(m.drugname) LIKE '%piperacillin%' OR LOWER(m.drugname) LIKE '%primsol%' OR LOWER(m.drugname) LIKE '%proquin%' OR LOWER(m.drugname) LIKE '%raniclor%' OR LOWER(m.drugname) LIKE '%rifadin%' OR LOWER(m.drugname) LIKE '%rifampin%' OR LOWER(m.drugname) LIKE '%rocephin%' OR LOWER(m.drugname) LIKE '%septra%' OR LOWER(m.drugname) LIKE '%septra ds%' OR LOWER(m.drugname) LIKE '%smz-tmp%' OR LOWER(m.drugname) LIKE '%solodyn%' OR LOWER(m.drugname) LIKE '%spectracef%' OR LOWER(m.drugname) LIKE '%streptomycin%' OR LOWER(m.drugname) LIKE '%sulfadiazine%' OR LOWER(m.drugname) LIKE '%sulfamethoxazole%' OR LOWER(m.drugname) LIKE '%sulfatrim%' OR LOWER(m.drugname) LIKE '%sulfisoxazole%' OR LOWER(m.drugname) LIKE '%suprax%' OR LOWER(m.drugname) LIKE '%synercid%' OR LOWER(m.drugname) LIKE '%tazicef%' OR LOWER(m.drugname) LIKE '%tazobactam%' OR LOWER(m.drugname) LIKE '%tetracycline%' OR LOWER(m.drugname) LIKE '%timentin%' OR LOWER(m.drugname) LIKE '%tobramycin%' OR LOWER(m.drugname) LIKE '%trimethoprim%' OR LOWER(m.drugname) LIKE '%unasyn%' OR LOWER(m.drugname) LIKE '%vancocin%' OR LOWER(m.drugname) LIKE '%vancomycin%' OR LOWER(m.drugname) LIKE '%vantin%' OR LOWER(m.drugname) LIKE '%vibativ%' OR LOWER(m.drugname) LIKE '%vibra-tabs%' OR LOWER(m.drugname) LIKE '%vibramycin%' OR LOWER(m.drugname) LIKE '%zinacef%' OR LOWER(m.drugname) LIKE '%zithromax%' OR LOWER(m.drugname) LIKE '%zosyn%' OR LOWER(m.drugname) LIKE '%zyvox%') AND LOWER(COALESCE(m.routeadmin,'')) NOT IN('topical','ophthalmic','otic') AND LOWER(m.drugname) NOT LIKE '%cream%' AND LOWER(m.drugname) NOT LIKE '%gel%')::integer AS antibiotic_24h,
 (SELECT SUM(io.cellvaluenumeric) FROM eicu_crd.intakeoutput io WHERE io.patientunitstayid=b.stay_id
 AND io.intakeoutputoffset>=0 AND io.intakeoutputoffset<1440 AND io.intakeoutputentryoffset<=1440 AND io.cellvaluenumeric>=0
 AND LOWER(io.cellpath) LIKE '%|intake (ml)|%'
 AND LOWER(io.celllabel) ~ '(normal saline|sodium chloride 0.9|lactated ringer|plasma.?lyte|albumin)'
 AND LOWER(io.celllabel) NOT LIKE '%flush%') AS fluid_resuscitation_24h_ml
 FROM cohort b
),
body AS (SELECT stay_id,admissionweight::double precision AS weight_kg,admissionheight::double precision AS height_cm FROM cohort),
cci AS (
 SELECT b.stay_id,c.cci_no_age AS charlson_comorbidity_index,
 FALSE AS cci_index_discharge_codes_used,0 AS prior_admissions_n,NULL::integer AS cci_index_discharge_candidate
 FROM cohort b LEFT JOIN ec_cci c ON c.patientunitstayid=b.stay_id
),
site_candidates AS (
 SELECT d.patientunitstayid::bigint AS stay_id,STRING_AGG(DISTINCT LOWER(d.diagnosisstring),' | ') AS diagnosis_text
 FROM eicu_crd.diagnosis d WHERE d.diagnosisoffset>=0 AND d.diagnosisoffset<1440 GROUP BY d.patientunitstayid
),

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
SELECT b.subject_id,b.hadm_id,b.eligible_pre_landmark,b.eligible_24h,s.* FROM cohort b JOIN sofa_scored s USING(stay_id) WHERE b.eligible_pre_landmark ORDER BY b.stay_id;
