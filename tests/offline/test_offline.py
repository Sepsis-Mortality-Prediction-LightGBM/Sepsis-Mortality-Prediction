from pathlib import Path
import unittest,sys,tempfile,json
import pandas as pd,numpy as np
from pglast import ast,parse_sql
from pglast.stream import RawStream
ROOT=Path(__file__).resolve().parents[2];sys.path.insert(0,str(ROOT/'scripts'))
import reconcile as rec
import validate_extraction as val
from static_sql_audit import Audit
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

class DistributionTests(unittest.TestCase):
 def test_identical_distribution_KS_zero(self):self.assertEqual(val.ks_statistic([1,2,3],[3,2,1]),0)
 def test_shift_detected(self):self.assertEqual(val.ks_statistic([1,2,3],[4,5,6]),1)
 def test_empty_distribution_is_unavailable(self):self.assertIsNone(val.ks_statistic([],[]))
 def test_missing_rate_change_detected(self):
  a,b=ReconciliationTests().frames();a=rec.original(a);b['lactate_24h_mean']=np.nan
  num,cat,missing=val.distribution_compare(a,b);row=next(x for x in missing if x['field']=='lactate_24h_mean');self.assertEqual(row['difference_percentage_points'],100)
 def test_different_sample_sizes_reported(self):
  a,b=ReconciliationTests().frames();b=pd.concat([b,b.assign(stay_id='1002')],ignore_index=True)
  with tempfile.TemporaryDirectory() as tmp:
   report=val.validate(a,b,None,'mimic',Path(tmp));sample=pd.read_csv(Path(tmp)/'sample_size_comparison.csv');self.assertEqual(int(sample.iloc[0].n_difference),1);self.assertFalse(report['exact_row_comparison_passed'])
 def test_reference_profile_contains_no_identifiers(self):
  a,b=ReconciliationTests().frames();profile=val.profile(rec.original(a));text=json.dumps(profile);self.assertNotIn('stay_id',text);self.assertNotIn('subject_id',text)
 def test_screening_sequence_counts(self):
  d=pd.DataFrame({'stay_id':['1','2','3'],'first_hospital_icu_rn':[1,2,1],'age':[60,60,17],'inhospital_mortality':[0,1,0],'eligible_24h':[True,False,False],'eligible_pre_landmark':[True,False,False],'sepsis_first_offset':[10,10,10],'hospitaladmitoffset':[-10,-10,-10],'unitdischargeoffset':[2000,2000,2000],'hospitaldischargeoffset':[5000,5000,5000]})
  stages=val.selection_masks(d,'eicu');self.assertEqual([x['retained_n'] for x in stages[:3]],[3,2,1]);self.assertEqual(stages[-1]['retained_n'],1)
 def test_patient_selection_missing_id_reported(self):
  a,b=ReconciliationTests().frames()
  screening=pd.DataFrame({'stay_id':['999'],'first_hospital_icu_rn':[1],'age':[60],'inhospital_mortality':[0],'eligible_24h':[True],'eligible_pre_landmark':[True],'sepsis_first_offset':[10],'hospitaladmitoffset':[-10],'unitdischargeoffset':[2000],'hospitaldischargeoffset':[5000]})
  with tempfile.TemporaryDirectory() as tmp:
   result=val.validate(a,b,screening,'eicu',Path(tmp));self.assertEqual(result['selection_comparison']['original_patient_ids_missing_n'],1);self.assertEqual(result['status'],'FILE_COMPARISON_ONLY_SOURCE_VALIDATION_NOT_ESTABLISHED')

class StaticAuditTests(unittest.TestCase):
 def test_shipping_SQL_all_static_references_resolve(self):
  for file in (ROOT/'sql').glob('*.sql'):
   with self.subTest(file=file.name):
    audit=Audit(file.read_text());r=audit.run();self.assertEqual(r['errors'],[]);self.assertIn('未经数据库验证',file.read_text())
 def test_typo_column_detected(self):
  r=Audit('SELECT p.not_a_column FROM eicu_crd.patient p').run();self.assertTrue(any(x['code']=='UNKNOWN_COLUMN' for x in r['errors']))
 def test_wrong_table_detected(self):
  r=Audit('SELECT * FROM eicu_crd.not_a_table').run();self.assertTrue(any(x['code']=='UNKNOWN_SOURCE_TABLE' for x in r['errors']))
 def test_wrong_alias_detected(self):
  r=Audit('SELECT q.age FROM eicu_crd.patient p').run();self.assertTrue(any(x['code']=='UNKNOWN_ALIAS' for x in r['errors']))
 def test_cte_and_correlated_scope_resolve(self):
  r=Audit('WITH a AS (SELECT patientunitstayid AS id FROM eicu_crd.patient) SELECT a.id FROM a WHERE EXISTS(SELECT 1 FROM eicu_crd.diagnosis d WHERE d.patientunitstayid=a.id)').run();self.assertEqual(r['errors'],[])
 def test_select_into_rejected(self):
  r=Audit('SELECT age INTO forbidden_table FROM eicu_crd.patient').run();self.assertTrue(any(x['code']=='WRITE_OR_SELECT_INTO' for x in r['errors']))
 def test_exact_22_predictor_outputs(self):
  expected=set(json.loads((ROOT/'analysis/analysis_config.json').read_text())['feature_columns']);self.assertEqual(len(expected),22)
  for file in [ROOT/'sql/03_mimic_22_predictors.sql',ROOT/'sql/04_eicu_22_predictors.sql']:self.assertTrue(expected.issubset(set(Audit(file.read_text()).run()['outputs'])))

# Evaluate the actual SQL CASE AST in Python with SQL NULL semantics; no SQL engine is used.
def evaluate(node,env):
 if node is None:return None
 if isinstance(node,ast.A_Const):
  if node.isnull:return None
  v=node.val
  return v.ival if isinstance(v,ast.Integer) else (float(v.fval) if isinstance(v,ast.Float) else (v.boolval if isinstance(v,ast.Boolean) else v.sval))
 if isinstance(node,ast.ColumnRef):return env.get(node.fields[-1].sval)
 if isinstance(node,ast.TypeCast):
  v=evaluate(node.arg,env);return None if v is None else int(v)
 if isinstance(node,ast.CoalesceExpr):return next((v for v in [evaluate(a,env) for a in node.args] if v is not None),None)
 if isinstance(node,ast.NullTest):return (evaluate(node.arg,env) is None) if node.nulltesttype.name=='IS_NULL' else (evaluate(node.arg,env) is not None)
 if isinstance(node,ast.BoolExpr):
  values=[evaluate(a,env) for a in node.args]
  if node.boolop.name=='AND_EXPR':return False if False in values else (None if None in values else True)
  if node.boolop.name=='OR_EXPR':return True if True in values else (None if None in values else False)
  return None if values[0] is None else not values[0]
 if isinstance(node,ast.A_Expr):
  left=evaluate(node.lexpr,env);right=evaluate(node.rexpr,env)
  if left is None or right is None:return None
  op=node.name[-1].sval
  return {'<':lambda:left<right,'>':lambda:left>right,'<=':lambda:left<=right,'>=':lambda:left>=right,'=':lambda:left==right,'+':lambda:left+right,'-':lambda:left-right}[op]()
 if isinstance(node,ast.CaseExpr):
  for item in node.args:
   if evaluate(item.expr,env) is True:return evaluate(item.result,env)
  return evaluate(node.defresult,env)
 raise AssertionError('Unsupported test expression '+type(node).__name__)

class SOFAOfflineTests(unittest.TestCase):
 @classmethod
 def setUpClass(cls):
  query=parse_sql('WITH '+(ROOT/'shared_summary_sofa.sql.inc').read_text()+' SELECT * FROM sofa_scored')[0].stmt
  cls.exprs={}
  for c in query.withClause.ctes:
   if c.ctename in ['sofa_components','sofa_scored']:
    cls.exprs.update({t.name:t.val for t in c.ctequery.targetList if t.name})
 def scores(self,**updates):
  env={'pf_supported_min':450.,'pf_unsupported_min':None,'platelets_min':200.,'bilirubin_max':.8,'creatinine_max':.8,'map_min':75.,'gcs_min':15.,'urine_24h_coverage_proxy_ml':2400.,'cv_drug_score':None,'vaso_dose_or_duration_unresolved':False};env.update(updates)
  for name,expr in self.exprs.items():env[name]=evaluate(expr,env)
  return env
 def test_resp_support_interaction(self):
  for args,expected in [({'pf_supported_min':None,'pf_unsupported_min':70},2),({'pf_supported_min':150,'pf_unsupported_min':70},3),({'pf_supported_min':299},2),({'pf_supported_min':99},4),({'pf_supported_min':400},0)]:self.assertEqual(self.scores(**args)['sofa_respiration_24h_new'],expected)
 def test_platelet_boundaries(self):
  for value,expected in [(19,4),(20,3),(49,3),(50,2),(99,2),(100,1),(149,1),(150,0)]:self.assertEqual(self.scores(platelets_min=value)['sofa_coagulation_24h_new'],expected)
 def test_bilirubin_boundaries(self):
  for value,expected in [(1.19,0),(1.2,1),(2,2),(6,3),(12,4)]:self.assertEqual(self.scores(bilirubin_max=value)['sofa_liver_24h_new'],expected)
 def test_gcs_boundaries(self):
  for value,expected in [(3,4),(6,3),(9,3),(10,2),(12,2),(13,1),(14,1),(15,0)]:self.assertEqual(self.scores(gcs_min=value)['sofa_cns_24h'],expected)
 def test_renal_total_and_creatinine(self):
  for value,expected in [(199,4),(200,3),(499,3),(500,0),(2400,0)]:self.assertEqual(self.scores(urine_24h_coverage_proxy_ml=value)['sofa_renal_24h_new'],expected)
  for value,expected in [(1.2,1),(2,2),(3.5,3),(5,4)]:self.assertEqual(self.scores(creatinine_max=value)['sofa_renal_24h_new'],expected)
 def test_missing_total_not_zero(self):
  scores=self.scores(pf_supported_min=None,pf_unsupported_min=None);self.assertIsNone(scores['sofa_component_sum']);self.assertEqual(scores['sofa_missing0_sensitivity'],0);self.assertEqual(scores['sofa_missing_components_n'],1)
 def test_unresolved_dose_not_normal(self):self.assertIsNone(self.scores(vaso_dose_or_duration_unresolved=True)['sofa_cardiovascular_24h_new'])
 def test_both_adapters_share_identical_threshold_CASEs(self):
  for file in [ROOT/'sql/03_mimic_22_predictors.sql',ROOT/'sql/04_eicu_22_predictors.sql']:
   stmt=parse_sql(file.read_text())[0].stmt;cte=next(c for c in stmt.withClause.ctes if c.ctename=='sofa_components')
   for t in cte.ctequery.targetList:
    if t.name in self.exprs:self.assertEqual(RawStream()(t.val),RawStream()(self.exprs[t.name]))

class EncodingTests(unittest.TestCase):
 def test_yes_no_and_numeric_equal(self):
  from encoding import normalize_binary
  result=normalize_binary(pd.Series(['Yes','No','1','0',True,False]));self.assertEqual(result.tolist(),[1,0,1,0,1,0])
 def test_missing_not_zero(self):
  from encoding import normalize_binary
  self.assertTrue(normalize_binary(pd.Series([None,'Unknown'])).isna().all())
 def test_unrecognized_encoding_raises(self):
  from encoding import normalize_binary
  with self.assertRaises(ValueError):normalize_binary(pd.Series(['dose uncertain']))
 def test_original_yes_no_reconciles_with_sql_numeric(self):
  a,b=ReconciliationTests().frames()
  for col in ['mechanical_ventilation_24h','vasopressor_24h','rrt_24h','antibiotic_24h']:a[col]='Yes';b[col]=1
  with tempfile.TemporaryDirectory() as tmp:self.assertTrue(rec.compare(a,b,Path(tmp),'synthetic'))
 def test_main_analysis_has_explicit_binary_path(self):
  text=(ROOT/'analysis/reanalyse.py').read_text();self.assertIn('elif c in BINARY_COLUMNS:x[c]=normalize_binary(df[c])',text)

if __name__=='__main__':unittest.main()
