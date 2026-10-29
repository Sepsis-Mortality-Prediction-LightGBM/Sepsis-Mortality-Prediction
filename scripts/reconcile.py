"""Local reconciliation. Patient-level differences are written ONLY under out/private.
No network calls. A successful process is not evidence of equivalence; inspect status.json.
"""
from pathlib import Path
import argparse,json,hashlib
import pandas as pd,numpy as np
from encoding import BINARY_COLUMNS,normalize_binary
NUM=['age','bmi_model','charlson_comorbidity_index','heart_rate_24h_mean','map_24h_mean','urine_output_24h_mean','lactate_24h_mean','creatinine_24h_mean','glucose_24h_mean','inr_24h_mean','mechanical_ventilation_24h','vasopressor_24h','rrt_24h','antibiotic_24h','fluid_resuscitation_24h_ml','lactate_24h_delta','map_24h_delta','urine_output_24h_delta','sofa_component_sum']
CAT=['sex','admission_source','infection_source']
COMP=['sofa_respiration_24h_new','sofa_coagulation_24h_new','sofa_liver_24h_new','sofa_cardiovascular_24h_new','sofa_cns_24h','sofa_renal_24h_new']
def read(path,sheet=0):
    return pd.read_excel(path,sheet_name=sheet) if path.suffix.lower() in('.xlsx','.xls') else pd.read_csv(path,dtype={'stay_id':'string','hadm_id':'string','subject_id':'string'})
def ids(s):
    # Do not cast through float: IDs must retain all digits.
    s=s.astype('string').str.strip().str.replace(r'\.0$','',regex=True)
    if s.isna().any() or s.eq('').any():raise ValueError('Missing stay identifier')
    return s
def original(d):
    d=d.copy();d['stay_id']=ids(d['stay_id'])
    for field in BINARY_COLUMNS:
        if field in d:d[field]=normalize_binary(d[field])
    if all(c in d for c in COMP):d['sofa_component_sum']=d[COMP].apply(pd.to_numeric,errors='raise').sum(axis=1,min_count=6)
    d['sex']=d['gender'].fillna('Unknown').astype(str)
    source=d['admission_location'] if 'admission_location' in d else d['admission_source']
    def admission(s):
        if pd.isna(s) or str(s)=='INFORMATION NOT AVAILABLE':return 'Unknown'
        s=str(s).upper()
        if s in ['EMERGENCY ROOM','EMERGENCY DEPARTMENT']:return 'Emergency'
        if 'TRANSFER' in s or s=='OTHER HOSPITAL':return 'Transfer'
        return 'Other'
    d['admission_source']=source.map(admission)
    mapping={'respiratory':'Pulmonary','abdominal':'Abdominal','urinary':'Urinary','bloodstream':'Bloodstream','skin_soft_tissue':'Skin_soft_tissue','other':'Other','cns':'Other'}
    d['infection_source']=d['infection_source'].map(mapping).fillna('Unknown')
    return d

def compare(old,new,out,cohort,crosswalk=None,atol=1e-6,rtol=1e-6):
    out.mkdir(parents=True,exist_ok=True);private=out/'private';private.mkdir(exist_ok=True)
    old=original(old);new=new.copy();new['stay_id']=ids(new['stay_id'])
    if crosswalk is not None:
        cw=crosswalk.copy();cw['original_stay_id']=ids(cw['original_stay_id']);cw['reextracted_stay_id']=ids(cw['reextracted_stay_id'])
        if cw['original_stay_id'].duplicated().any() or cw['reextracted_stay_id'].duplicated().any():raise ValueError('Crosswalk must be one-to-one')
        mapping=cw.set_index('reextracted_stay_id')['original_stay_id'];mapped=new['stay_id'].map(mapping)
        # Keep unmatched IDs explicitly; never silently drop them or allow namespace collision.
        new['native_stay_id']=new['stay_id'];new['stay_id']=mapped.fillna('UNMAPPED_NATIVE:'+new['stay_id'])
    duplicates={'original':int(old['stay_id'].duplicated().sum()),'reextracted':int(new['stay_id'].duplicated().sum())}
    if any(duplicates.values()):
        (out/'status.json').write_text(json.dumps({'status':'FAIL_DUPLICATE_IDS','duplicate_rows':duplicates},indent=2));return False
    old=old.set_index('stay_id');new=new.set_index('stay_id');shared=old.index.intersection(new.index)
    original_only=old.index.difference(new.index);new_only=new.index.difference(old.index)
    pd.DataFrame({'stay_id':original_only}).to_csv(private/'original_only_ids.csv',index=False)
    pd.DataFrame({'stay_id':new_only}).to_csv(private/'reextracted_only_ids.csv',index=False)
    a=old.loc[shared];b=new.loc[shared];rows=[];differences=[]
    for field in NUM+CAT+COMP+['inhospital_mortality','hadm_id','subject_id']:
        if field not in a or field not in b:
            rows.append({'field':field,'status':'MISSING_COLUMN','original_present':field in a,'reextracted_present':field in b});continue
        x=a[field];y=b[field];missing=x.isna()^y.isna();both=x.notna()&y.notna()
        if field in NUM+COMP+['inhospital_mortality']:
            x=pd.to_numeric(x,errors='raise');y=pd.to_numeric(y,errors='raise')
            same=pd.Series(np.isclose(x,y,atol=atol,rtol=rtol,equal_nan=True),index=shared)
            err=(x-y).abs();max_error=float(err[both].max()) if both.any() else None
        else:
            if field in ['hadm_id','subject_id']:x=x.astype('string').str.replace(r'\.0$','',regex=True);y=y.astype('string').str.replace(r'\.0$','',regex=True)
            same=x.fillna('<MISSING>').astype(str).eq(y.fillna('<MISSING>').astype(str));max_error=None
        bad=~same
        rows.append({'field':field,'status':'PASS' if not bad.any() else 'DIFFERENT','matched_n':len(shared),'original_missing_n':int(x.isna().sum()),'reextracted_missing_n':int(y.isna().sum()),'missing_mask_disagreement_n':int(missing.sum()),'value_disagreement_n':int((bad&both).sum()),'total_disagreement_n':int(bad.sum()),'max_absolute_difference':max_error})
        for ix in shared[bad]:differences.append({'stay_id':ix,'field':field,'original':x.loc[ix],'reextracted':y.loc[ix],'missing_mask_diff':bool(missing.loc[ix])})
    pd.DataFrame(rows).to_csv(out/'variable_reconciliation.csv',index=False)
    pd.DataFrame(differences,columns=['stay_id','field','original','reextracted','missing_mask_diff']).to_csv(private/'value_differences.csv',index=False)
    resolution=pd.DataFrame(differences,columns=['stay_id','field','original','reextracted','missing_mask_diff'])
    for column in ['discrepancy_category','resolution_decision','source_evidence_reference','reviewer','review_date']:resolution[column]=''
    resolution.to_csv(private/'resolution_template.csv',index=False)
    if 'internal_split' in old:
        # Reuse the existing labels by ID; no new random partition is generated.
        old[['internal_split']].join(new.drop(columns=['internal_split'],errors='ignore'),how='inner').to_csv(private/'matched_reextract_with_original_split.csv')
    landmark=None
    if 'eligible_24h' in b:
        eligible=b['eligible_24h'].map(lambda v: str(v).lower() in ['true','t','1'])
        landmark=int((~eligible).sum());b.loc[~eligible].to_csv(private/'original_ids_failing_rebuilt_landmark.csv')
    mandatory=NUM+CAT+COMP+['inhospital_mortality','hadm_id','subject_id']
    pass_values=all(r['status']=='PASS' for r in rows if r['field'] in mandatory)
    status={'cohort':cohort,'status':'PASS_EXACT_WITHIN_TOLERANCE' if len(shared)>0 and not len(original_only) and not len(new_only) and pass_values and landmark==0 else 'NOT_RECONCILED',
        'original_n':len(old),'reextracted_candidate_n':len(new),'matched_ids_n':len(shared),'original_only_n':len(original_only),'reextracted_only_n':len(new_only),'original_matched_failing_24h_landmark_n':landmark,'absolute_tolerance':atol,'relative_tolerance':rtol,'scope':'ID sets, 22 predictors, six SOFA components, null masks and mortality; provenance limitations still require source audit. Hospital/person ID comparison is reported separately because eICU native aliases may differ.'}
    (out/'status.json').write_text(json.dumps(status,indent=2))
    return status['status']=='PASS_EXACT_WITHIN_TOLERANCE'

def main():
    p=argparse.ArgumentParser();p.add_argument('--original',type=Path,required=True);p.add_argument('--reextracted',type=Path,required=True);p.add_argument('--cohort',choices=['mimic','eicu'],required=True);p.add_argument('--out',type=Path,required=True);p.add_argument('--crosswalk',type=Path);args=p.parse_args()
    old=read(args.original,'Modified_data' if args.cohort=='eicu' and args.original.suffix=='.xlsx' else 0)
    ok=compare(old,read(args.reextracted),args.out,args.cohort,read(args.crosswalk) if args.crosswalk else None)
    hashes={k:hashlib.sha256(v.read_bytes()).hexdigest() for k,v in {'original':args.original,'reextracted':args.reextracted}.items()}
    (args.out/'input_sha256.json').write_text(json.dumps(hashes,indent=2));print('RECONCILED' if ok else 'NOT_RECONCILED');raise SystemExit(0 if ok else 2)
if __name__=='__main__':main()
