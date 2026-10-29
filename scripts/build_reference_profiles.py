"""Build aggregate comparator profiles from locally held cleaned workbooks. No network or DB.
Do not include original workbooks or row-level output in the public package.
"""
from pathlib import Path
import argparse,json,hashlib
import reconcile as rec
from validate_extraction import profile
p=argparse.ArgumentParser();p.add_argument('--mimic',type=Path,required=True);p.add_argument('--eicu',type=Path,required=True);p.add_argument('--out',type=Path,required=True);args=p.parse_args();args.out.mkdir(parents=True,exist_ok=True)
counts={}
for name,path,sheet in [('mimic',args.mimic,0),('eicu',args.eicu,'Modified_data')]:
 raw=rec.read(path,sheet);data=rec.original(raw);meta=profile(data)
 meta['source_workbook_sha256']=hashlib.sha256(path.read_bytes()).hexdigest();meta['cohort']=name
 (args.out/(name+'_archival_reference_profile.json')).write_text(json.dumps(meta,indent=2,allow_nan=False))
 counts[name]={'n':len(data),'deaths':int(data.inhospital_mortality.eq(1).sum()),'reference_status':'ARCHIVAL_COMPARATOR_NOT_GROUND_TRUTH','source_database_reextraction_performed':False}
 if name=='mimic':counts[name]['internal_split_counts']=raw.internal_split.value_counts(dropna=False).to_dict()
(args.out/'archival_cohort_counts.json').write_text(json.dumps(counts,indent=2,allow_nan=False))
