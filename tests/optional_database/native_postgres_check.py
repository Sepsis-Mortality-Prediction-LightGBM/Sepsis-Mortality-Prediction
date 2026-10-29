# OPTIONAL DATABASE TEST — NOT RUN IN THE OFFLINE TASK.
"""Optional PostgreSQL-native validation. Only a new temporary synthetic database is created.
No source research database, patient file or external clinical API is used.
Requires requirements-test-native.txt; output is aggregate JSON.
"""
from pathlib import Path
import sys,tempfile,json,datetime,subprocess,os
import pgserver,psycopg,fasteners
from psycopg import sql
PUB=Path(__file__).resolve().parents[2]
import argparse,shutil
parser=argparse.ArgumentParser();parser.add_argument('--out',type=Path,required=True);args=parser.parse_args()
tmp=Path(tempfile.mkdtemp(prefix='spg_',dir='/private/tmp'));runtime=tmp/'runtime'
pgserver.PostgresServer.runtime_path=runtime;pgserver.PostgresServer.lock_path=runtime/'.lockfile';pgserver.PostgresServer._lock=fasteners.InterProcessLock(runtime/'.lockfile')
server=pgserver.get_server(tmp/'database',cleanup_mode='stop');tests=[]
with psycopg.connect(server.get_uri(),autocommit=True) as c:
 for sc in ['mimiciv_hosp','mimiciv_icu','mimiciv_derived','eicu_crd']:c.execute(sql.SQL('CREATE SCHEMA {}').format(sql.Identifier(sc)))
 c.execute((PUB/'tests/mimic_schema.sql').read_text());c.execute('SET search_path=eicu_crd');c.execute((PUB/'tests/eicu_schema.sql').read_text());c.execute('SET search_path=public')
 version=c.execute('SHOW server_version').fetchone()[0]
 for f in sorted((PUB/'sql').glob('*.sql')):
  assert c.execute(f.read_text()).fetchall()==[],f.name
  tests.append('native_empty_'+f.name)
 def insert(table,values):
  sc,t=table.split('.')
  cols=c.execute("SELECT column_name,data_type FROM information_schema.columns WHERE table_schema=%s AND table_name=%s AND is_nullable='NO' AND column_default IS NULL",(sc,t)).fetchall()
  values=values.copy()
  for name,typ in cols:
   if name not in values:values[name]=datetime.datetime(2020,1,1) if 'timestamp' in typ else (False if typ=='boolean' else ('' if typ in ['character varying','character','text'] else 0))
  c.execute(sql.SQL('INSERT INTO {}.{} ({}) VALUES ({})').format(sql.Identifier(sc),sql.Identifier(t),sql.SQL(',').join(map(sql.Identifier,values)),sql.SQL(',').join(sql.Placeholder() for _ in values)),list(values.values()))
 t0=datetime.datetime(2020,1,1);at=lambda h:t0+datetime.timedelta(hours=h)
 insert('mimiciv_hosp.patients',dict(subject_id=1,gender='F',anchor_age=60,anchor_year=2020,anchor_year_group='2017 - 2019'))
 insert('mimiciv_hosp.admissions',dict(subject_id=1,hadm_id=1,admittime=t0,dischtime=at(100),admission_type='EMERGENCY',hospital_expire_flag=0,admission_location='EMERGENCY ROOM'))
 insert('mimiciv_icu.icustays',dict(subject_id=1,hadm_id=1,stay_id=1,intime=t0,outtime=at(72),first_careunit='MICU',last_careunit='MICU',los=3))
 for h,item,val in [(.25,220045,80),(2,220045,100),(.25,220052,65),(2,220052,75),(.5,220739,1),(.5,223900,1),(.5,223901,1),(1,226512,70),(1,226730,170)]:
  insert('mimiciv_icu.chartevents',dict(subject_id=1,hadm_id=1,stay_id=1,charttime=at(h),storetime=at(h),itemid=item,valuenum=val,value=str(val)))
 for h,val in [(1,100),(23,200),(24,900)]:insert('mimiciv_icu.outputevents',dict(subject_id=1,hadm_id=1,stay_id=1,charttime=at(h),storetime=at(h),itemid=226559,value=val))
 for lid,(item,h,val,store) in enumerate([(50813,1,4,1),(50813,23,2,23),(50813,2,20,25),(50912,2,.8,2),(50931,2,100,2),(51237,2,1,2),(51265,2,180,2),(50885,2,.8,2)],1):
  insert('mimiciv_hosp.labevents',dict(labevent_id=lid,subject_id=1,hadm_id=1,specimen_id=lid,charttime=at(h),storetime=at(store),itemid=item,valuenum=val,value=str(val)))
 insert('mimiciv_hosp.prescriptions',dict(subject_id=1,hadm_id=1,pharmacy_id=1,starttime=at(1),stoptime=at(48),drug_type='MAIN',drug='Vancomycin',route='IV'))
 insert('mimiciv_hosp.microbiologyevents',dict(microevent_id=1,subject_id=1,hadm_id=1,micro_specimen_id=1,chartdate=t0,charttime=at(2),spec_type_desc='BLOOD CULTURE',spec_itemid=70012))
 insert('mimiciv_icu.d_items',dict(itemid=225158,label='Normal Saline',abbreviation='NS',linksto='inputevents'))
 insert('mimiciv_icu.inputevents',dict(subject_id=1,hadm_id=1,stay_id=1,itemid=225158,starttime=at(23.5),endtime=at(24.5),amount=500,amountuom='mL',statusdescription='FinishedRunning'))
 for idx,(a,b) in enumerate([(3,3.5),(3.5,4)],1):insert('mimiciv_icu.inputevents',dict(subject_id=1,hadm_id=1,stay_id=1,itemid=221906,starttime=at(a),endtime=at(b),rate=.1,rateuom='mcg/kg/min',amount=1,amountuom='mg',patientweight=70,linkorderid=idx,statusdescription='FinishedRunning'))
 def query(name):
  r=c.execute((PUB/'sql'/name).read_text());columns=[x.name for x in r.description];return [dict(zip(columns,row)) for row in r.fetchall()]
 r=query('03_mimic_22_predictors.sql');assert len(r)==1,('MIMIC fixture cohort',len(r));r=r[0]
 for field,expected in [('heart_rate_24h_mean',90),('map_24h_mean',70),('lactate_24h_mean',3),('lactate_24h_delta',-2),('urine_output_24h_mean',150),('urine_output_24h_sum',300),('fluid_resuscitation_24h_ml',250),('sofa_cardiovascular_24h_new',3)]:assert abs(float(r[field])-expected)<1e-6,(field,r[field],expected);tests.append('mimic_'+field)
 assert r['eligible_24h'] and r['infection_source']=='Unknown' and r['charlson_comorbidity_index'] is None;tests.append('mimic_landmark_and_unavailable_history')
 insert('eicu_crd.patient',dict(patientunitstayid=200,patienthealthsystemstayid=200,uniquepid='SYNTHETIC',hospitalid=1,age='60',gender='Female',hospitaladmitoffset=-60,unitvisitnumber=1,unitdischargeoffset=3000,hospitaldischargeoffset=6000,hospitaldischargestatus='Alive',admissionweight=70,admissionheight=170,hospitaladmitsource='Emergency Department'))
 insert('eicu_crd.diagnosis',dict(diagnosisid=1,patientunitstayid=200,diagnosisoffset=10,diagnosisstring='sepsis',diagnosispriority='Primary',activeupondischarge=False))
 for off,hr,mapv in [(60,80,65),(1380,100,75)]:insert('eicu_crd.vitalperiodic',dict(vitalperiodicid=off,patientunitstayid=200,observationoffset=off,heartrate=hr,systemicmean=mapv))
 for idx,(name,off,value,rev) in enumerate([('lactate',60,4,60),('lactate',1380,2,1380),('lactate',120,20,1500),('creatinine',120,.8,120),('glucose',120,100,120),('PT - INR',120,1,120),('platelets x 1000',120,180,120),('total bilirubin',120,.8,120)],1):insert('eicu_crd.lab',dict(labid=idx,patientunitstayid=200,labresultoffset=off,labresultrevisedoffset=rev,labtypeid=1,labname=name,labresult=value))
 for idx,(off,value) in enumerate([(60,100),(1380,200),(1440,900)],1):insert('eicu_crd.intakeoutput',dict(intakeoutputid=idx,patientunitstayid=200,intakeoutputoffset=off,intakeoutputentryoffset=off,cellpath='flowsheet|Flowsheet Cell Labels|I&O|Output (ml)|Urine',celllabel='Urine',cellvaluenumeric=value,cellvaluetext=str(value)))
 insert('eicu_crd.infusiondrug',dict(infusiondrugid=1,patientunitstayid=200,infusionoffset=100,drugname='Norepinephrine (ml/hr)',drugrate='3'))
 r=query('04_eicu_22_predictors.sql');assert len(r)==1;r=r[0]
 for field,expected in [('heart_rate_24h_mean',90),('map_24h_mean',70),('lactate_24h_mean',3),('lactate_24h_delta',-2),('urine_output_24h_mean',150),('urine_output_24h_sum',300)]:assert abs(float(r[field])-expected)<1e-6,(field,r[field],expected);tests.append('eicu_'+field)
 assert r['vaso_dose_or_duration_unresolved'] and r['sofa_cardiovascular_24h_new'] is None;tests.append('eicu_unknown_rate_and_duration_not_zero')
 # Exercise the actual read-only runner through a temporary synthetic libpq service.
 info=server.get_postmaster_info();svc=tmp/'pg_service.conf';svc.write_text('[synthetic_sepsis_test]\nhost='+str(info.socket_dir)+'\nport='+str(info.port)+'\nuser=postgres\ndbname=postgres\n')
 env=os.environ.copy();env['PGSERVICEFILE']=str(svc)
 subprocess.run([sys.executable,str(PUB/'scripts/run_postgres.py'),'--service','synthetic_sepsis_test','--cohort','mimic','--database-version','2.2','--execute-authorized','--out',str(tmp/'runner_output')],env=env,check=True)
 manifest=json.loads((tmp/'runner_output/execution_manifest.json').read_text());assert manifest['executed'] and manifest['transaction_read_only']=='on';tests.append('actual_runner_readonly_export_on_synthetic_database')
result={'postgres_version':version,'fixture':'fully synthetic raw clinical-schema records, NOT source research data','passed_checks':len(tests),'checks':tests,'real_source_extraction':False}
args.out.parent.mkdir(parents=True,exist_ok=True);args.out.write_text(json.dumps(result,indent=2));print(json.dumps(result,indent=2));server.cleanup();shutil.rmtree(tmp)
