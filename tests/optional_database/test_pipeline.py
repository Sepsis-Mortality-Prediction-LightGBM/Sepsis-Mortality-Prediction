# OPTIONAL DATABASE TEST — NOT RUN IN THE OFFLINE TASK.
"""Meaningful synthetic tests; no clinical data or original patient IDs.
Run: python -m unittest discover -s tests -v
DuckDB is only a local test engine. PostgreSQL pglast parses the actual shipping SQL.
The numeric TO_CHAR/TO_TIMESTAMP bridge is used solely for the official Charlson age dependency.
"""
from pathlib import Path
import unittest,sys,tempfile,json
import duckdb,pandas as pd
from pglast import parse_sql
ROOT=Path(__file__).resolve().parents[2];sys.path.insert(0,str(ROOT/'scripts'))
import reconcile as rec

def db():
 c=duckdb.connect()
 for sc in ['mimiciv_hosp','mimiciv_icu','mimiciv_derived','eicu_crd']:c.execute('CREATE SCHEMA '+sc)
 c.execute((ROOT/'tests/mimic_schema.sql').read_text());c.execute("SET schema='eicu_crd'");c.execute((ROOT/'tests/eicu_schema.sql').read_text());c.execute("SET schema='main'")
 c.execute("CREATE MACRO to_char(x,y) AS lpad(CAST(x AS VARCHAR),CAST(length(y) AS INTEGER),'0')")
 c.execute("CREATE MACRO to_timestamp(x,y) AS strptime(x,'%Y%m%d%H%M%S')")
 return c

class SQLTests(unittest.TestCase):
 def test_all_shipping_queries_parse_and_bind_official_schemas(self):
  c=db()
  for f in sorted((ROOT/'sql').glob('*.sql')):
   with self.subTest(file=f.name):
    parsed=parse_sql(f.read_text());self.assertEqual(len(parsed),1)
    self.assertEqual(c.execute(f.read_text()).fetchall(),[])
  c.close()
 def test_eicu_first_icu_uses_offsets_not_native_id_order(self):
  c=db();c.execute("INSERT INTO eicu_crd.patient(patientunitstayid,patienthealthsystemstayid,uniquepid,age,gender,hospitaladmitoffset,unitvisitnumber,unitdischargeoffset,hospitaldischargeoffset,hospitaldischargestatus) VALUES(20,100,'SYNTHETIC','60','Female',-60,1,3000,6000,'Alive'),(10,100,'SYNTHETIC','60','Female',-300,2,3000,6000,'Alive')")
  c.execute("INSERT INTO eicu_crd.diagnosis(diagnosisid,patientunitstayid,diagnosisoffset,diagnosisstring,diagnosispriority,activeupondischarge) VALUES(1,20,10,'sepsis','Primary',false),(2,10,10,'sepsis','Primary',false)")
  result=c.execute((ROOT/'sql/02_eicu_cohort.sql').read_text()).fetchdf().set_index('stay_id')
  self.assertTrue(bool(result.loc[20,'eligible_24h']));self.assertFalse(bool(result.loc[10,'eligible_24h']));c.close()

class SOFATests(unittest.TestCase):
 def score(self,**updates):
  defaults={'pf_supported_min':450.,'pf_unsupported_min':None,'platelets_min':200.,'bilirubin_max':.8,'creatinine_max':.8,'map_min':75.,'gcs_min':15.,'urine_24h_coverage_proxy_ml':2400.,'cv_drug_score':None,'vaso_dose_or_duration_unresolved':False}
  defaults.update(updates);df=pd.DataFrame([defaults]);c=duckdb.connect();c.register('sofa_inputs',df)
  fragment=(ROOT/'shared_summary_sofa.sql.inc').read_text().split('sofa_components AS (',1)[1]
  result=c.execute('WITH sofa_components AS ('+fragment+' SELECT * FROM sofa_scored').fetchdf().iloc[0];c.close();return result
 def test_respiratory_support_interaction(self):
  for args,expected in [({'pf_supported_min':None,'pf_unsupported_min':70},2),({'pf_supported_min':150,'pf_unsupported_min':70},3),({'pf_supported_min':299},2),({'pf_supported_min':99},4),({'pf_supported_min':400},0)]:
   with self.subTest(args=args):self.assertEqual(self.score(**args).sofa_respiration_24h_new,expected)
 def test_platelet_threshold_boundaries(self):
  for value,expected in [(19,4),(20,3),(49,3),(50,2),(99,2),(100,1),(149,1),(150,0)]:
   with self.subTest(value=value):self.assertEqual(self.score(platelets_min=value).sofa_coagulation_24h_new,expected)
 def test_bilirubin_thresholds(self):
  for value,expected in [(1.19,0),(1.2,1),(2,2),(6,3),(12,4)]:self.assertEqual(self.score(bilirubin_max=value).sofa_liver_24h_new,expected)
 def test_gcs_thresholds(self):
  for value,expected in [(3,4),(6,3),(9,3),(10,2),(12,2),(13,1),(14,1),(15,0)]:self.assertEqual(self.score(gcs_min=value).sofa_cns_24h,expected)
 def test_renal_uses_total_not_event_mean(self):
  self.assertEqual(self.score(urine_24h_coverage_proxy_ml=2400).sofa_renal_24h_new,0)
  self.assertEqual(self.score(urine_24h_coverage_proxy_ml=199).sofa_renal_24h_new,4)
  self.assertEqual(self.score(urine_24h_coverage_proxy_ml=200).sofa_renal_24h_new,3)
  self.assertEqual(self.score(urine_24h_coverage_proxy_ml=500).sofa_renal_24h_new,0)
  for value,expected in [(1.2,1),(2,2),(3.5,3),(5,4)]:self.assertEqual(self.score(creatinine_max=value).sofa_renal_24h_new,expected)
 def test_missing_is_not_silently_normal(self):
  r=self.score(pf_supported_min=None,pf_unsupported_min=None)
  self.assertTrue(pd.isna(r.sofa_component_sum));self.assertEqual(r.sofa_missing_components_n,1);self.assertEqual(r.sofa_missing0_sensitivity,0)
 def test_unresolved_vasopressor_duration_is_missing(self):
  self.assertTrue(pd.isna(self.score(vaso_dose_or_duration_unresolved=True).sofa_cardiovascular_24h_new))
 def test_adjacent_vasopressor_intervals_merge_without_double_count(self):
  # Two 30-min documented norepinephrine periods make one hour; a 1-min gap does not.
  fragment=(ROOT/'shared_summary_sofa.sql.inc').read_text().split('vaso_levels AS (',1)[1].split(',\nsofa_inputs AS (',1)[0]
  for intervals,expected in [([(0,30),(30,60)],3),([(0,30),(31,61)],None),([(0,40),(20,50)],None)]:
   with self.subTest(intervals=intervals):
    c=duckdb.connect();df=pd.DataFrame([{'stay_id':1,'drug':'norepinephrine','start_min':a,'end_min':b,'rate':.1,'duration_recorded':True} for a,b in intervals]);c.register('vaso_intervals',df);c.execute('CREATE TABLE cohort AS SELECT 1 AS stay_id')
    actual=c.execute('WITH vaso_levels AS ('+fragment+' SELECT cv_drug_score FROM vaso').fetchone()[0];self.assertEqual(actual,expected);c.close()

class ReconciliationTests(unittest.TestCase):
 def frames(self):
  old=pd.DataFrame([{**{k:1. for k in rec.NUM if k!='sofa_component_sum'},**{k:0 for k in rec.COMP},'stay_id':1001,'subject_id':2001,'hadm_id':3001,'gender':'F','admission_location':'EMERGENCY ROOM','infection_source':'respiratory','inhospital_mortality':0,'internal_split':'development_80'}]);new=rec.original(old);new['eligible_24h']=True;return old,new
 def check(self,change,expected=False):
  old,new=self.frames();old,new=change(old,new)
  with tempfile.TemporaryDirectory() as tmp:self.assertEqual(rec.compare(old,new,Path(tmp),'synthetic'),expected)
 def test_identical_reconciles(self):self.check(lambda a,b:(a,b),True)
 def test_mortality_flip_detected(self):self.check(lambda a,b:(a,b.assign(inhospital_mortality=1)))
 def test_missing_value_change_detected(self):self.check(lambda a,b:(a,b.assign(lactate_24h_mean=float('nan'))))
 def test_value_change_detected(self):self.check(lambda a,b:(a,b.assign(map_24h_mean=75)))
 def test_sofa_component_change_detected(self):self.check(lambda a,b:(a,b.assign(sofa_renal_24h_new=4)))
 def test_missing_id_detected(self):self.check(lambda a,b:(a,b.iloc[0:0]))
 def test_extra_id_detected(self):self.check(lambda a,b:(a,pd.concat([b,b.assign(stay_id='1002')],ignore_index=True)))
 def test_duplicate_id_stops_comparison(self):self.check(lambda a,b:(a,pd.concat([b,b],ignore_index=True)))
 def test_landmark_failure_detected(self):self.check(lambda a,b:(a,b.assign(eligible_24h=False)))
 def test_person_id_change_detected(self):self.check(lambda a,b:(a,b.assign(subject_id=9999)))
if __name__=='__main__':unittest.main()
