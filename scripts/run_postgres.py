# 未经数据库验证 / NOT VALIDATED AGAINST ACTUAL SOURCE DATABASES.
# Prepared for future authorized execution; not invoked by any offline checks or CI.
"""Execute bundled SELECT queries in an authorized PostgreSQL environment.
Uses a libpq service from ~/.pg_service.conf / .pgpass; never accepts passwords on CLI.
Each cohort is exported in one REPEATABLE READ, READ ONLY transaction. Clinical files stay private.
"""
from pathlib import Path
import argparse,json,hashlib,datetime,os

def main():
 p=argparse.ArgumentParser();p.add_argument('--service',required=True);p.add_argument('--cohort',choices=['mimic','eicu'],required=True);p.add_argument('--out',type=Path,required=True);p.add_argument('--database-version',required=True);p.add_argument('--hosp-schema',default='mimiciv_hosp');p.add_argument('--icu-schema',default='mimiciv_icu');p.add_argument('--eicu-schema',default='eicu_crd');p.add_argument('--preflight-only',action='store_true');p.add_argument('--execute-authorized',action='store_true');args=p.parse_args()
 if not args.execute_authorized:p.error('Database execution is disabled by default. This script is for a future explicitly authorized environment only.')
 import psycopg
 from psycopg.conninfo import make_conninfo
 if args.database_version!=('2.2' if args.cohort=='mimic' else '2.0'):p.error('Database version must match the manuscript; revise the contract before using another release.')
 os.umask(0o077);out=args.out/'private';out.mkdir(parents=True,exist_ok=True)
 root=Path(__file__).resolve().parents[1]
 files=([('cohort','01_mimic_cohort.sql'),('predictors','03_mimic_22_predictors.sql'),('sofa','05_mimic_sofa.sql')] if args.cohort=='mimic' else [('cohort','02_eicu_cohort.sql'),('predictors','04_eicu_22_predictors.sql'),('sofa','06_eicu_sofa.sql')])
 meta={'started_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'cohort':args.cohort,'raw_database_version_expected':'2.2' if args.cohort=='mimic' else '2.0','database_version_confirmed_by_operator':args.database_version,'preflight_only':args.preflight_only,'executed':False,'queries':{}}
 # make_conninfo escapes service names; connection parameters are never logged.
 with psycopg.connect(make_conninfo(service=args.service),autocommit=True) as con:
  con.execute('BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY')
  try:
   con.execute("SET LOCAL statement_timeout='0'")
   meta['postgres_version']=con.execute('SHOW server_version').fetchone()[0]
   meta['transaction_read_only']=con.execute('SHOW transaction_read_only').fetchone()[0]
   for kind,name in files:
    source_sql=(root/'sql'/name).read_text().rstrip().rstrip(';');sql=source_sql
    for source_schema,target_schema in [('mimiciv_hosp',args.hosp_schema),('mimiciv_icu',args.icu_schema),('eicu_crd',args.eicu_schema)]:
     sql=sql.replace(source_schema+'.',psycopg.sql.Identifier(target_schema).as_string(con)+'.')
    if args.preflight_only:
     plan=con.execute('EXPLAIN (FORMAT JSON) '+sql).fetchone()[0]
     (out/(args.cohort+'_'+kind+'_plan.json')).write_text(json.dumps(plan,indent=2));meta['queries'][name]={'preflight':'pass','sql_sha256':hashlib.sha256(sql.encode()).hexdigest()};continue
    path=out/(args.cohort+'_'+kind+'.csv')
    # SQL text comes only from shipped files, not a user-supplied identifier/path.
    temp=path.with_suffix('.csv.part')
    with con.cursor() as cur,temp.open('wb') as stream:
     with cur.copy('COPY ('+sql+') TO STDOUT WITH (FORMAT CSV, HEADER TRUE)') as copy:
      for block in copy:stream.write(block)
    temp.replace(path)
    meta['queries'][name]={'source_sql_sha256':hashlib.sha256(source_sql.encode()).hexdigest(),'executed_sql_sha256':hashlib.sha256(sql.encode()).hexdigest(),'output_sha256':hashlib.sha256(path.read_bytes()).hexdigest(),'output':path.name}
   con.execute('COMMIT');meta['executed']=not args.preflight_only
  except BaseException:
   con.execute('ROLLBACK');raise
 meta['finished_utc']=datetime.datetime.now(datetime.timezone.utc).isoformat()
 (args.out/'execution_manifest.json').write_text(json.dumps(meta,indent=2));print('Preflight complete; no extraction performed.' if args.preflight_only else 'Extraction complete. Reconciliation is a separate required step.')
if __name__=='__main__':main()
