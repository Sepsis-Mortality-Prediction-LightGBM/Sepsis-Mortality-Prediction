-- 未经数据库验证 / NOT VALIDATED AGAINST THE ACTUAL SOURCE DATABASES.
-- Offline reconstruction v0.2 (2026-10-25); no original extraction reproduction is claimed.
-- Reconstructed extraction pipeline v0.1 (2026-10-24); PostgreSQL 14+.
-- MIMIC-IV 2.2 / eICU-CRD 2.0. No patient identifiers are hard-coded.
-- Read-only SELECT. Definitions/provenance limits are in README and feature_contract.csv.
-- This is newly reconstructed code, not the unavailable original extraction script.
WITH
mc_bg AS (
/* The aim of this query is to pivot entries related to blood gases */ /* which were found in LABEVENTS */
WITH bg AS (
  SELECT
    MAX(subject_id) AS subject_id,
    MAX(hadm_id) AS hadm_id,
    MAX(charttime) AS charttime, /* specimen_id *may* have different storetimes, so this */ /* is taking the latest */
    MAX(storetime) AS storetime,
    le.specimen_id,
    MAX(CASE WHEN itemid = 52033 THEN value ELSE NULL END) AS specimen,
    MAX(CASE WHEN itemid = 50801 THEN valuenum ELSE NULL END) AS aado2,
    MAX(CASE WHEN itemid = 50802 THEN valuenum ELSE NULL END) AS baseexcess,
    MAX(CASE WHEN itemid = 50803 THEN valuenum ELSE NULL END) AS bicarbonate,
    MAX(CASE WHEN itemid = 50804 THEN valuenum ELSE NULL END) AS totalco2,
    MAX(CASE WHEN itemid = 50805 THEN valuenum ELSE NULL END) AS carboxyhemoglobin,
    MAX(CASE WHEN itemid = 50806 THEN valuenum ELSE NULL END) AS chloride,
    MAX(CASE WHEN itemid = 50808 THEN valuenum ELSE NULL END) AS calcium,
    MAX(CASE WHEN itemid = 50809 AND valuenum <= 10000 THEN valuenum ELSE NULL END) AS glucose,
    MAX(CASE WHEN itemid = 50810 AND valuenum <= 100 THEN valuenum ELSE NULL END) AS hematocrit,
    MAX(CASE WHEN itemid = 50811 THEN valuenum ELSE NULL END) AS hemoglobin,
    MAX(CASE WHEN itemid = 50813 AND valuenum <= 10000 THEN valuenum ELSE NULL END) AS lactate,
    MAX(CASE WHEN itemid = 50814 THEN valuenum ELSE NULL END) AS methemoglobin,
    MAX(CASE WHEN itemid = 50815 THEN valuenum ELSE NULL END) AS o2flow, /* fix a common unit conversion error for fio2 */ /* atmospheric o2 is 20.89%, so any value <= 20 is unphysiologic */ /* usually this is a misplaced O2 flow measurement */
    MAX(
      CASE
        WHEN itemid = 50816
        THEN CASE
          WHEN valuenum > 20 AND valuenum <= 100
          THEN valuenum
          WHEN valuenum > 0.2 AND valuenum <= 1.0
          THEN valuenum * 100.0
          ELSE NULL
        END
        ELSE NULL
      END
    ) AS fio2,
    MAX(CASE WHEN itemid = 50817 AND valuenum <= 100 THEN valuenum ELSE NULL END) AS so2,
    MAX(CASE WHEN itemid = 50818 THEN valuenum ELSE NULL END) AS pco2,
    MAX(CASE WHEN itemid = 50819 THEN valuenum ELSE NULL END) AS peep,
    MAX(CASE WHEN itemid = 50820 THEN valuenum ELSE NULL END) AS ph,
    MAX(CASE WHEN itemid = 50821 THEN valuenum ELSE NULL END) AS po2,
    MAX(CASE WHEN itemid = 50822 THEN valuenum ELSE NULL END) AS potassium,
    MAX(CASE WHEN itemid = 50823 THEN valuenum ELSE NULL END) AS requiredo2,
    MAX(CASE WHEN itemid = 50824 THEN valuenum ELSE NULL END) AS sodium,
    MAX(CASE WHEN itemid = 50825 THEN valuenum ELSE NULL END) AS temperature,
    MAX(CASE WHEN itemid = 50807 THEN value ELSE NULL END) AS comments
  FROM mimiciv_hosp.labevents AS le
  WHERE
    le.itemid IN (52033 /* specimen */, 50801 /* aado2 */, 50802 /* base excess */, 50803 /* bicarb */, 50804 /* calc tot co2 */, 50805 /* carboxyhgb */, 50806 /* chloride */ /* , 52390 -- chloride, WB CL- */, 50807 /* comments */, 50808 /* free calcium */, 50809 /* glucose */, 50810 /* hct */, 50811 /* hgb */, 50813 /* lactate */, 50814 /* methemoglobin */, 50815 /* o2 flow */, 50816 /* fio2 */, 50817 /* o2 sat */, 50818 /* pco2 */, 50819 /* peep */, 50820 /* pH */, 50821 /* pO2 */, 50822 /* potassium */ /* , 52408 -- potassium, WB K+ */, 50823 /* required O2 */, 50824 /* sodium */ /* , 52411 -- sodium, WB NA + */, 50825 /* temperature */)
  GROUP BY
    le.specimen_id
), stg_spo2 AS (
  SELECT
    subject_id,
    charttime, /* avg here is just used to group SpO2 by charttime */
    AVG(valuenum) AS spo2
  FROM mimiciv_icu.chartevents
  WHERE
    itemid = 220277 /* O2 saturation pulseoxymetry */ AND valuenum > 0 AND valuenum <= 100
  GROUP BY
    subject_id,
    charttime
), stg_fio2 AS (
  SELECT
    subject_id,
    charttime, /* pre-process the FiO2s to ensure they are between 21-100% */
    MAX(
      CASE
        WHEN valuenum > 0.2 AND valuenum <= 1
        THEN valuenum * 100
        WHEN valuenum > 1 AND valuenum < 20
        THEN NULL
        WHEN valuenum >= 20 AND valuenum <= 100
        THEN valuenum
        ELSE NULL
      END
    ) AS fio2_chartevents
  FROM mimiciv_icu.chartevents
  WHERE
    itemid = 223835 /* Inspired O2 Fraction (FiO2) */ AND valuenum > 0 AND valuenum <= 100
  GROUP BY
    subject_id,
    charttime
), stg2 AS (
  SELECT
    bg.*,
    ROW_NUMBER() OVER (PARTITION BY bg.subject_id, bg.charttime ORDER BY s1.charttime DESC NULLS LAST) AS lastrowspo2,
    s1.spo2
  FROM bg
  LEFT JOIN stg_spo2 AS s1
    ON bg.subject_id = s1.subject_id
    AND s1.charttime BETWEEN bg.charttime - INTERVAL '2 HOUR' AND bg.charttime
  WHERE
    NOT bg.po2 IS NULL
), stg3 AS (
  SELECT
    bg.*,
    ROW_NUMBER() OVER (PARTITION BY bg.subject_id, bg.charttime ORDER BY s2.charttime DESC NULLS LAST) AS lastrowfio2,
    s2.fio2_chartevents
  FROM stg2 AS bg
  LEFT JOIN stg_fio2 AS s2
    ON bg.subject_id = s2.subject_id
    AND s2.charttime >= bg.charttime - INTERVAL '4 HOUR'
    AND s2.charttime <= bg.charttime
    AND s2.fio2_chartevents > 0
  /* only the row with the most recent SpO2 (if no SpO2 found lastRowSpO2 = 1) */
  WHERE
    bg.lastrowspo2 = 1
)
SELECT
  stg3.subject_id,
  stg3.hadm_id,
  stg3.charttime,stg3.storetime, /* drop down text indicating the specimen type */
  specimen, /* oxygen related parameters */
  so2,
  po2,
  pco2,
  fio2_chartevents,
  fio2,
  aado2, /* also calculate AADO2 */
  CASE
    WHEN po2 IS NULL OR pco2 IS NULL
    THEN NULL
    WHEN NOT fio2 IS NULL
    THEN (
      CAST(fio2 AS DOUBLE PRECISION) / 100
    ) * (
      760 - 47
    ) - (
      CAST(pco2 AS DOUBLE PRECISION) / 0.8
    ) - po2
    WHEN NOT fio2_chartevents IS NULL
    THEN (
      CAST(fio2_chartevents AS DOUBLE PRECISION) / 100
    ) * (
      760 - 47
    ) - (
      CAST(pco2 AS DOUBLE PRECISION) / 0.8
    ) - po2
    ELSE NULL
  END AS aado2_calc,
  CASE
    WHEN po2 IS NULL
    THEN NULL
    WHEN NOT fio2 IS NULL
    THEN CAST(100 * po2 AS DOUBLE PRECISION) / fio2
    WHEN NOT fio2_chartevents IS NULL
    THEN CAST(100 * po2 AS DOUBLE PRECISION) / fio2_chartevents
    ELSE NULL
  END AS pao2fio2ratio, /* acid-base parameters */
  ph,
  baseexcess,
  bicarbonate,
  totalco2, /* blood count parameters */
  hematocrit,
  hemoglobin,
  carboxyhemoglobin,
  methemoglobin, /* chemistry */
  chloride,
  calcium,
  temperature,
  potassium,
  sodium,
  lactate,
  glucose
/* ventilation stuff that's sometimes input */ /* , intubated, tidalvolume, ventilationrate, ventilator */ /* , peep, o2flow */ /* , requiredo2 */
FROM stg3
WHERE
  lastrowfio2 = 1 /* only the most recent FiO2 */
),
mc_chemistry AS (
/* extract chemistry labs */ /* excludes point of care tests (very rare) */ /* blood gas measurements are *not* included in this query */ /* instead they are in bg.sql */
SELECT
  MAX(subject_id) AS subject_id,
  MAX(hadm_id) AS hadm_id,
  MAX(charttime) AS charttime,
  le.specimen_id, /* convert from itemid into a meaningful column */
  MAX(CASE WHEN itemid = 50862 AND valuenum <= 10 THEN valuenum ELSE NULL END) AS albumin,
  MAX(CASE WHEN itemid = 50930 AND valuenum <= 10 THEN valuenum ELSE NULL END) AS globulin,
  MAX(CASE WHEN itemid = 50976 AND valuenum <= 20 THEN valuenum ELSE NULL END) AS total_protein,
  MAX(CASE WHEN itemid = 50868 AND valuenum <= 10000 THEN valuenum ELSE NULL END) AS aniongap,
  MAX(CASE WHEN itemid = 50882 AND valuenum <= 10000 THEN valuenum ELSE NULL END) AS bicarbonate,
  MAX(CASE WHEN itemid = 51006 AND valuenum <= 300 THEN valuenum ELSE NULL END) AS bun,
  MAX(CASE WHEN itemid = 50893 AND valuenum <= 10000 THEN valuenum ELSE NULL END) AS calcium,
  MAX(CASE WHEN itemid = 50902 AND valuenum <= 10000 THEN valuenum ELSE NULL END) AS chloride,
  MAX(CASE WHEN itemid = 50912 AND valuenum <= 150 THEN valuenum ELSE NULL END) AS creatinine,
  MAX(CASE WHEN itemid = 50931 AND valuenum <= 10000 THEN valuenum ELSE NULL END) AS glucose,
  MAX(CASE WHEN itemid = 50983 AND valuenum <= 200 THEN valuenum ELSE NULL END) AS sodium,
  MAX(CASE WHEN itemid = 50971 AND valuenum <= 30 THEN valuenum ELSE NULL END) AS potassium
FROM mimiciv_hosp.labevents AS le
WHERE
  le.itemid IN (50862 /* comment is: LABEL | CATEGORY | FLUID | NUMBER OF ROWS IN LABEVENTS */ /* ALBUMIN | CHEMISTRY | BLOOD | 146697 */, 50930 /* Globulin */, 50976 /* Total protein */ /* 52456, -- Anion gap, point of care test */, 50868 /* ANION GAP | CHEMISTRY | BLOOD | 769895 */, 50882 /* BICARBONATE | CHEMISTRY | BLOOD | 780733 */, 50893 /* Calcium */ /* 52502, Creatinine, point of care */, 50912 /* CREATININE | CHEMISTRY | BLOOD | 797476 */, 50902 /* CHLORIDE | CHEMISTRY | BLOOD | 795568 */, 50931 /* GLUCOSE | CHEMISTRY | BLOOD | 748981 */ /* 52525, Glucose, point of care */ /* 52566, -- Potassium, point of care */, 50971 /* POTASSIUM | CHEMISTRY | BLOOD | 845825 */ /* 52579, -- Sodium, point of care */, 50983 /* SODIUM | CHEMISTRY | BLOOD | 808489 */ /* 52603, Urea, point of care */, 51006 /* UREA NITROGEN | CHEMISTRY | BLOOD | 791925 */)
  AND NOT valuenum IS NULL
  AND (
    valuenum > 0 OR itemid = 50868
  ) /* lab values cannot be 0 and cannot be negative */ /* .. except anion gap. */
GROUP BY
  le.specimen_id
),
mc_complete_blood_count AS (
/* begin query that extracts the data */
SELECT
  MAX(subject_id) AS subject_id,
  MAX(hadm_id) AS hadm_id,
  MAX(charttime) AS charttime,
  le.specimen_id, /* convert from itemid into a meaningful column */
  MAX(CASE WHEN itemid = 51221 THEN valuenum ELSE NULL END) AS hematocrit,
  MAX(CASE WHEN itemid = 51222 THEN valuenum ELSE NULL END) AS hemoglobin,
  MAX(CASE WHEN itemid = 51248 THEN valuenum ELSE NULL END) AS mch,
  MAX(CASE WHEN itemid = 51249 THEN valuenum ELSE NULL END) AS mchc,
  MAX(CASE WHEN itemid = 51250 THEN valuenum ELSE NULL END) AS mcv,
  MAX(CASE WHEN itemid = 51265 THEN valuenum ELSE NULL END) AS platelet,
  MAX(CASE WHEN itemid = 51279 THEN valuenum ELSE NULL END) AS rbc,
  MAX(CASE WHEN itemid = 51277 THEN valuenum ELSE NULL END) AS rdw,
  MAX(CASE WHEN itemid = 52159 THEN valuenum ELSE NULL END) AS rdwsd,
  MAX(CASE WHEN itemid = 51301 THEN valuenum ELSE NULL END) AS wbc
FROM mimiciv_hosp.labevents AS le
WHERE
  le.itemid IN (51221 /* hematocrit */, 51222 /* hemoglobin */, 51248 /* MCH */, 51249 /* MCHC */, 51250 /* MCV */, 51265 /* platelets */, 51279 /* RBC */, 51277 /* RDW */, 52159 /* RDW SD */, 51301 /* WBC */)
  AND NOT valuenum IS NULL
  AND valuenum > 0
GROUP BY
  le.specimen_id
),
mc_dobutamine AS (
/* This query extracts dose+durations of dobutamine administration */ /* Local hospital dosage guidance: 2 mcg/kg/min (low) - 40 mcg/kg/min (max) */
SELECT
  stay_id,
  linkorderid, /* all rows in mcg/kg/min */
  rate AS vaso_rate,
  amount AS vaso_amount,
  starttime,
  endtime
FROM mimiciv_icu.inputevents
WHERE
  itemid = 221653 /* dobutamine */
),
mc_dopamine AS (
/* This query extracts dose+durations of dopamine administration */ /* Local hospital dosage guidance: 2 mcg/kg/min (low) - 10 mcg/kg/min (high) */
SELECT
  stay_id,
  linkorderid, /* all rows in mcg/kg/min */
  rate AS vaso_rate,
  amount AS vaso_amount,
  starttime,
  endtime
FROM mimiciv_icu.inputevents
WHERE
  itemid = 221662 /* dopamine */
),
mc_enzyme AS (
/* begin query that extracts the data */
SELECT
  MAX(subject_id) AS subject_id,
  MAX(hadm_id) AS hadm_id,
  MAX(charttime) AS charttime,
  le.specimen_id, /* convert from itemid into a meaningful column */
  MAX(CASE WHEN itemid = 50861 THEN valuenum ELSE NULL END) AS alt,
  MAX(CASE WHEN itemid = 50863 THEN valuenum ELSE NULL END) AS alp,
  MAX(CASE WHEN itemid = 50878 THEN valuenum ELSE NULL END) AS ast,
  MAX(CASE WHEN itemid = 50867 THEN valuenum ELSE NULL END) AS amylase,
  MAX(CASE WHEN itemid = 50885 THEN valuenum ELSE NULL END) AS bilirubin_total,
  MAX(CASE WHEN itemid = 50883 THEN valuenum ELSE NULL END) AS bilirubin_direct,
  MAX(CASE WHEN itemid = 50884 THEN valuenum ELSE NULL END) AS bilirubin_indirect,
  MAX(CASE WHEN itemid = 50910 THEN valuenum ELSE NULL END) AS ck_cpk,
  MAX(CASE WHEN itemid = 50911 THEN valuenum ELSE NULL END) AS ck_mb,
  MAX(CASE WHEN itemid = 50927 THEN valuenum ELSE NULL END) AS ggt,
  MAX(CASE WHEN itemid = 50954 THEN valuenum ELSE NULL END) AS ld_ldh
FROM mimiciv_hosp.labevents AS le
WHERE
  le.itemid IN (50861 /* Alanine transaminase (ALT) */, 50863 /* Alkaline phosphatase (ALP) */, 50878 /* Aspartate transaminase (AST) */, 50867 /* Amylase */, 50885 /* total bili */, 50884 /* indirect bili */, 50883 /* direct bili */, 50910 /* ck_cpk */, 50911 /* CK-MB */, 50927 /* Gamma Glutamyltransferase (GGT) */, 50954 /* ld_ldh */)
  AND NOT valuenum IS NULL
  AND valuenum > 0
GROUP BY
  le.specimen_id
),
mc_epinephrine AS (
/* This query extracts dose+durations of epinephrine administration */ /* Local hospital dosage guidance: 0.2 mcg/kg/min (low) - 2 mcg/kg/min (high) */
SELECT
  stay_id,
  linkorderid, /* all rows in mcg/kg/min */
  rate AS vaso_rate,
  amount AS vaso_amount,
  starttime,
  endtime
FROM mimiciv_icu.inputevents
WHERE
  itemid = 221289 /* epinephrine */
),
mc_gcs AS (
/* This query extracts the Glasgow Coma Scale, a measure of neurological */ /* function. */ /* The query has a few special rules: */ /*    (1) The verbal component can be set to 0 if the patient is ventilated. */ /*    This is corrected to 5 - the overall GCS is set to 15 in these cases. */ /*    (2) Often only one of three components is documented. The other components */ /*    are carried forward. */ /* ITEMIDs used: */ /* METAVISION */ /*    223900 GCS - Verbal Response */ /*    223901 GCS - Motor Response */ /*    220739 GCS - Eye Opening */ /* Note: */ /*  The GCS for sedated patients is defaulted to 15 in this code. */ /*  This is in line with how the data is meant to be collected. */ /*  e.g., from the SAPS II publication: */ /*    For sedated patients, the Glasgow Coma Score before sedation was used. */ /*    This was ascertained either from interviewing the physician who ordered */ /*    the sedation, or by reviewing the patient's medical record. */
WITH base AS (
  SELECT
    subject_id,
    ce.stay_id,
    ce.charttime, /* pivot each value into its own column */
    MAX(CASE WHEN ce.itemid = 223901 THEN ce.valuenum ELSE NULL END) AS gcsmotor,
    MAX(
      CASE
        WHEN ce.itemid = 223900 AND ce.value = 'No Response-ETT'
        THEN 0
        WHEN ce.itemid = 223900
        THEN ce.valuenum
        ELSE NULL
      END
    ) AS gcsverbal,
    MAX(CASE WHEN ce.itemid = 220739 THEN ce.valuenum ELSE NULL END) AS gcseyes, /* convert the data into a number, reserving a value of 0 for ET/Trach */
    MAX(CASE WHEN ce.itemid = 223900 AND ce.value = 'No Response-ETT' THEN 1 ELSE 0 END) AS endotrachflag,
    ROW_NUMBER() OVER (PARTITION BY ce.stay_id ORDER BY ce.charttime ASC NULLS FIRST) AS rn
  FROM mimiciv_icu.chartevents AS ce
  /* Isolate the desired GCS variables */
  WHERE
    ce.itemid IN (223900 /* GCS components, Metavision */, 223901, 220739)
  GROUP BY
    ce.subject_id,
    ce.stay_id,
    ce.charttime
), gcs AS (
  SELECT
    b.*,
    b2.gcsverbal AS gcsverbalprev,
    b2.gcsmotor AS gcsmotorprev,
    b2.gcseyes AS gcseyesprev, /* Calculate GCS, factoring in special case when they are intubated */ /* note that the coalesce are used to implement the following if: */ /*  if current value exists, use it */ /*  if previous value exists, use it */ /*  otherwise, default to normal */
    CASE
      WHEN b.gcsverbal = 0
      THEN 15
      WHEN b.gcsverbal IS NULL AND b2.gcsverbal = 0
      THEN 15
      WHEN b2.gcsverbal = 0
      THEN COALESCE(b.gcsmotor, 6) + COALESCE(b.gcsverbal, 5) + COALESCE(b.gcseyes, 4)
      ELSE COALESCE(b.gcsmotor, COALESCE(b2.gcsmotor, 6)) + COALESCE(b.gcsverbal, COALESCE(b2.gcsverbal, 5)) + COALESCE(b.gcseyes, COALESCE(b2.gcseyes, 4))
    END AS gcs
  FROM base AS b
  /* join to itself within 6 hours to get previous value */
  LEFT JOIN base AS b2
    ON b.stay_id = b2.stay_id
    AND b.rn = b2.rn + 1
    AND b2.charttime > b.charttime - INTERVAL '6 HOUR'
), gcs_stg AS (
  SELECT
    subject_id,
    gs.stay_id,
    gs.charttime,
    gcs,
    COALESCE(gcsmotor, gcsmotorprev) AS gcsmotor,
    COALESCE(gcsverbal, gcsverbalprev) AS gcsverbal,
    COALESCE(gcseyes, gcseyesprev) AS gcseyes,
    CASE WHEN COALESCE(gcsmotor, gcsmotorprev) IS NULL THEN 0 ELSE 1 END + CASE WHEN COALESCE(gcsverbal, gcsverbalprev) IS NULL THEN 0 ELSE 1 END + CASE WHEN COALESCE(gcseyes, gcseyesprev) IS NULL THEN 0 ELSE 1 END AS components_measured,
    endotrachflag
  FROM gcs AS gs
)
SELECT
  gs.subject_id,
  gs.stay_id,
  gs.charttime,
  gcs AS gcs,
  gcsmotor AS gcs_motor,
  gcsverbal AS gcs_verbal,
  gcseyes AS gcs_eyes,
  endotrachflag AS gcs_unable
FROM gcs_stg AS gs
),
mc_icustay_times AS (
/* add in subject_id/hadm_id */
/* create a table which has fuzzy boundaries on hospital admission */ /* involves first creating a lag/lead version of disch/admit time */ /* get first/last heart rate measurement during hospitalization for each stay_id */
WITH t1 AS (
  SELECT
    ce.stay_id,
    MIN(charttime) AS intime_hr,
    MAX(charttime) AS outtime_hr
  FROM mimiciv_icu.chartevents AS ce
  /* only look at heart rate */
  WHERE
    ce.itemid = 220045
  GROUP BY
    ce.stay_id
)
SELECT
  ie.subject_id,
  ie.hadm_id,
  ie.stay_id,
  t1.intime_hr,
  t1.outtime_hr
FROM mimiciv_icu.icustays AS ie
LEFT JOIN t1
  ON ie.stay_id = t1.stay_id
),
mc_icustay_hourly AS (
-- PostgreSQL portability patch: set-returning generate_series belongs in FROM.
SELECT it.stay_id,h.hr::bigint AS hr,
 (CASE WHEN DATE_TRUNC('hour',it.intime_hr)=it.intime_hr THEN it.intime_hr
 ELSE DATE_TRUNC('hour',it.intime_hr)+INTERVAL '1 hour' END)+h.hr*INTERVAL '1 hour' AS endtime
 FROM mc_icustay_times it
 CROSS JOIN LATERAL GENERATE_SERIES(-24,CEIL(EXTRACT(EPOCH FROM(it.outtime_hr-it.intime_hr))/3600.0)::integer) AS h(hr)
),
mc_norepinephrine AS (
/* This query extracts dose+durations of norepinephrine administration */ /* Local hospital dosage guidance: 0.03 mcg/kg/min (low), 0.5 mcg/kg/min (high) */
SELECT
  stay_id,
  linkorderid, /* two rows in mg/kg/min... rest in mcg/kg/min */ /* the rows in mg/kg/min are documented incorrectly */ /* all rows converted into mcg/kg/min (equiv to ug/kg/min) */
  CASE
    WHEN rateuom = 'mg/kg/min' AND patientweight = 1
    THEN rate
    WHEN rateuom = 'mg/kg/min'
    THEN rate * 1000.0
    ELSE rate
  END AS vaso_rate,
  amount AS vaso_amount,
  starttime,
  endtime
FROM mimiciv_icu.inputevents
WHERE
  itemid = 221906 /* norepinephrine */
),
mc_urine_output AS (
WITH uo AS (
  SELECT
    oe.stay_id,
    oe.charttime, /* volumes associated with urine output ITEMIDs */ /* note we consider input of GU irrigant as a negative volume */ /* GU irrigant volume in usually has a corresponding volume out */ /* so the net is often 0, despite large irrigant volumes */
    CASE WHEN oe.itemid = 227488 AND oe.value > 0 THEN -1 * oe.value ELSE oe.value END AS urineoutput
  FROM mimiciv_icu.outputevents AS oe
  WHERE
    itemid IN (226559 /* Foley */, 226560 /* Void */, 226561 /* Condom Cath */, 226584 /* Ileoconduit */, 226563 /* Suprapubic */, 226564 /* R Nephrostomy */, 226565 /* L Nephrostomy */, 226567 /* Straight Cath */, 226557 /* R Ureteral Stent */, 226558 /* L Ureteral Stent */, 227488 /* GU Irrigant Volume In */, 227489 /* GU Irrigant/Urine Volume Out */)
)
SELECT
  stay_id,
  charttime,
  SUM(urineoutput) AS urineoutput
FROM uo
GROUP BY
  stay_id,
  charttime
),
mc_weight_durations AS (
/* This query extracts weights for adult ICU patients with start/stop times */ /* if an admission weight is given, then this is assigned from intime to outtime */
WITH wt_stg AS (
  SELECT
    c.stay_id,
    c.charttime,
    CASE WHEN c.itemid = 226512 THEN 'admit' ELSE 'daily' END AS weight_type, /* TODO: eliminate obvious outliers if there is a reasonable weight */
    c.valuenum AS weight
  FROM mimiciv_icu.chartevents AS c
  WHERE
    NOT c.valuenum IS NULL
    AND c.itemid IN (226512 /* Admit Wt */, 224639 /* Daily Weight */)
    AND c.valuenum > 0
), wt_stg1 AS (
  SELECT
    stay_id,
    charttime,
    weight_type,
    weight,
    ROW_NUMBER() OVER (PARTITION BY stay_id, weight_type ORDER BY charttime NULLS FIRST) AS rn
  FROM wt_stg
  WHERE
    NOT weight IS NULL
), wt_stg2 AS (
  SELECT
    wt_stg1.stay_id,
    ie.intime,
    ie.outtime,
    wt_stg1.weight_type,
    CASE
      WHEN wt_stg1.weight_type = 'admit' AND wt_stg1.rn = 1
      THEN ie.intime - INTERVAL '2 HOUR'
      ELSE wt_stg1.charttime
    END AS starttime,
    wt_stg1.weight
  FROM wt_stg1
  INNER JOIN mimiciv_icu.icustays AS ie
    ON ie.stay_id = wt_stg1.stay_id
), wt_stg3 AS (
  SELECT
    stay_id,
    intime,
    outtime,
    starttime,
    COALESCE(
      LEAD(starttime) OVER (PARTITION BY stay_id ORDER BY starttime NULLS FIRST),
      outtime + INTERVAL '2 HOUR'
    ) AS endtime,
    weight,
    weight_type
  FROM wt_stg2
), wt1 AS (
  SELECT
    stay_id,
    starttime,
    COALESCE(
      endtime,
      LEAD(starttime) OVER (PARTITION BY stay_id ORDER BY starttime NULLS FIRST) /* impute ICU discharge as the end of the final weight measurement */ /* plus a 2 hour "fuzziness" window */,
      outtime + INTERVAL '2 HOUR'
    ) AS endtime,
    weight,
    weight_type
  FROM wt_stg3
), wt_fix AS (
  SELECT
    ie.stay_id, /* we add a 2 hour "fuzziness" window */
    ie.intime - INTERVAL '2 HOUR' AS starttime,
    wt.starttime AS endtime,
    wt.weight,
    wt.weight_type
  FROM mimiciv_icu.icustays AS ie
  INNER JOIN (
    SELECT
      wt1.stay_id,
      wt1.starttime,
      wt1.weight,
      weight_type,
      ROW_NUMBER() OVER (PARTITION BY wt1.stay_id ORDER BY wt1.starttime NULLS FIRST) AS rn
    FROM wt1
  ) AS wt
    ON ie.stay_id = wt.stay_id AND wt.rn = 1 AND ie.intime < wt.starttime
)
/* add the backfill rows to the main weight table */
SELECT
  wt1.stay_id,
  wt1.starttime,
  wt1.endtime,
  wt1.weight,
  wt1.weight_type
FROM wt1
UNION ALL
SELECT
  wt_fix.stay_id,
  wt_fix.starttime,
  wt_fix.endtime,
  wt_fix.weight,
  wt_fix.weight_type
FROM wt_fix
),
mc_urine_output_rate AS (
/* attempt to calculate urine output per hour */ /* rate/hour is the interpretable measure of kidney function */ /* though it is difficult to estimate from aperiodic point measures */ /* first we get the earliest heart rate documented for the stay */
WITH tm AS (
  SELECT
    ie.stay_id,
    MIN(charttime) AS intime_hr,
    MAX(charttime) AS outtime_hr
  FROM mimiciv_icu.icustays AS ie
  INNER JOIN mimiciv_icu.chartevents AS ce
    ON ie.stay_id = ce.stay_id
    AND ce.itemid = 220045
    AND ce.charttime > ie.intime - INTERVAL '1 MONTH'
    AND ce.charttime < ie.outtime + INTERVAL '1 MONTH'
  GROUP BY
    ie.stay_id
), uo_tm AS (
  SELECT
    tm.stay_id,
    CASE
      WHEN LAG(charttime) OVER w IS NULL
      THEN EXTRACT(EPOCH FROM charttime - intime_hr) / 60.0
      ELSE EXTRACT(EPOCH FROM charttime - LAG(charttime) OVER w) / 60.0
    END AS tm_since_last_uo,
    uo.charttime,
    uo.urineoutput
  FROM tm
  INNER JOIN mc_urine_output AS uo
    ON tm.stay_id = uo.stay_id
  WINDOW w AS (PARTITION BY tm.stay_id ORDER BY charttime NULLS FIRST)
), ur_stg AS (
  SELECT
    io.stay_id,
    io.charttime, /* we have joined each row to all rows preceding within 24 hours */ /* we can now sum these rows to get total UO over the last 24 hours */ /* we can use case statements to restrict it to only the last 6/12 hours */ /* therefore we have three sums: */ /* 1) over a 6 hour period */ /* 2) over a 12 hour period */ /* 3) over a 24 hour period */
    SUM(DISTINCT io.urineoutput) AS uo, /* note that we assume data charted at charttime corresponds */ /* to 1 hour of UO, therefore we use '5' and '11' to restrict the */ /* period, rather than 6/12 this assumption may overestimate UO rate */ /* when documentation is done less than hourly */
    SUM(
      CASE
        WHEN EXTRACT(EPOCH FROM io.charttime - iosum.charttime) / 3600.0 <= 5
        THEN iosum.urineoutput
        ELSE NULL
      END
    ) AS urineoutput_6hr,
    CAST(SUM(
      CASE
        WHEN EXTRACT(EPOCH FROM io.charttime - iosum.charttime) / 3600.0 <= 5
        THEN iosum.tm_since_last_uo
        ELSE NULL
      END
    ) AS DOUBLE PRECISION) / 60.0 AS uo_tm_6hr,
    SUM(
      CASE
        WHEN EXTRACT(EPOCH FROM io.charttime - iosum.charttime) / 3600.0 <= 11
        THEN iosum.urineoutput
        ELSE NULL
      END
    ) AS urineoutput_12hr,
    CAST(SUM(
      CASE
        WHEN EXTRACT(EPOCH FROM io.charttime - iosum.charttime) / 3600.0 <= 11
        THEN iosum.tm_since_last_uo
        ELSE NULL
      END
    ) AS DOUBLE PRECISION) / 60.0 AS uo_tm_12hr, /* 24 hours */
    SUM(iosum.urineoutput) AS urineoutput_24hr,
    CAST(SUM(iosum.tm_since_last_uo) AS DOUBLE PRECISION) / 60.0 AS uo_tm_24hr
  FROM uo_tm AS io
  /* this join gives you all UO measurements over a 24 hour period */
  LEFT JOIN uo_tm AS iosum
    ON io.stay_id = iosum.stay_id
    AND io.charttime >= iosum.charttime
    AND io.charttime <= (
      iosum.charttime + INTERVAL '23 HOUR'
    )
  GROUP BY
    io.stay_id,
    io.charttime
)
SELECT
  ur.stay_id,
  ur.charttime,
  wd.weight,
  ur.uo,
  ur.urineoutput_6hr,
  ur.urineoutput_12hr,
  ur.urineoutput_24hr,
  CASE
    WHEN uo_tm_6hr >= 6
    THEN ROUND(
      CAST((
        CAST(CAST(ur.urineoutput_6hr AS DOUBLE PRECISION) / wd.weight AS DOUBLE PRECISION) / uo_tm_6hr
      ) AS DECIMAL),
      4
    )
  END AS uo_mlkghr_6hr,
  CASE
    WHEN uo_tm_12hr >= 12
    THEN ROUND(
      CAST((
        CAST(CAST(ur.urineoutput_12hr AS DOUBLE PRECISION) / wd.weight AS DOUBLE PRECISION) / uo_tm_12hr
      ) AS DECIMAL),
      4
    )
  END AS uo_mlkghr_12hr,
  CASE
    WHEN uo_tm_24hr >= 24
    THEN ROUND(
      CAST((
        CAST(CAST(ur.urineoutput_24hr AS DOUBLE PRECISION) / wd.weight AS DOUBLE PRECISION) / uo_tm_24hr
      ) AS DECIMAL),
      4
    )
  END AS uo_mlkghr_24hr, /* time of earliest UO measurement that was used to calculate the rate */
  ROUND(CAST(uo_tm_6hr AS DECIMAL), 2) AS uo_tm_6hr,
  ROUND(CAST(uo_tm_12hr AS DECIMAL), 2) AS uo_tm_12hr,
  ROUND(CAST(uo_tm_24hr AS DECIMAL), 2) AS uo_tm_24hr
FROM ur_stg AS ur
LEFT JOIN mc_weight_durations AS wd
  ON ur.stay_id = wd.stay_id
  AND ur.charttime > wd.starttime
  AND ur.charttime <= wd.endtime
  AND wd.weight > 0
),
mc_oxygen_delivery AS (
WITH ce_stg1 AS (
  SELECT
    ce.subject_id,
    ce.stay_id,
    ce.charttime,
    CASE WHEN itemid IN (223834, 227582) THEN 223834 ELSE itemid END AS itemid,
    value,
    valuenum,
    valueuom,
    storetime
  FROM mimiciv_icu.chartevents AS ce
  WHERE
    NOT ce.value IS NULL
    AND ce.itemid IN (223834 /* o2 flow */, 227582 /* bipap o2 flow */ /* below flow rate is *not* o2 flow, and not included */ /* , 224691 -- Flow Rate (L) */ /* additional o2 flow is its own column */, 227287 /* additional o2 flow */)
), ce_stg2 AS (
  SELECT
    ce.subject_id,
    ce.stay_id,
    ce.charttime,
    itemid,
    value,
    valuenum,
    valueuom, /* retain only 1 row per charttime */ /* prioritizing the last documented value */ /* primarily used to subselect o2 flows */
    ROW_NUMBER() OVER (PARTITION BY subject_id, charttime, itemid ORDER BY storetime DESC NULLS LAST) AS rn
  FROM ce_stg1 AS ce
), o2 AS (
  /* The below ITEMID can have multiple entries for charttime/storetime */ /* These are valid entries, and should be retained in derived tables. */ /*   224181 -- Small Volume Neb Drug #1       | Respiratory | Text */ /* , 227570 -- Small Volume Neb Drug/Dose #1  | Respiratory | Text */ /* , 224833 -- SBT Deferred                   | Respiratory | Text */ /* , 224716 -- SBT Stopped                    | Respiratory | Text */ /* , 224740 -- RSBI Deferred                  | Respiratory | Text */ /* , 224829 -- Trach Tube Type                | Respiratory | Text */ /* , 226732 -- O2 Delivery Device(s)          | Respiratory | Text */ /* , 226873 -- Inspiratory Ratio              | Respiratory | Numeric */ /* , 226871 -- Expiratory Ratio               | Respiratory | Numeric */ /* maximum of 4 o2 devices on at once */
  SELECT
    subject_id,
    stay_id,
    charttime,
    itemid,
    value AS o2_device,
    ROW_NUMBER() OVER (PARTITION BY subject_id, charttime, itemid ORDER BY value NULLS FIRST) AS rn
  FROM mimiciv_icu.chartevents
  WHERE
    itemid = 226732 /* oxygen delivery device(s) */
), stg AS (
  SELECT
    COALESCE(ce.subject_id, o2.subject_id) AS subject_id,
    COALESCE(ce.stay_id, o2.stay_id) AS stay_id,
    COALESCE(ce.charttime, o2.charttime) AS charttime,
    COALESCE(ce.itemid, o2.itemid) AS itemid,
    ce.value,
    ce.valuenum,
    o2.o2_device,
    o2.rn
  FROM ce_stg2 AS ce
  FULL OUTER JOIN o2
    ON ce.subject_id = o2.subject_id AND ce.charttime = o2.charttime
  /* limit to 1 row per subject_id/charttime/itemid from ce_stg2 */
  WHERE
    ce.rn = 1
)
SELECT
  subject_id,
  MAX(stay_id) AS stay_id,
  charttime,
  MAX(CASE WHEN itemid = 223834 THEN valuenum ELSE NULL END) AS o2_flow,
  MAX(CASE WHEN itemid = 227287 THEN valuenum ELSE NULL END) AS o2_flow_additional, /* ensure we retain all o2 devices for the patient */
  MAX(CASE WHEN rn = 1 THEN o2_device ELSE NULL END) AS o2_delivery_device_1,
  MAX(CASE WHEN rn = 2 THEN o2_device ELSE NULL END) AS o2_delivery_device_2,
  MAX(CASE WHEN rn = 3 THEN o2_device ELSE NULL END) AS o2_delivery_device_3,
  MAX(CASE WHEN rn = 4 THEN o2_device ELSE NULL END) AS o2_delivery_device_4
FROM stg
GROUP BY
  subject_id,
  charttime
),
mc_ventilator_setting AS (
WITH ce AS (
  SELECT
    ce.subject_id,
    ce.stay_id,
    ce.charttime,
    itemid, /* TODO: clean */
    value,
    CASE
      WHEN itemid = 223835
      THEN CASE
        WHEN valuenum >= 0.20 AND valuenum <= 1
        THEN valuenum * 100
        WHEN valuenum > 1 AND valuenum < 20
        THEN NULL
        WHEN valuenum >= 20 AND valuenum <= 100
        THEN valuenum
        ELSE NULL
      END
      WHEN itemid IN (220339, 224700)
      THEN CASE WHEN valuenum > 100 THEN NULL WHEN valuenum < 0 THEN NULL ELSE valuenum END
      ELSE valuenum
    END AS valuenum,
    valueuom,
    storetime
  FROM mimiciv_icu.chartevents AS ce
  WHERE
    NOT ce.value IS NULL
    AND NOT ce.stay_id IS NULL
    AND ce.itemid IN (224688 /* Respiratory Rate (Set) */, 224689 /* Respiratory Rate (spontaneous) */, 224690 /* Respiratory Rate (Total) */, 224687 /* minute volume */, 224685, 224684, 224686 /* tidal volume */, 224696 /* PlateauPressure */, 220339, 224700 /* PEEP */, 223835 /* fio2 */, 223849 /* vent mode */, 229314 /* vent mode (Hamilton) */, 223848 /* vent type */, 224691 /* Flow Rate (L) */)
)
SELECT
  subject_id,
  MAX(stay_id) AS stay_id,
  charttime,
  MAX(CASE WHEN itemid = 224688 THEN valuenum ELSE NULL END) AS respiratory_rate_set,
  MAX(CASE WHEN itemid = 224690 THEN valuenum ELSE NULL END) AS respiratory_rate_total,
  MAX(CASE WHEN itemid = 224689 THEN valuenum ELSE NULL END) AS respiratory_rate_spontaneous,
  MAX(CASE WHEN itemid = 224687 THEN valuenum ELSE NULL END) AS minute_volume,
  MAX(CASE WHEN itemid = 224684 THEN valuenum ELSE NULL END) AS tidal_volume_set,
  MAX(CASE WHEN itemid = 224685 THEN valuenum ELSE NULL END) AS tidal_volume_observed,
  MAX(CASE WHEN itemid = 224686 THEN valuenum ELSE NULL END) AS tidal_volume_spontaneous,
  MAX(CASE WHEN itemid = 224696 THEN valuenum ELSE NULL END) AS plateau_pressure,
  MAX(CASE WHEN itemid IN (220339, 224700) THEN valuenum ELSE NULL END) AS peep,
  MAX(CASE WHEN itemid = 223835 THEN valuenum ELSE NULL END) AS fio2,
  MAX(CASE WHEN itemid = 224691 THEN valuenum ELSE NULL END) AS flow_rate,
  MAX(CASE WHEN itemid = 223849 THEN value ELSE NULL END) AS ventilator_mode,
  MAX(CASE WHEN itemid = 229314 THEN value ELSE NULL END) AS ventilator_mode_hamilton,
  MAX(CASE WHEN itemid = 223848 THEN value ELSE NULL END) AS ventilator_type
FROM ce
GROUP BY
  subject_id,
  charttime
),
mc_ventilation AS (
/* create the durations for each ventilation instance */
/* Classify oxygen devices and ventilator modes into six clinical categories. */ /* Categories include.. */ /*  Invasive oxygen delivery types: */ /*      Tracheostomy (with or without positive pressure ventilation) */ /*      InvasiveVent (positive pressure ventilation via endotracheal tube, */ /*          could be oro/nasotracheal or tracheostomy) */ /*  Non invasive oxygen delivery types (ref doi:10.1001/jama.2020.9524): */ /*      NonInvasiveVent (non-invasive positive pressure ventilation) */ /*      HFNC (high flow nasal oxygen / cannula) */ /*      SupplementalOxygen (all other non-rebreather, */ /*          facemask, face tent, nasal prongs...) */ /*  No oxygen device: */ /*      None */ /* When conflicting settings occur (rare), the priority is: */ /*  trach > mech vent > NIV > high flow > o2 */ /* Some useful cases for debugging: */ /*  stay_id = 30019660 has a tracheostomy placed in the ICU */ /*  stay_id = 30000117 has explicit documentation of extubation */ /* first we collect all times which have relevant documentation */
WITH tm AS (
  SELECT
    stay_id,
    charttime
  FROM mc_ventilator_setting
  UNION
  SELECT
    stay_id,
    charttime
  FROM mc_oxygen_delivery
), vs AS (
  SELECT
    tm.stay_id,
    tm.charttime, /* source data columns, here for debug */
    o2_delivery_device_1,
    COALESCE(ventilator_mode, ventilator_mode_hamilton) AS vent_mode, /* case statement determining the type of intervention */ /* done in order of priority: trach > mech vent > NIV > high flow > o2 */
    CASE
      WHEN o2_delivery_device_1 IN ('Tracheostomy tube' /* 1135 observations for T-Piece */ /* could be either InvasiveVent or Tracheostomy, so omit */ /* 'T-piece', */, 'Trach mask ' /* 16435 observations */)
      THEN 'Tracheostomy'
      WHEN o2_delivery_device_1 IN ('Endotracheal tube')
      OR ventilator_mode IN ('(S) CMV', 'APRV', 'APRV/Biphasic+ApnPress', 'APRV/Biphasic+ApnVol', 'APV (cmv)', 'Ambient', 'Apnea Ventilation', 'CMV', 'CMV/ASSIST', 'CMV/ASSIST/AutoFlow', 'CMV/AutoFlow', 'CPAP/PPS', 'CPAP/PSV', 'CPAP/PSV+Apn TCPL', 'CPAP/PSV+ApnPres', 'CPAP/PSV+ApnVol', 'MMV', 'MMV/AutoFlow', 'MMV/PSV', 'MMV/PSV/AutoFlow', 'P-CMV', 'PCV+', 'PCV+/PSV', 'PCV+Assist', 'PRES/AC', 'PRVC/AC', 'PRVC/SIMV', 'PSV/SBT', 'SIMV', 'SIMV/AutoFlow', 'SIMV/PRES', 'SIMV/PSV', 'SIMV/PSV/AutoFlow', 'SIMV/VOL', 'SYNCHRON MASTER', 'SYNCHRON SLAVE', 'VOL/AC')
      OR ventilator_mode_hamilton IN ('APRV', 'APV (cmv)', 'Ambient', '(S) CMV', 'P-CMV', 'SIMV', 'APV (simv)', 'P-SIMV', 'VS', 'ASV')
      THEN 'InvasiveVent'
      WHEN o2_delivery_device_1 IN ('Bipap mask ' /* 8997 observations */, 'CPAP mask ' /* 5568 observations */)
      OR ventilator_mode_hamilton IN ('DuoPaP', 'NIV', 'NIV-ST')
      THEN 'NonInvasiveVent'
      WHEN o2_delivery_device_1 IN ('High flow nasal cannula' /* 925 observations */)
      THEN 'HFNC'
      WHEN o2_delivery_device_1 IN ('Non-rebreather' /* 5182 observations */, 'Face tent' /* 24601 observations */, 'Aerosol-cool' /* 24560 observations */, 'Venti mask ' /* 1947 observations */, 'Medium conc mask ' /* 1888 observations */, 'Ultrasonic neb' /* 9 observations */, 'Vapomist' /* 3 observations */, 'Oxymizer' /* 1301 observations */, 'High flow neb' /* 10785 observations */, 'Nasal cannula')
      THEN 'SupplementalOxygen'
      WHEN o2_delivery_device_1 IN ('None')
      THEN 'None'
      ELSE NULL
    END AS ventilation_status
  FROM tm
  LEFT JOIN mc_ventilator_setting AS vs
    ON tm.stay_id = vs.stay_id AND tm.charttime = vs.charttime
  LEFT JOIN mc_oxygen_delivery AS od
    ON tm.stay_id = od.stay_id AND tm.charttime = od.charttime
), vd0 AS (
  SELECT
    stay_id,
    charttime, /* source data columns, here for debug */ /* , o2_delivery_device_1 */ /* , vent_mode */ /* carry over the previous charttime which had the same state */
    LAG(charttime, 1) OVER (PARTITION BY stay_id, ventilation_status ORDER BY charttime NULLS FIRST) AS charttime_lag, /* bring back the next charttime, regardless of the state */ /* this will be used as the end time for state transitions */
    LEAD(charttime, 1) OVER w AS charttime_lead,
    ventilation_status,
    LAG(ventilation_status, 1) OVER w AS ventilation_status_lag
  FROM vs
  WHERE
    NOT ventilation_status IS NULL
  WINDOW w AS (PARTITION BY stay_id ORDER BY charttime NULLS FIRST)
), vd1 AS (
  SELECT
    stay_id,
    charttime,
    charttime_lag,
    charttime_lead,
    ventilation_status, /* source data columns, here for debug */ /* , o2_delivery_device_1 */ /* , vent_mode */ /* calculate the time since the last event */
    CAST(EXTRACT(EPOCH FROM charttime - charttime_lag) / 60.0 AS DOUBLE PRECISION) / 60 AS ventduration, /* now we determine if the current ventilation status is "new", */ /* or continuing the previous event */
    CASE
      WHEN ventilation_status_lag IS NULL
      THEN 1
      WHEN EXTRACT(EPOCH FROM charttime - charttime_lag) / 3600.0 >= 14
      THEN 1
      WHEN ventilation_status_lag <> ventilation_status
      THEN 1
      ELSE 0
    END AS new_ventilation_event
  FROM vd0
), vd2 AS (
  SELECT
    vd1.stay_id,
    vd1.charttime,
    vd1.charttime_lead,
    vd1.ventilation_status,
    ventduration,
    new_ventilation_event, /* create a cumulative sum of the instances of new ventilation */ /* this results in a monotonically increasing integer assigned */ /* to each instance of ventilation */
    SUM(new_ventilation_event) OVER (PARTITION BY stay_id ORDER BY charttime NULLS FIRST) AS vent_seq
  FROM vd1
)
SELECT
  stay_id,
  MIN(charttime) AS starttime, /* for the end time of the ventilation event, the time of the *next* setting */ /* i.e. if we go NIV -> O2, the end time of NIV is the first row */ /* with a documented O2 device */ /* ... unless it's been over 14 hours, */ /* in which case it's the last row with a documented NIV. */
  MAX(
    CASE
      WHEN charttime_lead IS NULL
      OR EXTRACT(EPOCH FROM charttime_lead - charttime) / 3600.0 >= 14
      THEN charttime
      ELSE charttime_lead
    END
  ) AS endtime, /* all rows with the same vent_num will have the same ventilation_status */ /* for efficiency, we use an aggregate here, */ /* but we could equally well group by this column */
  MAX(ventilation_status) AS ventilation_status
FROM vd2
GROUP BY
  stay_id,
  vent_seq
HAVING
  MIN(charttime) <> MAX(charttime)
),
mc_vitalsign AS (
/* This query pivots the vital signs for the entire patient stay. */ /* The result is a tabler with stay_id, charttime, and various */ /* vital signs, with one row per charted time. */
SELECT
  ce.subject_id,
  ce.stay_id,
  ce.charttime,
  AVG(
    CASE WHEN itemid IN (220045) AND valuenum > 0 AND valuenum < 300 THEN valuenum END
  ) AS heart_rate,
  AVG(
    CASE
      WHEN itemid IN (220179, 220050, 225309) AND valuenum > 0 AND valuenum < 400
      THEN valuenum
    END
  ) AS sbp,
  AVG(
    CASE
      WHEN itemid IN (220180, 220051, 225310) AND valuenum > 0 AND valuenum < 300
      THEN valuenum
    END
  ) AS dbp,
  AVG(
    CASE
      WHEN itemid IN (220052, 220181, 225312) AND valuenum > 0 AND valuenum < 300
      THEN valuenum
    END
  ) AS mbp,
  AVG(CASE WHEN itemid = 220179 AND valuenum > 0 AND valuenum < 400 THEN valuenum END) AS sbp_ni,
  AVG(CASE WHEN itemid = 220180 AND valuenum > 0 AND valuenum < 300 THEN valuenum END) AS dbp_ni,
  AVG(CASE WHEN itemid = 220181 AND valuenum > 0 AND valuenum < 300 THEN valuenum END) AS mbp_ni,
  AVG(
    CASE
      WHEN itemid IN (220210, 224690) AND valuenum > 0 AND valuenum < 70
      THEN valuenum
    END
  ) AS resp_rate,
  ROUND(
    CAST(AVG(
      CASE
        WHEN itemid IN (223761) AND valuenum > 70 AND valuenum < 120
        THEN CAST((
          valuenum - 32
        ) AS DOUBLE PRECISION) / 1.8
        WHEN itemid IN (223762) AND valuenum > 10 AND valuenum < 50
        THEN valuenum
      END
    ) AS DECIMAL),
    2
  ) AS temperature,
  MAX(CASE WHEN itemid = 224642 THEN value END) AS temperature_site,
  AVG(
    CASE WHEN itemid IN (220277) AND valuenum > 0 AND valuenum <= 100 THEN valuenum END
  ) AS spo2,
  AVG(CASE WHEN itemid IN (225664, 220621, 226537) AND valuenum > 0 THEN valuenum END) AS glucose
FROM mimiciv_icu.chartevents AS ce
WHERE
  NOT ce.stay_id IS NULL
  AND ce.itemid IN (220045 /* Heart Rate */, 225309 /* ART BP Systolic */, 225310 /* ART BP Diastolic */, 225312 /* ART BP Mean */, 220050 /* Arterial Blood Pressure systolic */, 220051 /* Arterial Blood Pressure diastolic */, 220052 /* Arterial Blood Pressure mean */, 220179 /* Non Invasive Blood Pressure systolic */, 220180 /* Non Invasive Blood Pressure diastolic */, 220181 /* Non Invasive Blood Pressure mean */, 220210 /* Respiratory Rate */, 224690 /* Respiratory Rate (Total) */, 220277 /* SPO2, peripheral */ /* GLUCOSE, both lab and fingerstick */, 225664 /* Glucose finger stick */, 220621 /* Glucose (serum) */, 226537 /* Glucose (whole blood) */ /* TEMPERATURE */ /* 226329 -- Blood Temperature CCO (C) */, 223762 /* "Temperature Celsius" */, 223761 /* "Temperature Fahrenheit" */, 224642 /* Temperature Site */)
GROUP BY
  ce.subject_id,
  ce.stay_id,
  ce.charttime
),
mc_sofa AS (
/* ------------------------------------------------------------------ */ /* Title: Sequential Organ Failure Assessment (SOFA) */ /* This query extracts the sequential organ failure assessment */ /* (formally: sepsis-related organ failure assessment). */ /* This score is a measure of organ failure for patients in the ICU. */ /* The score is calculated for **every hour** of the patient's ICU stay. */ /* However, as the calculation window is 24 hours, care should be */ /* taken when using the score before the end of the first day, */ /* as the data window is limited. */ /* ------------------------------------------------------------------ */ /* Reference for SOFA: */ /*    Jean-Louis Vincent, Rui Moreno, Jukka Takala, Sheila Willatts, */ /*    Arnaldo De Mendonça, Hajo Bruining, C. K. Reinhart, */ /*    Peter M Suter, and L. G. Thijs. */ /*    "The SOFA (Sepsis-related Organ Failure Assessment) score to */ /*     describe organ dysfunction/failure." */ /*    Intensive care medicine 22, no. 7 (1996): 707-710. */ /* Variables used in SOFA: */ /*  GCS, MAP, FiO2, Ventilation status (chartevents) */ /*  Creatinine, Bilirubin, FiO2, PaO2, Platelets (labevents) */ /*  Dopamine, Dobutamine, Epinephrine, Norepinephrine (inputevents) */ /*  Urine output (outputevents) */ /* use icustay_hourly to get a row for every hour the patient was in the ICU */ /* all of our joins to data will use these times */ /* to extract data pertinent to only that hour */
WITH co AS (
  SELECT
    ih.stay_id,
    ie.hadm_id,
    hr, /* start/endtime can be used to filter to values within this hour */
    ih.endtime - INTERVAL '1 HOUR' AS starttime,
    ih.endtime
  FROM mc_icustay_hourly AS ih
  INNER JOIN mimiciv_icu.icustays AS ie
    ON ih.stay_id = ie.stay_id
), pafi AS (
  /* join blood gas to ventilation durations to determine if patient was vent */
  SELECT
    ie.stay_id,
    bg.charttime, /* because pafi has an interaction between vent/PaO2:FiO2, */ /* we need two columns for the score */ /* it can happen that the lowest unventilated PaO2/FiO2 is 68, */ /* but the lowest ventilated PaO2/FiO2 is 120 */ /* in this case, the SOFA score is 3, *not* 4. */
    CASE WHEN vd.stay_id IS NULL THEN pao2fio2ratio ELSE NULL END AS pao2fio2ratio_novent,
    CASE WHEN NOT vd.stay_id IS NULL THEN pao2fio2ratio ELSE NULL END AS pao2fio2ratio_vent
  FROM mimiciv_icu.icustays AS ie
  INNER JOIN mc_bg AS bg
    ON ie.subject_id = bg.subject_id
  LEFT JOIN mc_ventilation AS vd
    ON ie.stay_id = vd.stay_id
    AND bg.charttime >= vd.starttime
    AND bg.charttime <= vd.endtime
    AND vd.ventilation_status = 'InvasiveVent'
  WHERE
    specimen = 'ART.'
), vs AS (
  SELECT
    co.stay_id,
    co.hr, /* vitals */
    MIN(vs.mbp) AS meanbp_min
  FROM co
  LEFT JOIN mc_vitalsign AS vs
    ON co.stay_id = vs.stay_id AND co.starttime < vs.charttime AND co.endtime >= vs.charttime
  GROUP BY
    co.stay_id,
    co.hr
), gcs AS (
  SELECT
    co.stay_id,
    co.hr, /* gcs */
    MIN(gcs.gcs) AS gcs_min
  FROM co
  LEFT JOIN mc_gcs AS gcs
    ON co.stay_id = gcs.stay_id AND co.starttime < gcs.charttime AND co.endtime >= gcs.charttime
  GROUP BY
    co.stay_id,
    co.hr
), bili AS (
  SELECT
    co.stay_id,
    co.hr,
    MAX(enz.bilirubin_total) AS bilirubin_max
  FROM co
  LEFT JOIN mc_enzyme AS enz
    ON co.hadm_id = enz.hadm_id AND co.starttime < enz.charttime AND co.endtime >= enz.charttime
  GROUP BY
    co.stay_id,
    co.hr
), cr AS (
  SELECT
    co.stay_id,
    co.hr,
    MAX(chem.creatinine) AS creatinine_max
  FROM co
  LEFT JOIN mc_chemistry AS chem
    ON co.hadm_id = chem.hadm_id
    AND co.starttime < chem.charttime
    AND co.endtime >= chem.charttime
  GROUP BY
    co.stay_id,
    co.hr
), plt AS (
  SELECT
    co.stay_id,
    co.hr,
    MIN(cbc.platelet) AS platelet_min
  FROM co
  LEFT JOIN mc_complete_blood_count AS cbc
    ON co.hadm_id = cbc.hadm_id AND co.starttime < cbc.charttime AND co.endtime >= cbc.charttime
  GROUP BY
    co.stay_id,
    co.hr
), pf AS (
  SELECT
    co.stay_id,
    co.hr,
    MIN(pafi.pao2fio2ratio_novent) AS pao2fio2ratio_novent,
    MIN(pafi.pao2fio2ratio_vent) AS pao2fio2ratio_vent
  FROM co
  /* bring in blood gases that occurred during this hour */
  LEFT JOIN pafi
    ON co.stay_id = pafi.stay_id
    AND co.starttime < pafi.charttime
    AND co.endtime >= pafi.charttime
  GROUP BY
    co.stay_id,
    co.hr
), uo AS (
  SELECT
    co.stay_id,
    co.hr, /* uo */
    MAX(
      CASE
        WHEN uo.uo_tm_24hr >= 22 AND uo.uo_tm_24hr <= 30
        THEN CAST(uo.urineoutput_24hr AS DOUBLE PRECISION) / uo.uo_tm_24hr * 24
      END
    ) AS uo_24hr
  FROM co
  LEFT JOIN mc_urine_output_rate AS uo
    ON co.stay_id = uo.stay_id AND co.starttime < uo.charttime AND co.endtime >= uo.charttime
  GROUP BY
    co.stay_id,
    co.hr
), vaso AS (
  SELECT
    co.stay_id,
    co.hr,
    MAX(epi.vaso_rate) AS rate_epinephrine,
    MAX(nor.vaso_rate) AS rate_norepinephrine,
    MAX(dop.vaso_rate) AS rate_dopamine,
    MAX(dob.vaso_rate) AS rate_dobutamine
  FROM co
  LEFT JOIN mc_epinephrine AS epi
    ON co.stay_id = epi.stay_id AND co.endtime > epi.starttime AND co.endtime <= epi.endtime
  LEFT JOIN mc_norepinephrine AS nor
    ON co.stay_id = nor.stay_id AND co.endtime > nor.starttime AND co.endtime <= nor.endtime
  LEFT JOIN mc_dopamine AS dop
    ON co.stay_id = dop.stay_id AND co.endtime > dop.starttime AND co.endtime <= dop.endtime
  LEFT JOIN mc_dobutamine AS dob
    ON co.stay_id = dob.stay_id AND co.endtime > dob.starttime AND co.endtime <= dob.endtime
  WHERE
    NOT epi.stay_id IS NULL
    OR NOT nor.stay_id IS NULL
    OR NOT dop.stay_id IS NULL
    OR NOT dob.stay_id IS NULL
  GROUP BY
    co.stay_id,
    co.hr
), scorecomp AS (
  SELECT
    co.stay_id,
    co.hr,
    co.starttime,
    co.endtime,
    pf.pao2fio2ratio_novent,
    pf.pao2fio2ratio_vent,
    vaso.rate_epinephrine,
    vaso.rate_norepinephrine,
    vaso.rate_dopamine,
    vaso.rate_dobutamine,
    vs.meanbp_min,
    gcs.gcs_min, /* uo */
    uo.uo_24hr, /* labs */
    bili.bilirubin_max,
    cr.creatinine_max,
    plt.platelet_min
  FROM co
  LEFT JOIN vs
    ON co.stay_id = vs.stay_id AND co.hr = vs.hr
  LEFT JOIN gcs
    ON co.stay_id = gcs.stay_id AND co.hr = gcs.hr
  LEFT JOIN bili
    ON co.stay_id = bili.stay_id AND co.hr = bili.hr
  LEFT JOIN cr
    ON co.stay_id = cr.stay_id AND co.hr = cr.hr
  LEFT JOIN plt
    ON co.stay_id = plt.stay_id AND co.hr = plt.hr
  LEFT JOIN pf
    ON co.stay_id = pf.stay_id AND co.hr = pf.hr
  LEFT JOIN uo
    ON co.stay_id = uo.stay_id AND co.hr = uo.hr
  LEFT JOIN vaso
    ON co.stay_id = vaso.stay_id AND co.hr = vaso.hr
), scorecalc AS (
  /* Calculate the final score */ /* note that if the underlying data is missing, */ /* the component is null */ /* eventually these are treated as 0 (normal), */ /* but knowing when data is missing is useful for debugging */
  SELECT
    scorecomp.*, /* Respiration */
    CASE
      WHEN pao2fio2ratio_vent < 100
      THEN 4
      WHEN pao2fio2ratio_vent < 200
      THEN 3
      WHEN pao2fio2ratio_novent < 300
      THEN 2
      WHEN pao2fio2ratio_vent < 300
      THEN 2
      WHEN pao2fio2ratio_novent < 400
      THEN 1
      WHEN pao2fio2ratio_vent < 400
      THEN 1
      WHEN COALESCE(pao2fio2ratio_vent, pao2fio2ratio_novent) IS NULL
      THEN NULL
      ELSE 0
    END AS respiration, /* Coagulation */
    CASE
      WHEN platelet_min < 20
      THEN 4
      WHEN platelet_min < 50
      THEN 3
      WHEN platelet_min < 100
      THEN 2
      WHEN platelet_min < 150
      THEN 1
      WHEN platelet_min IS NULL
      THEN NULL
      ELSE 0
    END AS coagulation, /* Liver */
    CASE
      WHEN bilirubin_max >= 12.0
      THEN 4
      WHEN bilirubin_max >= 6.0
      THEN 3
      WHEN bilirubin_max >= 2.0
      THEN 2
      WHEN bilirubin_max >= 1.2
      THEN 1
      WHEN bilirubin_max IS NULL
      THEN NULL
      ELSE 0
    END AS liver, /* Cardiovascular */
    CASE
      WHEN rate_dopamine > 15 OR rate_epinephrine > 0.1 OR rate_norepinephrine > 0.1
      THEN 4
      WHEN rate_dopamine > 5 OR rate_epinephrine <= 0.1 OR rate_norepinephrine <= 0.1
      THEN 3
      WHEN rate_dopamine > 0 OR rate_dobutamine > 0
      THEN 2
      WHEN meanbp_min < 70
      THEN 1
      WHEN COALESCE(meanbp_min, rate_dopamine, rate_dobutamine, rate_epinephrine, rate_norepinephrine) IS NULL
      THEN NULL
      ELSE 0
    END AS cardiovascular, /* Neurological failure (GCS) */
    CASE
      WHEN (
        gcs_min >= 13 AND gcs_min <= 14
      )
      THEN 1
      WHEN (
        gcs_min >= 10 AND gcs_min <= 12
      )
      THEN 2
      WHEN (
        gcs_min >= 6 AND gcs_min <= 9
      )
      THEN 3
      WHEN gcs_min < 6
      THEN 4
      WHEN gcs_min IS NULL
      THEN NULL
      ELSE 0
    END AS cns, /* Renal failure - high creatinine or low urine output */
    CASE
      WHEN (
        creatinine_max >= 5.0
      )
      THEN 4
      WHEN uo_24hr < 200
      THEN 4
      WHEN (
        creatinine_max >= 3.5 AND creatinine_max < 5.0
      )
      THEN 3
      WHEN uo_24hr < 500
      THEN 3
      WHEN (
        creatinine_max >= 2.0 AND creatinine_max < 3.5
      )
      THEN 2
      WHEN (
        creatinine_max >= 1.2 AND creatinine_max < 2.0
      )
      THEN 1
      WHEN COALESCE(uo_24hr, creatinine_max) IS NULL
      THEN NULL
      ELSE 0
    END AS renal
  FROM scorecomp
), score_final AS (
  SELECT
    s.*, /* Combine all the scores to get SOFA */ /* Impute 0 if the score is missing */ /* the window function takes the max over the last 24 hours */
    COALESCE(MAX(respiration) OVER w, 0) AS respiration_24hours,
    COALESCE(MAX(coagulation) OVER w, 0) AS coagulation_24hours,
    COALESCE(MAX(liver) OVER w, 0) AS liver_24hours,
    COALESCE(MAX(cardiovascular) OVER w, 0) AS cardiovascular_24hours,
    COALESCE(MAX(cns) OVER w, 0) AS cns_24hours,
    COALESCE(MAX(renal) OVER w, 0) AS renal_24hours, /* sum together data for final SOFA */
    COALESCE(MAX(respiration) OVER w, 0) + COALESCE(MAX(coagulation) OVER w, 0) + COALESCE(MAX(liver) OVER w, 0) + COALESCE(MAX(cardiovascular) OVER w, 0) + COALESCE(MAX(cns) OVER w, 0) + COALESCE(MAX(renal) OVER w, 0) AS sofa_24hours
  FROM scorecalc AS s
  WINDOW w AS (PARTITION BY stay_id ORDER BY hr NULLS FIRST ROWS BETWEEN 23 PRECEDING AND 0 FOLLOWING)
)
SELECT
  *
FROM score_final
WHERE
  hr >= 0
),
mc_antibiotic AS (
WITH abx AS (
  SELECT DISTINCT
    drug,
    route,
    CASE
      WHEN LOWER(drug) LIKE '%adoxa%'
      THEN 1
      WHEN LOWER(drug) LIKE '%ala-tet%'
      THEN 1
      WHEN LOWER(drug) LIKE '%alodox%'
      THEN 1
      WHEN LOWER(drug) LIKE '%amikacin%'
      THEN 1
      WHEN LOWER(drug) LIKE '%amikin%'
      THEN 1
      WHEN LOWER(drug) LIKE '%amoxicill%'
      THEN 1
      WHEN LOWER(drug) LIKE '%amphotericin%'
      THEN 1
      WHEN LOWER(drug) LIKE '%anidulafungin%'
      THEN 1
      WHEN LOWER(drug) LIKE '%ancef%'
      THEN 1
      WHEN LOWER(drug) LIKE '%clavulanate%'
      THEN 1
      WHEN LOWER(drug) LIKE '%ampicillin%'
      THEN 1
      WHEN LOWER(drug) LIKE '%augmentin%'
      THEN 1
      WHEN LOWER(drug) LIKE '%avelox%'
      THEN 1
      WHEN LOWER(drug) LIKE '%avidoxy%'
      THEN 1
      WHEN LOWER(drug) LIKE '%azactam%'
      THEN 1
      WHEN LOWER(drug) LIKE '%azithromycin%'
      THEN 1
      WHEN LOWER(drug) LIKE '%aztreonam%'
      THEN 1
      WHEN LOWER(drug) LIKE '%axetil%'
      THEN 1
      WHEN LOWER(drug) LIKE '%bactocill%'
      THEN 1
      WHEN LOWER(drug) LIKE '%bactrim%'
      THEN 1
      WHEN LOWER(drug) LIKE '%bactroban%'
      THEN 1
      WHEN LOWER(drug) LIKE '%bethkis%'
      THEN 1
      WHEN LOWER(drug) LIKE '%biaxin%'
      THEN 1
      WHEN LOWER(drug) LIKE '%bicillin l-a%'
      THEN 1
      WHEN LOWER(drug) LIKE '%cayston%'
      THEN 1
      WHEN LOWER(drug) LIKE '%cefazolin%'
      THEN 1
      WHEN LOWER(drug) LIKE '%cedax%'
      THEN 1
      WHEN LOWER(drug) LIKE '%cefoxitin%'
      THEN 1
      WHEN LOWER(drug) LIKE '%ceftazidime%'
      THEN 1
      WHEN LOWER(drug) LIKE '%cefaclor%'
      THEN 1
      WHEN LOWER(drug) LIKE '%cefadroxil%'
      THEN 1
      WHEN LOWER(drug) LIKE '%cefdinir%'
      THEN 1
      WHEN LOWER(drug) LIKE '%cefditoren%'
      THEN 1
      WHEN LOWER(drug) LIKE '%cefepime%'
      THEN 1
      WHEN LOWER(drug) LIKE '%cefotan%'
      THEN 1
      WHEN LOWER(drug) LIKE '%cefotetan%'
      THEN 1
      WHEN LOWER(drug) LIKE '%cefotaxime%'
      THEN 1
      WHEN LOWER(drug) LIKE '%ceftaroline%'
      THEN 1
      WHEN LOWER(drug) LIKE '%cefpodoxime%'
      THEN 1
      WHEN LOWER(drug) LIKE '%cefpirome%'
      THEN 1
      WHEN LOWER(drug) LIKE '%cefprozil%'
      THEN 1
      WHEN LOWER(drug) LIKE '%ceftibuten%'
      THEN 1
      WHEN LOWER(drug) LIKE '%ceftin%'
      THEN 1
      WHEN LOWER(drug) LIKE '%ceftriaxone%'
      THEN 1
      WHEN LOWER(drug) LIKE '%cefuroxime%'
      THEN 1
      WHEN LOWER(drug) LIKE '%cephalexin%'
      THEN 1
      WHEN LOWER(drug) LIKE '%cephalothin%'
      THEN 1
      WHEN LOWER(drug) LIKE '%cephapririn%'
      THEN 1
      WHEN LOWER(drug) LIKE '%chloramphenicol%'
      THEN 1
      WHEN LOWER(drug) LIKE '%cipro%'
      THEN 1
      WHEN LOWER(drug) LIKE '%ciprofloxacin%'
      THEN 1
      WHEN LOWER(drug) LIKE '%claforan%'
      THEN 1
      WHEN LOWER(drug) LIKE '%clarithromycin%'
      THEN 1
      WHEN LOWER(drug) LIKE '%cleocin%'
      THEN 1
      WHEN LOWER(drug) LIKE '%clindamycin%'
      THEN 1
      WHEN LOWER(drug) LIKE '%cubicin%'
      THEN 1
      WHEN LOWER(drug) LIKE '%dicloxacillin%'
      THEN 1
      WHEN LOWER(drug) LIKE '%dirithromycin%'
      THEN 1
      WHEN LOWER(drug) LIKE '%doryx%'
      THEN 1
      WHEN LOWER(drug) LIKE '%doxycy%'
      THEN 1
      WHEN LOWER(drug) LIKE '%duricef%'
      THEN 1
      WHEN LOWER(drug) LIKE '%dynacin%'
      THEN 1
      WHEN LOWER(drug) LIKE '%ery-tab%'
      THEN 1
      WHEN LOWER(drug) LIKE '%eryped%'
      THEN 1
      WHEN LOWER(drug) LIKE '%eryc%'
      THEN 1
      WHEN LOWER(drug) LIKE '%erythrocin%'
      THEN 1
      WHEN LOWER(drug) LIKE '%erythromycin%'
      THEN 1
      WHEN LOWER(drug) LIKE '%factive%'
      THEN 1
      WHEN LOWER(drug) LIKE '%flagyl%'
      THEN 1
      WHEN LOWER(drug) LIKE '%fortaz%'
      THEN 1
      WHEN LOWER(drug) LIKE '%furadantin%'
      THEN 1
      WHEN LOWER(drug) LIKE '%garamycin%'
      THEN 1
      WHEN LOWER(drug) LIKE '%gentamicin%'
      THEN 1
      WHEN LOWER(drug) LIKE '%kanamycin%'
      THEN 1
      WHEN LOWER(drug) LIKE '%keflex%'
      THEN 1
      WHEN LOWER(drug) LIKE '%kefzol%'
      THEN 1
      WHEN LOWER(drug) LIKE '%ketek%'
      THEN 1
      WHEN LOWER(drug) LIKE '%levaquin%'
      THEN 1
      WHEN LOWER(drug) LIKE '%levofloxacin%'
      THEN 1
      WHEN LOWER(drug) LIKE '%lincocin%'
      THEN 1
      WHEN LOWER(drug) LIKE '%linezolid%'
      THEN 1
      WHEN LOWER(drug) LIKE '%macrobid%'
      THEN 1
      WHEN LOWER(drug) LIKE '%macrodantin%'
      THEN 1
      WHEN LOWER(drug) LIKE '%maxipime%'
      THEN 1
      WHEN LOWER(drug) LIKE '%mefoxin%'
      THEN 1
      WHEN LOWER(drug) LIKE '%metronidazole%'
      THEN 1
      WHEN LOWER(drug) LIKE '%meropenem%'
      THEN 1
      WHEN LOWER(drug) LIKE '%methicillin%'
      THEN 1
      WHEN LOWER(drug) LIKE '%minocin%'
      THEN 1
      WHEN LOWER(drug) LIKE '%minocycline%'
      THEN 1
      WHEN LOWER(drug) LIKE '%monodox%'
      THEN 1
      WHEN LOWER(drug) LIKE '%monurol%'
      THEN 1
      WHEN LOWER(drug) LIKE '%morgidox%'
      THEN 1
      WHEN LOWER(drug) LIKE '%moxatag%'
      THEN 1
      WHEN LOWER(drug) LIKE '%moxifloxacin%'
      THEN 1
      WHEN LOWER(drug) LIKE '%mupirocin%'
      THEN 1
      WHEN LOWER(drug) LIKE '%myrac%'
      THEN 1
      WHEN LOWER(drug) LIKE '%nafcillin%'
      THEN 1
      WHEN LOWER(drug) LIKE '%neomycin%'
      THEN 1
      WHEN LOWER(drug) LIKE '%nicazel doxy 30%'
      THEN 1
      WHEN LOWER(drug) LIKE '%nitrofurantoin%'
      THEN 1
      WHEN LOWER(drug) LIKE '%norfloxacin%'
      THEN 1
      WHEN LOWER(drug) LIKE '%noroxin%'
      THEN 1
      WHEN LOWER(drug) LIKE '%ocudox%'
      THEN 1
      WHEN LOWER(drug) LIKE '%ofloxacin%'
      THEN 1
      WHEN LOWER(drug) LIKE '%omnicef%'
      THEN 1
      WHEN LOWER(drug) LIKE '%oracea%'
      THEN 1
      WHEN LOWER(drug) LIKE '%oraxyl%'
      THEN 1
      WHEN LOWER(drug) LIKE '%oxacillin%'
      THEN 1
      WHEN LOWER(drug) LIKE '%pc pen vk%'
      THEN 1
      WHEN LOWER(drug) LIKE '%pce dispertab%'
      THEN 1
      WHEN LOWER(drug) LIKE '%panixine%'
      THEN 1
      WHEN LOWER(drug) LIKE '%pediazole%'
      THEN 1
      WHEN LOWER(drug) LIKE '%penicillin%'
      THEN 1
      WHEN LOWER(drug) LIKE '%periostat%'
      THEN 1
      WHEN LOWER(drug) LIKE '%pfizerpen%'
      THEN 1
      WHEN LOWER(drug) LIKE '%piperacillin%'
      THEN 1
      WHEN LOWER(drug) LIKE '%tazobactam%'
      THEN 1
      WHEN LOWER(drug) LIKE '%primsol%'
      THEN 1
      WHEN LOWER(drug) LIKE '%proquin%'
      THEN 1
      WHEN LOWER(drug) LIKE '%raniclor%'
      THEN 1
      WHEN LOWER(drug) LIKE '%rifadin%'
      THEN 1
      WHEN LOWER(drug) LIKE '%rifampin%'
      THEN 1
      WHEN LOWER(drug) LIKE '%rocephin%'
      THEN 1
      WHEN LOWER(drug) LIKE '%smz-tmp%'
      THEN 1
      WHEN LOWER(drug) LIKE '%septra%'
      THEN 1
      WHEN LOWER(drug) LIKE '%septra ds%'
      THEN 1
      WHEN LOWER(drug) LIKE '%septra%'
      THEN 1
      WHEN LOWER(drug) LIKE '%solodyn%'
      THEN 1
      WHEN LOWER(drug) LIKE '%spectracef%'
      THEN 1
      WHEN LOWER(drug) LIKE '%streptomycin%'
      THEN 1
      WHEN LOWER(drug) LIKE '%sulfadiazine%'
      THEN 1
      WHEN LOWER(drug) LIKE '%sulfamethoxazole%'
      THEN 1
      WHEN LOWER(drug) LIKE '%trimethoprim%'
      THEN 1
      WHEN LOWER(drug) LIKE '%sulfatrim%'
      THEN 1
      WHEN LOWER(drug) LIKE '%sulfisoxazole%'
      THEN 1
      WHEN LOWER(drug) LIKE '%suprax%'
      THEN 1
      WHEN LOWER(drug) LIKE '%synercid%'
      THEN 1
      WHEN LOWER(drug) LIKE '%tazicef%'
      THEN 1
      WHEN LOWER(drug) LIKE '%tetracycline%'
      THEN 1
      WHEN LOWER(drug) LIKE '%timentin%'
      THEN 1
      WHEN LOWER(drug) LIKE '%tobramycin%'
      THEN 1
      WHEN LOWER(drug) LIKE '%trimethoprim%'
      THEN 1
      WHEN LOWER(drug) LIKE '%unasyn%'
      THEN 1
      WHEN LOWER(drug) LIKE '%vancocin%'
      THEN 1
      WHEN LOWER(drug) LIKE '%vancomycin%'
      THEN 1
      WHEN LOWER(drug) LIKE '%vantin%'
      THEN 1
      WHEN LOWER(drug) LIKE '%vibativ%'
      THEN 1
      WHEN LOWER(drug) LIKE '%vibra-tabs%'
      THEN 1
      WHEN LOWER(drug) LIKE '%vibramycin%'
      THEN 1
      WHEN LOWER(drug) LIKE '%zinacef%'
      THEN 1
      WHEN LOWER(drug) LIKE '%zithromax%'
      THEN 1
      WHEN LOWER(drug) LIKE '%zosyn%'
      THEN 1
      WHEN LOWER(drug) LIKE '%zyvox%'
      THEN 1
      ELSE 0
    END AS antibiotic
  FROM mimiciv_hosp.prescriptions
  /* excludes vials/syringe/normal saline, etc */
  WHERE
    NOT drug_type IN ('BASE') /* we exclude routes via the eye, ears, or topically */
    AND NOT route IN ('OU', 'OS', 'OD', 'AU', 'AS', 'AD', 'TP')
    AND NOT LOWER(route) LIKE '%ear%'
    AND NOT LOWER(route) LIKE '%eye%'
    AND NOT LOWER(drug) LIKE '%cream%' /* we exclude certain types of antibiotics: topical creams, */ /* gels, desens, etc */
    AND NOT LOWER(drug) LIKE '%desensitization%'
    AND NOT LOWER(drug) LIKE '%ophth oint%'
    AND NOT LOWER(drug) LIKE '%gel%'
) /* other routes not sure about... */ /* for sure keep: ('IV','PO','PO/NG','ORAL', 'IV DRIP', 'IV BOLUS') */ /* ? VT, PB, PR, PL, NS, NG, NEB, NAS, LOCK, J TUBE, IVT */ /* ? IT, IRR, IP, IO, INHALATION, IN, IM */ /* ? IJ, IH, G TUBE, DIALYS */ /* ?? enemas?? */
SELECT
  pr.subject_id,
  pr.hadm_id,
  ie.stay_id,
  pr.drug AS antibiotic,
  pr.route,
  pr.starttime,
  pr.stoptime
FROM mimiciv_hosp.prescriptions AS pr
/* inner join to subselect to only antibiotic prescriptions */
INNER JOIN abx
  ON pr.drug = abx.drug AND pr.route = abx.route
/* add in stay_id as we use this table for sepsis-3 */
LEFT JOIN mimiciv_icu.icustays AS ie
  ON pr.hadm_id = ie.hadm_id AND pr.starttime >= ie.intime AND pr.starttime < ie.outtime
WHERE
  abx.antibiotic = 1
),
mc_suspicion_of_infection AS (
/* note this duplicates prescriptions */ /* each ICU stay in the same hospitalization will get a copy of */ /* all prescriptions for that hospitalization */
WITH ab_tbl AS (
  SELECT
    abx.subject_id,
    abx.hadm_id,
    abx.stay_id,
    abx.antibiotic,
    abx.starttime AS antibiotic_time, /* date is used to match microbiology cultures with only date available */
    DATE_TRUNC('DAY', abx.starttime) AS antibiotic_date,
    abx.stoptime AS antibiotic_stoptime, /* create a unique identifier for each patient antibiotic */
    ROW_NUMBER() OVER (PARTITION BY subject_id ORDER BY starttime NULLS FIRST, stoptime NULLS FIRST, antibiotic NULLS FIRST) AS ab_id
  FROM mc_antibiotic AS abx
), me AS (
  SELECT
    micro_specimen_id, /* the following columns are identical for all rows */ /* of the same micro_specimen_id */ /* these aggregates simply collapse duplicates down to 1 row */
    MAX(subject_id) AS subject_id,
    MAX(hadm_id) AS hadm_id,
    CAST(MAX(chartdate) AS DATE) AS chartdate,
    MAX(charttime) AS charttime,
    MAX(spec_type_desc) AS spec_type_desc, /* identify negative cultures as NULL organism */ /* or a specific itemid saying "NEGATIVE" */
    MAX(
      CASE
        WHEN NOT org_name IS NULL AND org_itemid <> 90856 AND org_name <> ''
        THEN 1
        ELSE 0
      END
    ) AS positiveculture
  FROM mimiciv_hosp.microbiologyevents
  GROUP BY
    micro_specimen_id
), me_then_ab AS (
  SELECT
    ab_tbl.subject_id,
    ab_tbl.hadm_id,
    ab_tbl.stay_id,
    ab_tbl.ab_id,
    me72.micro_specimen_id,
    COALESCE(me72.charttime, CAST(me72.chartdate AS TIMESTAMP)) AS last72_charttime,
    me72.positiveculture AS last72_positiveculture,
    me72.spec_type_desc AS last72_specimen, /* we will use this partition to select the earliest culture */ /* before this abx */ /* this ensures each antibiotic is only matched to a single culture */ /* and consequently we have 1 row per antibiotic */
    ROW_NUMBER() OVER (PARTITION BY ab_tbl.subject_id, ab_tbl.ab_id ORDER BY me72.chartdate NULLS FIRST, me72.charttime) AS micro_seq
  FROM ab_tbl
  /* abx taken after culture, but no more than 72 hours after */
  LEFT JOIN me AS me72
    ON ab_tbl.subject_id = me72.subject_id
    AND (
      (
        NOT me72.charttime IS NULL
        AND ab_tbl.antibiotic_time > me72.charttime
        AND ab_tbl.antibiotic_time <= me72.charttime + INTERVAL '72 HOUR'
      )
      OR (
        me72.charttime IS NULL
        AND antibiotic_date >= me72.chartdate
        AND antibiotic_date <= me72.chartdate + INTERVAL '3 DAY'
      )
    )
), ab_then_me AS (
  SELECT
    ab_tbl.subject_id,
    ab_tbl.hadm_id,
    ab_tbl.stay_id,
    ab_tbl.ab_id,
    me24.micro_specimen_id,
    COALESCE(me24.charttime, CAST(me24.chartdate AS TIMESTAMP)) AS next24_charttime,
    me24.positiveculture AS next24_positiveculture,
    me24.spec_type_desc AS next24_specimen, /* we will use this partition to select the earliest culture */ /* before this abx */ /* this ensures each antibiotic is only matched to a single culture */ /* and consequently we have 1 row per antibiotic */
    ROW_NUMBER() OVER (PARTITION BY ab_tbl.subject_id, ab_tbl.ab_id ORDER BY me24.chartdate NULLS FIRST, me24.charttime) AS micro_seq
  FROM ab_tbl
  /* culture in subsequent 24 hours */
  LEFT JOIN me AS me24
    ON ab_tbl.subject_id = me24.subject_id
    AND (
      (
        NOT me24.charttime IS NULL
        AND ab_tbl.antibiotic_time >= me24.charttime - INTERVAL '24 HOUR' /* noqa: L016 */
        AND ab_tbl.antibiotic_time < me24.charttime
      )
      OR (
        me24.charttime IS NULL
        AND ab_tbl.antibiotic_date >= me24.chartdate - INTERVAL '1 DAY' /* noqa: L016 */
        AND ab_tbl.antibiotic_date <= me24.chartdate
      )
    )
)
SELECT
  ab_tbl.subject_id,
  ab_tbl.stay_id,
  ab_tbl.hadm_id,
  ab_tbl.ab_id,
  ab_tbl.antibiotic,
  ab_tbl.antibiotic_time,
  CASE WHEN last72_specimen IS NULL AND next24_specimen IS NULL THEN 0 ELSE 1 END AS suspected_infection, /* time of suspected infection: */ /*    (1) the culture time (if before antibiotic) */ /*    (2) or the antibiotic time (if before culture) */
  CASE
    WHEN last72_specimen IS NULL AND next24_specimen IS NULL
    THEN NULL
    ELSE COALESCE(last72_charttime, antibiotic_time)
  END AS suspected_infection_time,
  COALESCE(last72_charttime, next24_charttime) AS culture_time, /* the specimen that was cultured */
  COALESCE(last72_specimen, next24_specimen) AS specimen, /* whether the cultured specimen ended up being positive or not */
  COALESCE(last72_positiveculture, next24_positiveculture) AS positive_culture
FROM ab_tbl
LEFT JOIN ab_then_me AS ab2me
  ON ab_tbl.subject_id = ab2me.subject_id
  AND ab_tbl.ab_id = ab2me.ab_id
  AND ab2me.micro_seq = 1
LEFT JOIN me_then_ab AS me2ab
  ON ab_tbl.subject_id = me2ab.subject_id
  AND ab_tbl.ab_id = me2ab.ab_id
  AND me2ab.micro_seq = 1
),
mc_rrt AS (
/* Creates a table with stay_id / time / dialysis type (if present) */
WITH ce AS (
  SELECT
    ce.stay_id,
    ce.charttime, /* when ce.itemid in (152,148,149,146,147,151,150) */ /* and value is not null then 1 */ /* when ce.itemid in (229,235,241,247,253,259,265,271) */ /* and value = 'Dialysis Line' then 1 */ /* when ce.itemid = 466 and value = 'Dialysis RN' then 1 */ /* when ce.itemid = 927 and value = 'Dialysis Solutions' then 1 */ /* when ce.itemid = 6250 and value = 'dialys' then 1 */ /* when ce. */ /* when ce.itemid = 582 and value in ('CAVH Start','CAVH D/C', */ /* 'CVVHD Start','CVVHD D/C', */ /* 'Hemodialysis st','Hemodialysis end') then 1 */
    CASE
      WHEN ce.itemid IN (226118 /* | Dialysis Catheter placed in outside facility */, 227357 /* | Dialysis Catheter Dressing Occlusive */, 225725 /* | Dialysis Catheter Tip Cultured */)
      THEN 1
      WHEN ce.itemid IN (226499 /* | Hemodialysis Output */ /* | Dialysate Rate */, 224154 /* | Dwell Time (Peritoneal Dialysis) */, 225810 /* | Medication Added Amount  #1 (Peritoneal Dialysis) */, 225959 /* | Medication Added Amount  #2 (Peritoneal Dialysis) */, 227639, 225183 /* | Current Goal */, 227438 /* | Volume not removed */, 224191 /* | Hourly Patient Fluid Removal */, 225806 /* | Volume In (PD) */, 225807 /* | Volume Out (PD) */, 228004 /* | Citrate (ACD-A) */, 228005 /* | PBP (Prefilter) Replacement Rate */, 228006 /* | Post Filter Replacement Rate */, 224144 /* | Blood Flow (ml/min) */, 224145 /* | Heparin Dose (per hour) */, 224149 /* | Access Pressure */, 224150 /* | Filter Pressure */, 224151 /* | Effluent Pressure */, 224152 /* | Return Pressure */, 224153 /* | Replacement Rate */, 224404 /* | ART Lumen Volume */, 224406 /* | VEN Lumen Volume */, 226457 /* | Ultrafiltrate Output */)
      THEN 1
      WHEN ce.itemid IN (224135 /* | Dialysis Access Site */, 224139 /* | Dialysis Site Appearance */, 224146 /* | System Integrity */ /* | Dialysis Catheter Site Appear */, 225323 /* | Dialysis Catheter Discontinued */, 225740 /* | Dialysis Catheter Dressing Type */, 225776 /* | Peritoneal Dialysis Fluid Appearance */, 225951 /* | Medication Added #1 (Peritoneal Dialysis) */, 225952, 225953 /* | Solution (Peritoneal Dialysis) */, 225954 /* | Dialysis Access Type */, 225956 /* | Reason for CRRT Filter Change */, 225958 /* | Heparin Concentration (units/mL) */ /* | Medication Added Units #1 (Peritoneal Dialysis) */, 225961, 225963 /* | Peritoneal Dialysis Catheter Type */, 225965 /* | Peritoneal Dialysis Catheter Status */, 225976 /* | Replacement Fluid */, 225977 /* | Dialysate Fluid */ /* | Dialysis Catheter Type | Access Lines - Invasive */, 227124, 227290 /* | CRRT mode */ /* | Medication Added #2 (Peritoneal Dialysis) */, 227638 /* | Medication Added Units #2 (Peritoneal Dialysis) */, 227640 /* | Dialysis Catheter Placement Confirmed by X-ray */, 227753)
      THEN 1
      ELSE 0
    END AS dialysis_present,
    CASE
      WHEN ce.itemid = 225965 /* Peritoneal Dialysis Catheter Status */ AND value = 'In use'
      THEN 1
      WHEN ce.itemid IN (226499 /* | Hemodialysis Output */, 224154 /* | Dialysate Rate */, 225183 /* | Current Goal */, 227438 /* | Volume not removed */, 224191 /* | Hourly Patient Fluid Removal */, 225806 /* | Volume In (PD) */, 225807 /* | Volume Out (PD) */, 228004 /* | Citrate (ACD-A) */, 228005 /* | PBP (Prefilter) Replacement Rat */, 228006 /* | Post Filter Replacement Rate */, 224144 /* | Blood Flow (ml/min) */, 224145 /* | Heparin Dose (per hour) */, 224153 /* | Replacement Rate */, 226457 /* | Ultrafiltrate Output */)
      THEN 1
      ELSE 0
    END AS dialysis_active,
    CASE
      WHEN ce.itemid = 227290
      THEN value
      WHEN ce.itemid IN (225810 /* | Dwell Time (Peritoneal Dialysis) */, 225806 /* | Volume In (PD) */, 225807 /* | Volume Out (PD) */ /* | Dwell Time (Peritoneal Dialysis) */, 225810 /* | Medication Added Amount  #2 (Peritoneal Dialysis) */, 227639 /* | Medication Added Amount  #1 (Peritoneal Dialysis) */, 225959 /* | Peritoneal Dialysis Fluid Appearance */, 225951 /* | Medication Added #1 (Peritoneal Dialysis) */, 225952 /* | Medication Added Units #1 (Peritoneal Dialysis) */, 225961, 225953 /* | Solution (Peritoneal Dialysis) */, 225963 /* | Peritoneal Dialysis Catheter Type */, 225965 /* | Peritoneal Dialysis Catheter Status */ /* | Medication Added #2 (Peritoneal Dialysis) */, 227638 /* | Medication Added Units #2 (Peritoneal Dialysis) */, 227640)
      THEN 'Peritoneal'
      WHEN ce.itemid = 226499
      THEN 'IHD'
      ELSE NULL
    END AS dialysis_type
  FROM mimiciv_icu.chartevents AS ce
  WHERE
    ce.itemid IN (226118 /* === MetaVision itemids === -- */ /* Checkboxes */ /* | Dialysis Catheter placed in outside facility */, 227357 /* | Dialysis Catheter Dressing Occlusive */, 225725 /* | Dialysis Catheter Tip Cultured */ /* Numeric values */, 226499 /* | Hemodialysis Output */, 224154 /* | Dialysate Rate */, 225810 /* | Dwell Time (Peritoneal Dialysis) */, 227639 /* | Medication Added Amount  #2 (Peritoneal Dialysis) */, 225183 /* | Current Goal */, 227438 /* | Volume not removed */, 224191 /* | Hourly Patient Fluid Removal */, 225806 /* | Volume In (PD) */, 225807 /* | Volume Out (PD) */, 228004 /* | Citrate (ACD-A) */, 228005 /* | PBP (Prefilter) Replacement Rate */, 228006 /* | Post Filter Replacement Rate */, 224144 /* | Blood Flow (ml/min) */, 224145 /* | Heparin Dose (per hour) */, 224149 /* | Access Pressure */, 224150 /* | Filter Pressure */, 224151 /* | Effluent Pressure */, 224152 /* | Return Pressure */, 224153 /* | Replacement Rate */, 224404 /* | ART Lumen Volume */, 224406 /* | VEN Lumen Volume */, 226457 /* | Ultrafiltrate Output */, 225959 /* | Medication Added Amount  #1 (Peritoneal Dialysis) */ /* Text values */, 224135 /* | Dialysis Access Site */ /* | Dialysis Site Appearance */, 224139, 224146 /* | System Integrity */, 225323 /* | Dialysis Catheter Site Appear */, 225740 /* | Dialysis Catheter Discontinued */, 225776 /* | Dialysis Catheter Dressing Type */, 225951 /* | Peritoneal Dialysis Fluid Appearance */, 225952 /* | Medication Added #1 (Peritoneal Dialysis) */ /* | Solution (Peritoneal Dialysis) */, 225953, 225954 /* | Dialysis Access Type */ /* | Reason for CRRT Filter Change */, 225956 /* | Heparin Concentration (units/mL) */, 225958, 225961 /* | Medication Added Units #1 (Peritoneal Dialysis) */ /* | Peritoneal Dialysis Catheter Type */, 225963 /* | Peritoneal Dialysis Catheter Status */, 225965, 225976 /* | Replacement Fluid */, 225977 /* | Dialysate Fluid */, 227124 /* | Dialysis Catheter Type */, 227290 /* | CRRT mode */, 227638 /* | Medication Added #2 (Peritoneal Dialysis) */, 227640 /* | Medication Added Units #2 (Peritoneal Dialysis) */, 227753 /* | Dialysis Catheter Placement Confirmed by X-ray */)
    AND NOT ce.value IS NULL
), mv_ranges AS (
  SELECT
    stay_id,
    starttime,
    endtime,
    1 AS dialysis_present,
    1 AS dialysis_active,
    'CRRT' AS dialysis_type
  FROM mimiciv_icu.inputevents
  WHERE
    itemid IN (227536 /*	KCl (CRRT)	Medications	inputevents_mv	Solution */ /*	Calcium Gluconate (CRRT)	Medications	inputevents_mv	Solution */, 227525)
    AND amount > 0 /* also ensures it's not null */
  UNION
  SELECT
    stay_id,
    starttime,
    endtime,
    1 AS dialysis_present,
    CASE WHEN NOT itemid IN (224270, 225436) THEN 1 ELSE 0 END AS dialysis_active,
    CASE
      WHEN itemid = 225441
      THEN 'IHD'
      WHEN itemid = 225802
      THEN 'CRRT'
      WHEN itemid = 225803
      THEN 'CVVHD'
      WHEN itemid = 225805
      THEN 'Peritoneal'
      WHEN itemid = 225809
      THEN 'CVVHDF'
      WHEN itemid = 225955
      THEN 'SCUF'
      ELSE NULL
    END AS dialysis_type
  FROM mimiciv_icu.procedureevents
  WHERE
    itemid IN (225441 /* | Hemodialysis */, 225802 /* | Dialysis - CRRT */, 225803 /* | Dialysis - CVVHD */, 225805 /* | Peritoneal Dialysis */, 224270 /* | Dialysis Catheter */, 225809 /* | Dialysis - CVVHDF */, 225955 /* | Dialysis - SCUF */, 225436 /* | CRRT Filter Change */)
    AND NOT value IS NULL
), stg0 AS (
  SELECT
    stay_id,
    charttime,
    dialysis_present,
    dialysis_active,
    dialysis_type
  FROM ce
  WHERE
    dialysis_present = 1
  UNION
  /*   SELECT */ /*     stay_id, charttime, dialysis_present, dialysis_active, dialysis_type */ /*   FROM oe */ /*   WHERE dialysis_present = 1 */ /*   UNION DISTINCT */
  SELECT
    stay_id,
    starttime AS charttime,
    dialysis_present,
    dialysis_active,
    dialysis_type
  FROM mv_ranges
)
SELECT
  stg0.stay_id,
  charttime,
  COALESCE(mv.dialysis_present, stg0.dialysis_present) AS dialysis_present,
  COALESCE(mv.dialysis_active, stg0.dialysis_active) AS dialysis_active,
  COALESCE(mv.dialysis_type, stg0.dialysis_type) AS dialysis_type
FROM stg0
LEFT JOIN mv_ranges AS mv
  ON stg0.stay_id = mv.stay_id
  AND stg0.charttime >= mv.starttime
  AND stg0.charttime <= mv.endtime
),
mc_height AS (
/* prep height */
WITH ht_in AS (
  SELECT
    c.subject_id,
    c.stay_id,
    c.charttime, /* Ensure that all heights are in centimeters */
    ROUND(CAST(c.valuenum * 2.54 AS DECIMAL), 2) AS height,
    c.valuenum AS height_orig
  FROM mimiciv_icu.chartevents AS c
  WHERE
    NOT c.valuenum IS NULL /* Height (measured in inches) */ AND c.itemid = 226707
), ht_cm AS (
  SELECT
    c.subject_id,
    c.stay_id,
    c.charttime, /* Ensure that all heights are in centimeters */
    ROUND(CAST(c.valuenum AS DECIMAL), 2) AS height
  FROM mimiciv_icu.chartevents AS c
  WHERE
    NOT c.valuenum IS NULL /* Height cm */ AND c.itemid = 226730
), ht_stg0 AS (
  SELECT
    COALESCE(h1.subject_id, h1.subject_id) AS subject_id,
    COALESCE(h1.stay_id, h1.stay_id) AS stay_id,
    COALESCE(h1.charttime, h1.charttime) AS charttime,
    COALESCE(h1.height, h2.height) AS height
  FROM ht_cm AS h1
  FULL OUTER JOIN ht_in AS h2
    ON h1.subject_id = h2.subject_id AND h1.charttime = h2.charttime
)
SELECT
  subject_id,
  stay_id,
  charttime,
  height
FROM ht_stg0
WHERE
  NOT height IS NULL /* filter out bad heights */ AND height > 120 AND height < 230
),
mc_age AS (
/* This query calculates the age of a patient on admission to the hospital. */ /* The columns of the table patients: anchor_age, anchor_year, anchor_year_group */ /* provide information regarding the actual patient year for the patient */ /* admission, and the patient's age at that time. */ /* anchor_year is a shifted year for the patient. */ /* anchor_year_group is a range of years - the patient's anchor_year occurred */ /* during this range. */ /* anchor_age is the patient's age in the anchor_year. */ /* Example: a patient has an anchor_year of 2153, */ /* anchor_year_group of 2008 - 2010, and an anchor_age of 60. */ /* The year 2153 for the patient corresponds to 2008, 2009, or 2010. */ /* The patient was 60 in the shifted year of 2153, */ /*  i.e. they were 60 in 2008, 2009, or 2010. */ /* A patient admission in 2154 will occur in 2009-2011, */ /* an admission in 2155 will occur in 2010-2012, and so on. */ /* Therefore, the age of a patient = admission time - anchor_year + anchor_age */
SELECT
  ad.subject_id,
  ad.hadm_id,
  ad.admittime,
  pa.anchor_age,
  pa.anchor_year, /* calculate the age as anchor_age (60) plus difference between */ /* admit year and the anchor year. */ /* the noqa retains the extra long line so the */ /* convert to postgres bash script works */
  pa.anchor_age + EXTRACT(EPOCH FROM ad.admittime - TO_TIMESTAMP(TO_CHAR(pa.anchor_year, '0000') || TO_CHAR(1, '00') || TO_CHAR(1, '00') || TO_CHAR(0, '00') || TO_CHAR(0, '00') || TO_CHAR(0, '00'), 'yyyymmddHH24MISS')) / 31556908.8 AS age /* noqa: L016 */
FROM mimiciv_hosp.admissions AS ad
INNER JOIN mimiciv_hosp.patients AS pa
  ON ad.subject_id = pa.subject_id
),
mc_charlson AS (
/* ------------------------------------------------------------------ */ /* This query extracts Charlson Comorbidity Index (CCI) based on the */ /* recorded ICD-9 and ICD-10 codes. */ /* Reference for CCI: */ /* (1) Charlson ME, Pompei P, Ales KL, MacKenzie CR. (1987) A new method */ /* of classifying prognostic comorbidity in longitudinal studies: */ /* development and validation.J Chronic Dis; 40(5):373-83. */ /* (2) Charlson M, Szatrowski TP, Peterson J, Gold J. (1994) Validation */ /* of a combined comorbidity index. J Clin Epidemiol; 47(11):1245-51. */ /* */ /* Reference for ICD-9-CM and ICD-10 Coding Algorithms for Charlson */ /* Comorbidities: */ /* (3) Quan H, Sundararajan V, Halfon P, et al. Coding algorithms for */ /* defining Comorbidities in ICD-9-CM and ICD-10 administrative data. */ /* Med Care. 2005 Nov; 43(11): 1130-9. */ /* ------------------------------------------------------------------ */
WITH diag AS (
  SELECT
    hadm_id,
    CASE WHEN icd_version = 9 THEN icd_code ELSE NULL END AS icd9_code,
    CASE WHEN icd_version = 10 THEN icd_code ELSE NULL END AS icd10_code
  FROM mimiciv_hosp.diagnoses_icd
), com AS (
  SELECT
    ad.hadm_id, /* Myocardial infarction */
    MAX(
      CASE
        WHEN SUBSTR(icd9_code, 1, 3) IN ('410', '412')
        OR SUBSTR(icd10_code, 1, 3) IN ('I21', 'I22')
        OR SUBSTR(icd10_code, 1, 4) = 'I252'
        THEN 1
        ELSE 0
      END
    ) AS myocardial_infarct, /* Congestive heart failure */
    MAX(
      CASE
        WHEN SUBSTR(icd9_code, 1, 3) = '428'
        OR SUBSTR(icd9_code, 1, 5) IN ('39891', '40201', '40211', '40291', '40401', '40403', '40411', '40413', '40491', '40493')
        OR SUBSTR(icd9_code, 1, 4) BETWEEN '4254' AND '4259'
        OR SUBSTR(icd10_code, 1, 3) IN ('I43', 'I50')
        OR SUBSTR(icd10_code, 1, 4) IN ('I099', 'I110', 'I130', 'I132', 'I255', 'I420', 'I425', 'I426', 'I427', 'I428', 'I429', 'P290')
        THEN 1
        ELSE 0
      END
    ) AS congestive_heart_failure, /* Peripheral vascular disease */
    MAX(
      CASE
        WHEN SUBSTR(icd9_code, 1, 3) IN ('440', '441')
        OR SUBSTR(icd9_code, 1, 4) IN ('0930', '4373', '4471', '5571', '5579', 'V434')
        OR SUBSTR(icd9_code, 1, 4) BETWEEN '4431' AND '4439'
        OR SUBSTR(icd10_code, 1, 3) IN ('I70', 'I71')
        OR SUBSTR(icd10_code, 1, 4) IN ('I731', 'I738', 'I739', 'I771', 'I790', 'I792', 'K551', 'K558', 'K559', 'Z958', 'Z959')
        THEN 1
        ELSE 0
      END
    ) AS peripheral_vascular_disease, /* Cerebrovascular disease */
    MAX(
      CASE
        WHEN SUBSTR(icd9_code, 1, 3) BETWEEN '430' AND '438'
        OR SUBSTR(icd9_code, 1, 5) = '36234'
        OR SUBSTR(icd10_code, 1, 3) IN ('G45', 'G46')
        OR SUBSTR(icd10_code, 1, 3) BETWEEN 'I60' AND 'I69'
        OR SUBSTR(icd10_code, 1, 4) = 'H340'
        THEN 1
        ELSE 0
      END
    ) AS cerebrovascular_disease, /* Dementia */
    MAX(
      CASE
        WHEN SUBSTR(icd9_code, 1, 3) = '290'
        OR SUBSTR(icd9_code, 1, 4) IN ('2941', '3312')
        OR SUBSTR(icd10_code, 1, 3) IN ('F00', 'F01', 'F02', 'F03', 'G30')
        OR SUBSTR(icd10_code, 1, 4) IN ('F051', 'G311')
        THEN 1
        ELSE 0
      END
    ) AS dementia, /* Chronic pulmonary disease */
    MAX(
      CASE
        WHEN SUBSTR(icd9_code, 1, 3) BETWEEN '490' AND '505'
        OR SUBSTR(icd9_code, 1, 4) IN ('4168', '4169', '5064', '5081', '5088')
        OR SUBSTR(icd10_code, 1, 3) BETWEEN 'J40' AND 'J47'
        OR SUBSTR(icd10_code, 1, 3) BETWEEN 'J60' AND 'J67'
        OR SUBSTR(icd10_code, 1, 4) IN ('I278', 'I279', 'J684', 'J701', 'J703')
        THEN 1
        ELSE 0
      END
    ) AS chronic_pulmonary_disease, /* Rheumatic disease */
    MAX(
      CASE
        WHEN SUBSTR(icd9_code, 1, 3) = '725'
        OR SUBSTR(icd9_code, 1, 4) IN ('4465', '7100', '7101', '7102', '7103', '7104', '7140', '7141', '7142', '7148')
        OR SUBSTR(icd10_code, 1, 3) IN ('M05', 'M06', 'M32', 'M33', 'M34')
        OR SUBSTR(icd10_code, 1, 4) IN ('M315', 'M351', 'M353', 'M360')
        THEN 1
        ELSE 0
      END
    ) AS rheumatic_disease, /* Peptic ulcer disease */
    MAX(
      CASE
        WHEN SUBSTR(icd9_code, 1, 3) IN ('531', '532', '533', '534')
        OR SUBSTR(icd10_code, 1, 3) IN ('K25', 'K26', 'K27', 'K28')
        THEN 1
        ELSE 0
      END
    ) AS peptic_ulcer_disease, /* Mild liver disease */
    MAX(
      CASE
        WHEN SUBSTR(icd9_code, 1, 3) IN ('570', '571')
        OR SUBSTR(icd9_code, 1, 4) IN ('0706', '0709', '5733', '5734', '5738', '5739', 'V427')
        OR SUBSTR(icd9_code, 1, 5) IN ('07022', '07023', '07032', '07033', '07044', '07054')
        OR SUBSTR(icd10_code, 1, 3) IN ('B18', 'K73', 'K74')
        OR SUBSTR(icd10_code, 1, 4) IN ('K700', 'K701', 'K702', 'K703', 'K709', 'K713', 'K714', 'K715', 'K717', 'K760', 'K762', 'K763', 'K764', 'K768', 'K769', 'Z944')
        THEN 1
        ELSE 0
      END
    ) AS mild_liver_disease, /* Diabetes without chronic complication */
    MAX(
      CASE
        WHEN SUBSTR(icd9_code, 1, 4) IN ('2500', '2501', '2502', '2503', '2508', '2509')
        OR SUBSTR(icd10_code, 1, 4) IN ('E100', 'E101', 'E106', 'E108', 'E109', 'E110', 'E111', 'E116', 'E118', 'E119', 'E120', 'E121', 'E126', 'E128', 'E129', 'E130', 'E131', 'E136', 'E138', 'E139', 'E140', 'E141', 'E146', 'E148', 'E149')
        THEN 1
        ELSE 0
      END
    ) AS diabetes_without_cc, /* Diabetes with chronic complication */
    MAX(
      CASE
        WHEN SUBSTR(icd9_code, 1, 4) IN ('2504', '2505', '2506', '2507')
        OR SUBSTR(icd10_code, 1, 4) IN ('E102', 'E103', 'E104', 'E105', 'E107', 'E112', 'E113', 'E114', 'E115', 'E117', 'E122', 'E123', 'E124', 'E125', 'E127', 'E132', 'E133', 'E134', 'E135', 'E137', 'E142', 'E143', 'E144', 'E145', 'E147')
        THEN 1
        ELSE 0
      END
    ) AS diabetes_with_cc, /* Hemiplegia or paraplegia */
    MAX(
      CASE
        WHEN SUBSTR(icd9_code, 1, 3) IN ('342', '343')
        OR SUBSTR(icd9_code, 1, 4) IN ('3341', '3440', '3441', '3442', '3443', '3444', '3445', '3446', '3449')
        OR SUBSTR(icd10_code, 1, 3) IN ('G81', 'G82')
        OR SUBSTR(icd10_code, 1, 4) IN ('G041', 'G114', 'G801', 'G802', 'G830', 'G831', 'G832', 'G833', 'G834', 'G839')
        THEN 1
        ELSE 0
      END
    ) AS paraplegia, /* Renal disease */
    MAX(
      CASE
        WHEN SUBSTR(icd9_code, 1, 3) IN ('582', '585', '586', 'V56')
        OR SUBSTR(icd9_code, 1, 4) IN ('5880', 'V420', 'V451')
        OR SUBSTR(icd9_code, 1, 4) BETWEEN '5830' AND '5837'
        OR SUBSTR(icd9_code, 1, 5) IN ('40301', '40311', '40391', '40402', '40403', '40412', '40413', '40492', '40493')
        OR SUBSTR(icd10_code, 1, 3) IN ('N18', 'N19')
        OR SUBSTR(icd10_code, 1, 4) IN ('I120', 'I131', 'N032', 'N033', 'N034', 'N035', 'N036', 'N037', 'N052', 'N053', 'N054', 'N055', 'N056', 'N057', 'N250', 'Z490', 'Z491', 'Z492', 'Z940', 'Z992')
        THEN 1
        ELSE 0
      END
    ) AS renal_disease, /* Any malignancy, including lymphoma and leukemia, */ /* except malignant neoplasm of skin. */
    MAX(
      CASE
        WHEN SUBSTR(icd9_code, 1, 3) BETWEEN '140' AND '172'
        OR SUBSTR(icd9_code, 1, 4) BETWEEN '1740' AND '1958'
        OR SUBSTR(icd9_code, 1, 3) BETWEEN '200' AND '208'
        OR SUBSTR(icd9_code, 1, 4) = '2386'
        OR SUBSTR(icd10_code, 1, 3) IN ('C43', 'C88')
        OR SUBSTR(icd10_code, 1, 3) BETWEEN 'C00' AND 'C26'
        OR SUBSTR(icd10_code, 1, 3) BETWEEN 'C30' AND 'C34'
        OR SUBSTR(icd10_code, 1, 3) BETWEEN 'C37' AND 'C41'
        OR SUBSTR(icd10_code, 1, 3) BETWEEN 'C45' AND 'C58'
        OR SUBSTR(icd10_code, 1, 3) BETWEEN 'C60' AND 'C76'
        OR SUBSTR(icd10_code, 1, 3) BETWEEN 'C81' AND 'C85'
        OR SUBSTR(icd10_code, 1, 3) BETWEEN 'C90' AND 'C97'
        THEN 1
        ELSE 0
      END
    ) AS malignant_cancer, /* Moderate or severe liver disease */
    MAX(
      CASE
        WHEN SUBSTR(icd9_code, 1, 4) IN ('4560', '4561', '4562')
        OR SUBSTR(icd9_code, 1, 4) BETWEEN '5722' AND '5728'
        OR SUBSTR(icd10_code, 1, 4) IN ('I850', 'I859', 'I864', 'I982', 'K704', 'K711', 'K721', 'K729', 'K765', 'K766', 'K767')
        THEN 1
        ELSE 0
      END
    ) AS severe_liver_disease, /* Metastatic solid tumor */
    MAX(
      CASE
        WHEN SUBSTR(icd9_code, 1, 3) IN ('196', '197', '198', '199')
        OR SUBSTR(icd10_code, 1, 3) IN ('C77', 'C78', 'C79', 'C80')
        THEN 1
        ELSE 0
      END
    ) AS metastatic_solid_tumor, /* AIDS/HIV */
    MAX(
      CASE
        WHEN SUBSTR(icd9_code, 1, 3) IN ('042', '043', '044')
        OR SUBSTR(icd10_code, 1, 3) IN ('B20', 'B21', 'B22', 'B24')
        THEN 1
        ELSE 0
      END
    ) AS aids
  FROM mimiciv_hosp.admissions AS ad
  LEFT JOIN diag
    ON ad.hadm_id = diag.hadm_id
  GROUP BY
    ad.hadm_id
), ag AS (
  SELECT
    hadm_id,
    age,
    CASE
      WHEN age <= 50
      THEN 0
      WHEN age <= 60
      THEN 1
      WHEN age <= 70
      THEN 2
      WHEN age <= 80
      THEN 3
      ELSE 4
    END AS age_score
  FROM mc_age
)
SELECT
  ad.subject_id,
  ad.hadm_id,
  ag.age_score,
  myocardial_infarct,
  congestive_heart_failure,
  peripheral_vascular_disease,
  cerebrovascular_disease,
  dementia,
  chronic_pulmonary_disease,
  rheumatic_disease,
  peptic_ulcer_disease,
  mild_liver_disease,
  diabetes_without_cc,
  diabetes_with_cc,
  paraplegia,
  renal_disease,
  malignant_cancer,
  severe_liver_disease,
  metastatic_solid_tumor,
  aids, /* Calculate the Charlson Comorbidity Score using the original */ /* weights from Charlson, 1987. */
  age_score + myocardial_infarct + congestive_heart_failure + peripheral_vascular_disease + cerebrovascular_disease + dementia + chronic_pulmonary_disease + rheumatic_disease + peptic_ulcer_disease + GREATEST(mild_liver_disease, 3 * severe_liver_disease) + GREATEST(2 * diabetes_with_cc, diabetes_without_cc) + GREATEST(2 * malignant_cancer, 6 * metastatic_solid_tumor) + 2 * paraplegia + 2 * renal_disease + 6 * aids AS charlson_comorbidity_index
FROM mimiciv_hosp.admissions AS ad
LEFT JOIN com
  ON ad.hadm_id = com.hadm_id
LEFT JOIN ag
  ON com.hadm_id = ag.hadm_id
),

base AS (
 SELECT i.*,p.gender,p.anchor_age + EXTRACT(YEAR FROM i.intime)::integer-p.anchor_year AS age,
 a.admittime,a.dischtime,a.deathtime,a.hospital_expire_flag AS inhospital_mortality,a.admission_location,
 ROW_NUMBER() OVER(PARTITION BY i.subject_id ORDER BY i.intime,i.stay_id) AS first_icu_rn
 FROM mimiciv_icu.icustays i JOIN mimiciv_hosp.patients p USING(subject_id)
 JOIN mimiciv_hosp.admissions a USING(subject_id,hadm_id)
),
sepsis_events AS (
 SELECT b.stay_id, MIN(s.suspected_infection_time) AS suspected_infection_time,
 MIN(f.endtime) AS sofa_time, MAX(f.sofa_24hours) AS sepsis_sofa_max,
 COUNT(*) FILTER(WHERE s.antibiotic_time>b.intime+INTERVAL '24 hours'
 OR s.culture_time>b.intime+INTERVAL '24 hours') AS retrospective_confirmation_n
 FROM base b JOIN mc_suspicion_of_infection s ON b.stay_id=s.stay_id AND s.suspected_infection=1
 JOIN mc_sofa f ON b.stay_id=f.stay_id AND f.sofa_24hours>=2
 AND f.endtime>=s.suspected_infection_time-INTERVAL '48 hours'
 AND f.endtime<=s.suspected_infection_time+INTERVAL '24 hours'
 WHERE s.suspected_infection_time>=b.intime AND s.suspected_infection_time<b.intime+INTERVAL '24 hours'
 AND f.endtime>=b.intime AND f.endtime<=b.intime+INTERVAL '24 hours'
 GROUP BY b.stay_id
),
cohort AS (
 SELECT 'mimic'::text AS data_source,b.subject_id::text AS subject_id,b.hadm_id::bigint AS hadm_id,b.stay_id::bigint AS stay_id,b.gender,b.age,
 b.intime,b.outtime,b.admittime,b.dischtime,b.deathtime,b.admission_location,
 b.inhospital_mortality,b.first_icu_rn,s.suspected_infection_time,s.sofa_time,s.sepsis_sofa_max,
 s.retrospective_confirmation_n,
 (b.first_icu_rn=1 AND b.age>=18 AND s.stay_id IS NOT NULL) AS eligible_pre_landmark,
 (b.first_icu_rn=1 AND b.age>=18 AND s.stay_id IS NOT NULL
 AND b.inhospital_mortality IN(0,1) AND b.admittime<=b.intime
 AND b.outtime>=b.intime+INTERVAL '24 hours' AND b.dischtime>=b.intime+INTERVAL '24 hours'
 AND (b.deathtime IS NULL OR b.deathtime>b.intime+INTERVAL '24 hours')) AS eligible_24h,
 EXTRACT(EPOCH FROM(b.dischtime-b.admittime))/86400.0 AS hospital_los_days,
 EXTRACT(EPOCH FROM(b.outtime-b.intime))/86400.0 AS icu_los_days
 FROM base b LEFT JOIN sepsis_events s USING(stay_id)
),

gcs_observed AS (
 SELECT b.stay_id,c.charttime,
 MAX(c.valuenum) FILTER(WHERE c.itemid=220739 AND c.valuenum BETWEEN 1 AND 4) AS eyes,
 MAX(c.valuenum) FILTER(WHERE c.itemid=223900 AND c.valuenum BETWEEN 1 AND 5 AND COALESCE(c.value,'')<>'No Response-ETT') AS verbal,
 MAX(c.valuenum) FILTER(WHERE c.itemid=223901 AND c.valuenum BETWEEN 1 AND 6) AS motor
 FROM cohort b JOIN mimiciv_icu.chartevents c USING(stay_id)
 WHERE c.itemid IN(220739,223900,223901) AND c.charttime>=b.intime AND c.charttime<b.intime+INTERVAL '24 hours'
 AND(c.storetime IS NULL OR c.storetime<=b.intime+INTERVAL '24 hours') GROUP BY b.stay_id,c.charttime
),
measurements AS (
 SELECT b.stay_id,EXTRACT(EPOCH FROM(v.charttime-b.intime))/60.0 AS minute,
 CASE WHEN v.itemid=220045 THEN 'heart_rate' ELSE 'map' END AS variable,v.valuenum AS value
 FROM cohort b JOIN mimiciv_icu.chartevents v USING(stay_id)
 WHERE v.itemid IN(220045,220052,220181,225312) AND v.valuenum>0 AND v.valuenum<300
 AND v.charttime>=b.intime AND v.charttime<b.intime+INTERVAL '24 hours'
 AND(v.storetime IS NULL OR v.storetime<=b.intime+INTERVAL '24 hours')
 UNION ALL
 SELECT b.stay_id,EXTRACT(EPOCH FROM(l.charttime-b.intime))/60.0,
 CASE l.itemid WHEN 50813 THEN 'lactate' WHEN 50912 THEN 'creatinine' WHEN 50931 THEN 'glucose'
 WHEN 51237 THEN 'inr' WHEN 51265 THEN 'platelets' WHEN 50885 THEN 'bilirubin' END,l.valuenum
 FROM cohort b JOIN mimiciv_hosp.labevents l ON b.hadm_id=l.hadm_id
 WHERE l.itemid IN(50813,50912,50931,51237,51265,50885) AND l.valuenum>=0
 AND l.charttime>=b.intime AND l.charttime<b.intime+INTERVAL '24 hours' AND (l.storetime IS NULL OR l.storetime<=b.intime+INTERVAL '24 hours')
 UNION ALL
 SELECT b.stay_id,EXTRACT(EPOCH FROM(g.charttime-b.intime))/60.0,'gcs',g.eyes+g.verbal+g.motor
 FROM cohort b JOIN gcs_observed g USING(stay_id)
 WHERE g.eyes IS NOT NULL AND g.verbal IS NOT NULL AND g.motor IS NOT NULL
 UNION ALL
 SELECT b.stay_id,EXTRACT(EPOCH FROM(u.charttime-b.intime))/60.0,'urine_output',
 SUM(CASE WHEN u.itemid=227488 AND u.value>0 THEN -u.value ELSE u.value END)
 FROM cohort b JOIN mimiciv_icu.outputevents u USING(stay_id)
 WHERE u.itemid IN(226559,226560,226561,226584,226563,226564,226565,226567,226557,226558,227488,227489)
 AND u.charttime>=b.intime AND u.charttime<b.intime+INTERVAL '24 hours'
 AND(u.storetime IS NULL OR u.storetime<=b.intime+INTERVAL '24 hours') GROUP BY b.stay_id,b.intime,u.charttime
),
pf AS (
 SELECT b.stay_id,MIN(g.pao2fio2ratio) FILTER(WHERE EXISTS(
 SELECT 1 FROM mc_ventilation v WHERE v.stay_id=b.stay_id AND v.ventilation_status='InvasiveVent'
 AND g.charttime>=v.starttime AND g.charttime<v.endtime)) AS pf_supported_min,
 MIN(g.pao2fio2ratio) FILTER(WHERE NOT EXISTS(
 SELECT 1 FROM mc_ventilation v WHERE v.stay_id=b.stay_id AND v.ventilation_status='InvasiveVent'
 AND g.charttime>=v.starttime AND g.charttime<v.endtime)) AS pf_unsupported_min
 FROM cohort b JOIN mc_bg g ON g.hadm_id=b.hadm_id AND g.specimen='ART.'
 WHERE g.charttime>=b.intime AND g.charttime<b.intime+INTERVAL '24 hours' AND g.pao2fio2ratio>0 AND(g.storetime IS NULL OR g.storetime<=b.intime+INTERVAL '24 hours')
 GROUP BY b.stay_id
),
vaso_intervals AS (
 SELECT b.stay_id,x.drug,EXTRACT(EPOCH FROM(GREATEST(x.starttime,b.intime)-b.intime))/60.0 AS start_min,
 EXTRACT(EPOCH FROM(LEAST(x.endtime,b.intime+INTERVAL '24 hours')-b.intime))/60.0 AS end_min,
 x.rate::double precision AS rate, TRUE AS duration_recorded
 FROM cohort b JOIN (
 SELECT stay_id,'dopamine' AS drug,starttime,endtime,vaso_rate AS rate FROM mc_dopamine
 UNION ALL SELECT stay_id,'dobutamine',starttime,endtime,vaso_rate FROM mc_dobutamine
 UNION ALL SELECT stay_id,'epinephrine',starttime,endtime,vaso_rate FROM mc_epinephrine
 UNION ALL SELECT stay_id,'norepinephrine',starttime,endtime,vaso_rate FROM mc_norepinephrine
 )x USING(stay_id)
 WHERE x.starttime<b.intime+INTERVAL '24 hours' AND x.endtime>b.intime AND x.rate>0 AND EXISTS(SELECT 1 FROM mimiciv_icu.inputevents raw WHERE raw.stay_id=x.stay_id AND raw.starttime=x.starttime AND raw.endtime=x.endtime
 AND raw.itemid=CASE x.drug WHEN 'dopamine' THEN 221662 WHEN 'dobutamine' THEN 221653 WHEN 'epinephrine' THEN 221289 WHEN 'norepinephrine' THEN 221906 END
 AND COALESCE(raw.statusdescription,'')<>'Rewritten' AND(raw.storetime IS NULL OR raw.storetime<=b.intime+INTERVAL '24 hours'))
),
treatments AS (
 SELECT b.stay_id,
 EXISTS(SELECT 1 FROM mc_ventilation v WHERE v.stay_id=b.stay_id AND v.ventilation_status='InvasiveVent'
 AND v.starttime<b.intime+INTERVAL '24 hours' AND v.endtime>b.intime)::integer AS mechanical_ventilation_24h,
 EXISTS(SELECT 1 FROM mimiciv_icu.inputevents v WHERE v.stay_id=b.stay_id AND v.itemid IN(221906,221289,221662,221749,222315)
 AND v.starttime<b.intime+INTERVAL '24 hours' AND v.endtime>b.intime AND v.rate>0
 AND COALESCE(v.statusdescription,'')<>'Rewritten' AND(v.storetime IS NULL OR v.storetime<=b.intime+INTERVAL '24 hours'))::integer AS vasopressor_24h,
 EXISTS(SELECT 1 FROM mc_rrt r WHERE r.stay_id=b.stay_id AND r.dialysis_active=1
 AND r.charttime>=b.intime AND r.charttime<b.intime+INTERVAL '24 hours')::integer AS rrt_24h,
 EXISTS(SELECT 1 FROM mc_antibiotic a WHERE a.hadm_id=b.hadm_id
 AND a.starttime<b.intime+INTERVAL '24 hours' AND COALESCE(a.stoptime,a.starttime)>=b.intime)::integer AS antibiotic_24h,
 (SELECT SUM(v.amount*CASE WHEN v.endtime>v.starttime THEN
 EXTRACT(EPOCH FROM(LEAST(v.endtime,b.intime+INTERVAL '24 hours')-GREATEST(v.starttime,b.intime)))
 /EXTRACT(EPOCH FROM(v.endtime-v.starttime)) ELSE 1 END)
 FROM mimiciv_icu.inputevents v JOIN mimiciv_icu.d_items di ON v.itemid=di.itemid
 WHERE v.stay_id=b.stay_id AND LOWER(v.amountuom)='ml' AND v.amount>=0
 AND LOWER(di.label) IN('normal saline','lactated ringers','plasmalyte','albumin 5%','albumin 25%')
 AND COALESCE(v.statusdescription,'')<>'Rewritten' AND(v.storetime IS NULL OR v.storetime<=b.intime+INTERVAL '24 hours')
 AND ((v.endtime>v.starttime AND v.starttime<b.intime+INTERVAL '24 hours' AND v.endtime>b.intime)
 OR(v.endtime=v.starttime AND v.starttime>=b.intime AND v.starttime<b.intime+INTERVAL '24 hours'))
 ) AS fluid_resuscitation_24h_ml
 FROM cohort b
),
body AS (
 SELECT b.stay_id,
 (SELECT c.valuenum FROM mimiciv_icu.chartevents c WHERE c.stay_id=b.stay_id AND c.itemid IN(226512,224639)
 AND c.valuenum>0 AND(c.storetime IS NULL OR c.storetime<=b.intime+INTERVAL '24 hours') AND c.charttime>=b.intime AND c.charttime<b.intime+INTERVAL '24 hours'
 ORDER BY CASE WHEN c.itemid=226512 THEN 0 ELSE 1 END,c.charttime,c.itemid LIMIT 1) AS weight_kg,
 (SELECT CASE WHEN h.itemid=226707 THEN h.valuenum*2.54 ELSE h.valuenum END
 FROM mimiciv_icu.chartevents h WHERE h.stay_id=b.stay_id AND h.itemid IN(226707,226730)
 AND h.charttime>=b.intime AND h.charttime<b.intime+INTERVAL '24 hours' AND(h.storetime IS NULL OR h.storetime<=b.intime+INTERVAL '24 hours')
 AND CASE WHEN h.itemid=226707 THEN h.valuenum*2.54 ELSE h.valuenum END BETWEEN 120 AND 230
 ORDER BY h.charttime,h.itemid DESC LIMIT 1) AS height_cm
 FROM cohort b
),
cci_history_flags AS (
 SELECT b.stay_id,COUNT(DISTINCT old.hadm_id) AS prior_admissions_n,
MAX(c.myocardial_infarct) AS myocardial_infarct,
MAX(c.congestive_heart_failure) AS congestive_heart_failure,
MAX(c.peripheral_vascular_disease) AS peripheral_vascular_disease,
MAX(c.cerebrovascular_disease) AS cerebrovascular_disease,
MAX(c.dementia) AS dementia,
MAX(c.chronic_pulmonary_disease) AS chronic_pulmonary_disease,
MAX(c.rheumatic_disease) AS rheumatic_disease,
MAX(c.peptic_ulcer_disease) AS peptic_ulcer_disease,
MAX(c.mild_liver_disease) AS mild_liver_disease,
MAX(c.diabetes_without_cc) AS diabetes_without_cc,
MAX(c.diabetes_with_cc) AS diabetes_with_cc,
MAX(c.paraplegia) AS paraplegia,
MAX(c.renal_disease) AS renal_disease,
MAX(c.malignant_cancer) AS malignant_cancer,
MAX(c.severe_liver_disease) AS severe_liver_disease,
MAX(c.metastatic_solid_tumor) AS metastatic_solid_tumor,
MAX(c.aids) AS aids
 FROM cohort b LEFT JOIN mimiciv_hosp.admissions old ON old.subject_id=b.subject_id::integer AND old.dischtime<b.intime
 LEFT JOIN mc_charlson c ON old.hadm_id=c.hadm_id GROUP BY b.stay_id
),
cci AS (
 SELECT h.stay_id,CASE WHEN h.prior_admissions_n>0 THEN
 h.myocardial_infarct+h.congestive_heart_failure+h.peripheral_vascular_disease+h.cerebrovascular_disease+h.dementia+h.chronic_pulmonary_disease+h.rheumatic_disease+h.peptic_ulcer_disease+
 GREATEST(h.mild_liver_disease,3*h.severe_liver_disease)+GREATEST(h.diabetes_without_cc,2*h.diabetes_with_cc)+2*h.paraplegia+2*h.renal_disease+GREATEST(2*h.malignant_cancer,6*h.metastatic_solid_tumor)+6*h.aids END AS charlson_comorbidity_index,
 FALSE AS cci_index_discharge_codes_used,h.prior_admissions_n,
 c.charlson_comorbidity_index-c.age_score AS cci_index_discharge_candidate
 FROM cci_history_flags h JOIN cohort b USING(stay_id) LEFT JOIN mc_charlson c USING(hadm_id)
),
site_candidates AS (
 SELECT b.stay_id,STRING_AGG(DISTINCT LOWER(di.long_title),' | ') AS diagnosis_text
 FROM cohort b JOIN mimiciv_hosp.diagnoses_icd d USING(hadm_id)
 JOIN mimiciv_hosp.d_icd_diagnoses di USING(icd_code,icd_version)
 GROUP BY b.stay_id
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
