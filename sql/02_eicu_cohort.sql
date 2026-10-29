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
)
SELECT * FROM cohort ORDER BY stay_id;
