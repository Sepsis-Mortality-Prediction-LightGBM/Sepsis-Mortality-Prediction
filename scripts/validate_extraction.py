"""Compare exported files without connecting to any database.
Produces cohort counts, selection-stage counts, distributions, missingness and ID/value audit.
Reference cleaned data are an archival comparator, not automatically ground truth.
"""
from pathlib import Path
import argparse,json,hashlib
import numpy as np,pandas as pd
import reconcile as rec
FEATURES=rec.NUM+rec.CAT

def clean_json(x):
 if x is pd.NA or x is pd.NaT:return None
 if isinstance(x,dict):return {str(k):clean_json(v) for k,v in x.items()}
 if isinstance(x,list):return [clean_json(v) for v in x]
 if isinstance(x,(np.integer,)):return int(x)
 if isinstance(x,(np.floating,float)):return None if not np.isfinite(x) else float(x)
 if isinstance(x,np.bool_):return bool(x)
 return x

def profile(d):
 result={'n':len(d),'reference_status':'ARCHIVAL_COMPARATOR_NOT_GROUND_TRUTH','numeric':{},'categorical':{}}
 for name in FEATURES+rec.COMP+['inhospital_mortality']:
  if name not in d:continue
  s=d[name];entry={'n':len(s),'nonmissing_n':int(s.notna().sum()),'missing_n':int(s.isna().sum()),'missing_rate':float(s.isna().mean()) if len(s) else None,'unique_nonmissing_n':int(s.nunique())}
  if name in rec.CAT:
   entry['counts']={str(k):int(v) for k,v in s.fillna('<MISSING>').value_counts().items()};result['categorical'][name]=entry
  else:
   s=pd.to_numeric(s,errors='raise');non=s.dropna()
   entry.update({'mean':non.mean(),'std':non.std(ddof=1),'min':non.min(),'q25':non.quantile(.25),'median':non.median(),'q75':non.quantile(.75),'max':non.max()});result['numeric'][name]=entry
 return clean_json(result)

def ks_statistic(x,y):
 x=np.sort(np.asarray(x,dtype=float));y=np.sort(np.asarray(y,dtype=float))
 if not len(x) or not len(y):return None
 grid=np.unique(np.concatenate([x,y]));return float(np.max(np.abs(np.searchsorted(x,grid,side='right')/len(x)-np.searchsorted(y,grid,side='right')/len(y))))

def distribution_compare(original,reextracted):
 a=profile(original);b=profile(reextracted);numeric=[];categorical=[];missing=[]
 for name in FEATURES+rec.COMP+['inhospital_mortality']:
  if name not in original or name not in reextracted:
   missing.append({'field':name,'status':'MISSING_COLUMN','original_present':name in original,'reextracted_present':name in reextracted});continue
  typ='categorical' if name in rec.CAT else 'numeric';x=a[typ][name];y=b[typ][name]
  gap=None if x['missing_rate'] is None or y['missing_rate'] is None else 100*(y['missing_rate']-x['missing_rate'])
  missing.append({'field':name,'original_n':x['n'],'reextracted_n':y['n'],'original_missing_n':x['missing_n'],'reextracted_missing_n':y['missing_n'],'original_missing_rate':x['missing_rate'],'reextracted_missing_rate':y['missing_rate'],'difference_percentage_points':gap,'review_flag':gap is not None and abs(gap)>1e-8})
  if typ=='numeric':
   row={'field':name}
   for stat in ['mean','std','min','q25','median','q75','max']:
    row['original_'+stat]=x[stat];row['reextracted_'+stat]=y[stat];row['difference_'+stat]=None if x[stat] is None or y[stat] is None else y[stat]-x[stat]
   denom=None if x['std'] is None or y['std'] is None else np.sqrt((x['std']**2+y['std']**2)/2)
   row['standardized_mean_difference']=None if denom is None or denom==0 or x['mean'] is None or y['mean'] is None else (y['mean']-x['mean'])/denom
   row['empirical_KS_D']=ks_statistic(original[name].dropna(),reextracted[name].dropna());row['review_flag']=row['empirical_KS_D'] is not None and row['empirical_KS_D']>1e-8
   numeric.append(row)
  else:
   for level in sorted(set(x['counts'])|set(y['counts'])):
    count1=x['counts'].get(level,0);count2=y['counts'].get(level,0)
    pct1=100*count1/x['n'] if x['n'] else None;pct2=100*count2/y['n'] if y['n'] else None
    categorical.append({'field':name,'level':level,'original_n':count1,'reextracted_n':count2,'original_percent':pct1,'reextracted_percent':pct2,'difference_percentage_points':None if pct1 is None or pct2 is None else pct2-pct1})
 return numeric,categorical,missing

def as_bool(s):return s.map(lambda x:str(x).strip().lower() in ['true','t','1','1.0'])
def selection_masks(d,cohort):
 all_rows=pd.Series(True,index=d.index);first='first_icu_rn' if cohort=='mimic' else 'first_hospital_icu_rn'
 required=[first,'age','inhospital_mortality','eligible_24h','eligible_pre_landmark']
 for col in required:
  if col not in d:raise ValueError('Screening export missing '+col)
 stages=[('all_ICU_stays',all_rows),('first_ICU_as_observable',pd.to_numeric(d[first],errors='coerce').eq(1)),('adult_age_ge18',pd.to_numeric(d.age,errors='coerce').ge(18))]
 if cohort=='mimic':
  stages.append(('operational_sepsis',d['suspected_infection_time'].notna()&pd.to_numeric(d['sepsis_sofa_max'],errors='coerce').ge(2)))
  dates={c:pd.to_datetime(d[c],errors='coerce') for c in ['intime','outtime','admittime','dischtime','deathtime']}
  valid=dates['intime'].notna()&dates['outtime'].notna()&dates['admittime'].notna()&dates['dischtime'].notna()&(dates['admittime']<=dates['intime'])&(dates['outtime']>=dates['intime'])&(dates['dischtime']>=dates['intime'])
 else:
  stages.append(('operational_sepsis',d['sepsis_first_offset'].notna()))
  valid=d['hospitaladmitoffset'].le(0)&d['unitdischargeoffset'].ge(0)&d['hospitaldischargeoffset'].ge(0)
 stages.extend([('outcome_available',pd.to_numeric(d.inhospital_mortality,errors='coerce').isin([0,1])),('valid_key_timestamps',valid),('24h_landmark_eligible',as_bool(d.eligible_24h))])
 result=[];mask=all_rows.copy()
 for name,new_mask in stages:
  before=int(mask.sum());mask=mask&new_mask.fillna(False);result.append({'stage':name,'retained_n':int(mask.sum()),'excluded_at_stage_n':before-int(mask.sum()),'mask':mask.copy()})
 return result

def validate(original,reextracted,screening,cohort,out,crosswalk=None,execution_manifest=None):
 out.mkdir(parents=True,exist_ok=True);private=out/'private';private.mkdir(exist_ok=True)
 a=rec.original(original);b=reextracted.copy();b['stay_id']=rec.ids(b['stay_id'])
 # The equality audit performs its own one-to-one crosswalk, duplicate and source-key checks.
 exact=rec.compare(original,reextracted,out/'row_level',cohort,crosswalk)
 # Distributions are descriptive for the whole candidate export and the explicitly eligible subset.
 contexts={'all_reextracted_candidates':b}
 if 'eligible_24h' in b:contexts['eligible_24h_subset']=b.loc[as_bool(b.eligible_24h)]
 rows_num=[];rows_cat=[];rows_missing=[];sample_rows=[]
 for context,frame in contexts.items():
  num,cat,missing=distribution_compare(a,frame)
  for r in num:r['comparison_scope']=context
  for r in cat:r['comparison_scope']=context
  for r in missing:r['comparison_scope']=context
  rows_num+=num;rows_cat+=cat;rows_missing+=missing
  mortality=pd.to_numeric(frame.get('inhospital_mortality',pd.Series(index=frame.index,dtype=float)),errors='coerce')
  sample_rows.append({'scope':context,'n':len(frame),'deaths':int(mortality.eq(1).sum()),'outcome_missing_n':int(mortality.isna().sum()),'reference_n':len(a),'reference_deaths':int(a.inhospital_mortality.eq(1).sum()),'n_difference':len(frame)-len(a)})
 for name,rows in [('numeric_distribution_comparison',rows_num),('categorical_distribution_comparison',rows_cat),('missingness_comparison',rows_missing),('sample_size_comparison',sample_rows)]:pd.DataFrame(rows).to_csv(out/(name+'.csv'),index=False)
 flow=[];selection_result=None
 if screening is not None:
  screen=screening.copy();screen['stay_id']=rec.ids(screen.stay_id)
  if screen.stay_id.duplicated().any():raise ValueError('Screening export has duplicate ICU IDs')
  stages=selection_masks(screen,cohort);flow=[{k:v for k,v in x.items() if k!='mask'} for x in stages]
  screen['first_failed_rebuilt_stage']='retained_through_landmark'
  passed=pd.Series(True,index=screen.index)
  for item in stages:
   fail=passed&~item['mask'];screen.loc[fail,'first_failed_rebuilt_stage']=item['stage'];passed=item['mask']
  native_index=screen.set_index('stay_id');old_ids=a['stay_id']
  if crosswalk is not None:
   cw=crosswalk.copy();cw['original_stay_id']=rec.ids(cw.original_stay_id);cw['reextracted_stay_id']=rec.ids(cw.reextracted_stay_id)
   old_ids=old_ids.map(cw.set_index('original_stay_id').reextracted_stay_id).fillna('UNMAPPED')
  lookup=pd.DataFrame({'original_stay_id':a['stay_id'].values,'native_stay_id':old_ids.values})
  lookup['found_in_source_screening']=lookup.native_stay_id.isin(native_index.index)
  lookup['first_failed_rebuilt_stage']=lookup.native_stay_id.map(native_index.first_failed_rebuilt_stage).fillna('not_found_in_source_screening')
  lookup.to_csv(private/'patient_selection_results.csv',index=False)
  selection_result={'original_patient_ids_found_n':int(lookup.found_in_source_screening.sum()),'original_patient_ids_missing_n':int((~lookup.found_in_source_screening).sum()),'original_patient_first_failure_counts':lookup.first_failed_rebuilt_stage.value_counts().to_dict(),'core_completeness_status':'Original core-completeness rule is unspecified; proposed HR/MAP flag is not an established original exclusion.'}
  pd.DataFrame(flow).to_csv(out/'screening_flow.csv',index=False)
 (out/'original_profile.json').write_text(json.dumps(profile(a),indent=2,allow_nan=False));(out/'reextracted_profile.json').write_text(json.dumps(profile(b),indent=2,allow_nan=False))
 selection_ok=selection_result is not None and selection_result['original_patient_ids_missing_n']==0 and set(selection_result['original_patient_first_failure_counts']).issubset({'retained_through_landmark'})
 sample_ok=all(r['n_difference']==0 for r in sample_rows)
 report={'all_file_checks_passed':bool(exact and selection_ok and sample_ok),'screening_patient_selection_passed':bool(selection_ok),'sample_sizes_match':bool(sample_ok),'status':'FILE_COMPARISON_ONLY_SOURCE_VALIDATION_NOT_ESTABLISHED','cohort':cohort,'exact_row_comparison_passed':bool(exact),'selection_comparison':selection_result,'screening_flow_available':screening is not None,'distribution_tests':'Descriptive differences and empirical KS statistic; not hypothesis-test evidence of equivalence','source_run_manifest_supplied':execution_manifest is not None,'source_database_version_verified_by_this_script':False,'release_note':'A match to an archival cleaned file does not validate the original extraction rules or resolve known internal data inconsistencies.'}
 if execution_manifest is not None:
  report['export_manifest_reports_executed']=execution_manifest.get('executed')
  report['export_manifest_cohort']=execution_manifest.get('cohort')
  report['export_manifest_read_only']=execution_manifest.get('transaction_read_only')
 (out/'validation_report.json').write_text(json.dumps(clean_json(report),indent=2,allow_nan=False));return report

def main():
 p=argparse.ArgumentParser();p.add_argument('--cohort',choices=['mimic','eicu'],required=True);p.add_argument('--original',type=Path,required=True);p.add_argument('--reextracted',type=Path,required=True);p.add_argument('--screening',type=Path,required=True);p.add_argument('--out',type=Path,required=True);p.add_argument('--crosswalk',type=Path);p.add_argument('--execution-manifest',type=Path);args=p.parse_args()
 original=rec.read(args.original,'Modified_data' if args.cohort=='eicu' and args.original.suffix=='.xlsx' else 0)
 report=validate(original,rec.read(args.reextracted),rec.read(args.screening),args.cohort,args.out,rec.read(args.crosswalk) if args.crosswalk else None,json.loads(args.execution_manifest.read_text()) if args.execution_manifest else None)
 paths={'original':args.original,'reextracted':args.reextracted,'screening':args.screening}
 (args.out/'input_sha256.json').write_text(json.dumps({k:hashlib.sha256(v.read_bytes()).hexdigest() for k,v in paths.items()},indent=2))
 print('File comparisons completed; inspect validation_report.json. No database connection was made.')
 if not report['all_file_checks_passed']:raise SystemExit(2)
if __name__=='__main__':main()
