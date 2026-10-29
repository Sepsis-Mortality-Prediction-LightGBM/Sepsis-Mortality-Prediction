"""Reanalysis of three local, author-confirmed cleaned cohorts.

Run with Python 3.12 and the versions recorded in requirements.txt.
No patient records are uploaded. --out-dir may contain restricted local predictions;
exclude its private subdirectory from any public code release.
"""
from pathlib import Path
import argparse,json,hashlib,sys,warnings,time
import numpy as np,pandas as pd
from scipy.special import expit,logit
from scipy.optimize import brentq
from scipy.stats import norm
from sklearn.model_selection import StratifiedKFold,GridSearchCV,cross_val_predict
from sklearn.pipeline import Pipeline
from sklearn.compose import ColumnTransformer
from sklearn.impute import SimpleImputer
from sklearn.preprocessing import OneHotEncoder,StandardScaler
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import roc_auc_score,average_precision_score,brier_score_loss,log_loss,roc_curve,precision_recall_curve
from sklearn.base import clone
from lightgbm import LGBMClassifier
from xgboost import XGBClassifier
from catboost import CatBoostClassifier
import sklearn,scipy,catboost,lightgbm,xgboost,joblib

SEED=20261021
COMP=['sofa_respiration_24h_new','sofa_coagulation_24h_new','sofa_liver_24h_new','sofa_cardiovascular_24h_new','sofa_cns_24h','sofa_renal_24h_new']
CAT=['sex','admission_source','infection_source']
NUM=['age','bmi_model','charlson_comorbidity_index','heart_rate_24h_mean','map_24h_mean','urine_output_24h_mean','lactate_24h_mean','creatinine_24h_mean','glucose_24h_mean','inr_24h_mean','mechanical_ventilation_24h','vasopressor_24h','rrt_24h','antibiotic_24h','fluid_resuscitation_24h_ml','lactate_24h_delta','map_24h_delta','urine_output_24h_delta','sofa_component_sum']
FEATURES=NUM+CAT
CATEGORIES=[['F','M','Unknown'],['Emergency','Transfer','Other','Unknown'],['Pulmonary','Abdominal','Urinary','Bloodstream','Skin_soft_tissue','Other','Unknown']]
warnings.filterwarnings('ignore',category=FutureWarning)

def clean(df):
    x=pd.DataFrame(index=df.index)
    for c in NUM:
        if c=='sofa_component_sum':x[c]=df[COMP].apply(pd.to_numeric,errors='raise').sum(axis=1,min_count=6)
        else:x[c]=pd.to_numeric(df[c],errors='coerce')
    x['sex']=df['gender'].fillna('Unknown').astype(str)
    source=df['admission_location'] if 'admission_location' in df else df['admission_source']
    def admission(s):
        if pd.isna(s) or str(s)=='INFORMATION NOT AVAILABLE':return 'Unknown'
        s=str(s).upper()
        if s in ['EMERGENCY ROOM','EMERGENCY DEPARTMENT']:return 'Emergency'
        if 'TRANSFER' in s or s=='OTHER HOSPITAL':return 'Transfer'
        return 'Other'
    x['admission_source']=source.map(admission)
    mapping={'respiratory':'Pulmonary','abdominal':'Abdominal','urinary':'Urinary','bloodstream':'Bloodstream','skin_soft_tissue':'Skin_soft_tissue','other':'Other','cns':'Other'}
    x['infection_source']=df['infection_source'].map(mapping).fillna('Unknown')
    assert x['sofa_component_sum'].notna().all()
    return x[FEATURES]

def preprocess(no_score=False,score_only=False):
    numeric=['sofa_component_sum'] if score_only else [n for n in NUM if not(no_score and n=='sofa_component_sum')]
    transformers=[('num',Pipeline([('impute',SimpleImputer(strategy='median',add_indicator=True)),('scale',StandardScaler())]),numeric)]
    if not score_only:transformers.append(('cat',OneHotEncoder(categories=CATEGORIES,drop='first',handle_unknown='ignore',sparse_output=False),CAT))
    return ColumnTransformer(transformers,remainder='drop',verbose_feature_names_out=True)

def definitions(name):
    if name=='LASSO':
        model=LogisticRegression(penalty='l1',solver='liblinear',max_iter=5000,random_state=SEED)
        grid={'model__C':[.001,.01,.1,1,10]}
    elif name=='XGBoost':
        model=XGBClassifier(n_estimators=400,subsample=.8,colsample_bytree=.8,reg_lambda=5,objective='binary:logistic',eval_metric='logloss',n_jobs=2,random_state=SEED,tree_method='hist')
        grid={'model__max_depth':[2,4],'model__learning_rate':[.03,.08],'model__min_child_weight':[1,5]}
    elif name in ['LightGBM','LightGBM_no_SOFA','LightGBM_time_sensitivity']:
        model=LGBMClassifier(n_estimators=400,subsample=.8,subsample_freq=1,colsample_bytree=.8,reg_lambda=5,verbosity=-1,n_jobs=2,random_state=SEED,deterministic=True,force_col_wise=True)
        grid={'model__num_leaves':[7,15],'model__learning_rate':[.03,.08],'model__min_child_samples':[20,50]}
    else:
        model=CatBoostClassifier(iterations=500,loss_function='Logloss',verbose=False,thread_count=2,random_seed=SEED,allow_writing_files=False)
        grid={'model__depth':[3,5],'model__learning_rate':[.03,.08],'model__l2_leaf_reg':[3,10]}
    return Pipeline([('preprocess',preprocess(no_score=name=='LightGBM_no_SOFA')),('model',model)]),grid

def calibration(y,p):
    z=logit(np.clip(p,1e-6,1-1e-6));a=np.column_stack([np.ones(len(y)),z]);b=np.array([0.,1.])
    for _ in range(60):
        mu=expit(a@b);ww=np.maximum(mu*(1-mu),1e-10)
        step=np.linalg.solve((a.T*ww)@a+np.eye(2)*1e-9,a.T@(mu-y))
        step=np.clip(step,-2,2);b-=step
        if np.max(np.abs(step))<1e-7:break
    return b

def metrics(y,p,threshold=None):
    b=calibration(y,p)
    d={'AUROC':roc_auc_score(y,p),'AUPRC':average_precision_score(y,p),'Brier':brier_score_loss(y,p),'LogLoss':log_loss(y,p),'cal_intercept':b[0],'cal_slope':b[1]}
    if threshold is not None:
        pred=p>=threshold;d['sensitivity']=float(pred[y==1].mean());d['specificity']=float((~pred[y==0]).mean())
    return {k:float(v) for k,v in d.items()}

def with_ci(y,p,threshold,seed,nboot=2000):
    d=metrics(y,p,threshold);rng=np.random.default_rng(seed);boot={k:[] for k in d}
    for _ in range(nboot):
        idx=rng.integers(0,len(y),len(y));yy=y[idx];pp=p[idx]
        if yy.min()==yy.max():continue
        mm=metrics(yy,pp,threshold)
        for k,v in mm.items():
            if np.isfinite(v):boot[k].append(v)
    for k,a in boot.items():
        d[k+'_lo'],d[k+'_hi']=[float(v) for v in np.quantile(a,[.025,.975])]
    return d

def youden(y,p):
    fpr,tpr,t=roc_curve(y,p);valid=np.isfinite(t)&(t>0)&(t<1)
    ix=np.flatnonzero(valid)[np.argmax((tpr-fpr)[valid])]
    return float(t[ix])

def tune(pipe,grid,x,y,folds=5,seed=SEED):
    search=GridSearchCV(pipe,grid,scoring='neg_log_loss',cv=StratifiedKFold(folds,shuffle=True,random_state=seed),n_jobs=1,refit=True,error_score='raise',return_train_score=False)
    search.fit(x,y);return search

def netbenefit(y,p,t):
    pos=p[:,None]>=t[None,:]
    return (pos&(y[:,None]==1)).mean(axis=0)-(pos&(y[:,None]==0)).mean(axis=0)*t/(1-t)

def paired_delong(y,p1,p2):
    m=(y==1).sum();n=(y==0).sum();v10=[];v01=[]
    for p in [p1,p2]:
        a=p[y==1,None];b=p[y==0][None,:];v=(a>b).astype(float)+.5*(a==b)
        v10.append(v.mean(axis=1));v01.append(v.mean(axis=0))
    cov=np.cov(np.asarray(v10))/m+np.cov(np.asarray(v01))/n
    difference=float(np.mean(v10[0])-np.mean(v10[1]));variance=cov[0,0]+cov[1,1]-2*cov[0,1]
    return difference,float(2*norm.sf(abs(difference)/np.sqrt(variance)))

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--data-dir',type=Path,required=True);parser.add_argument('--out-dir',type=Path,required=True);args=parser.parse_args()
    out=args.out_dir;out.mkdir(parents=True,exist_ok=True);private=out/'private';private.mkdir(exist_ok=True)
    locate=lambda prefix:next(args.data_dir.rglob(prefix+'*.xlsx'))
    paths={'MIMIC-IV':locate('1_mimic_exclusion'),'eICU':locate('v4-table1_'),'Single-center':locate('v3-final_179')}
    frames={k:pd.read_excel(v,sheet_name='Modified_data' if k=='eICU' else 0) for k,v in paths.items()}
    x={k:clean(v) for k,v in frames.items()};y={k:v['inhospital_mortality'].to_numpy(dtype=int) for k,v in frames.items()}
    source=frames['MIMIC-IV'];mask=source['internal_split'].eq('development_80').to_numpy();assert mask.sum()==3724 and (~mask).sum()==902
    datasets={'Training':(x['MIMIC-IV'].loc[mask].reset_index(drop=True),y['MIMIC-IV'][mask]),'Internal validation':(x['MIMIC-IV'].loc[~mask].reset_index(drop=True),y['MIMIC-IV'][~mask]),'eICU':(x['eICU'],y['eICU']),'Single-center':(x['Single-center'],y['Single-center'])}
    xt,yt=datasets['Training'];nested=[];final={};oof={};params={};pred={};thresholds={}
    config={'seed':SEED,'primary_model':'LightGBM','selection_rationale':'Chosen for the revision in response to the calibration/overfitting critique; no claim of original prespecification or test-set selection.','source_split':{'development_80':int(mask.sum()),'internal_test_20':int((~mask).sum())},'feature_columns':FEATURES,'numeric_columns':NUM,'categorical_columns':CAT,'categorical_levels':dict(zip(CAT,CATEGORIES)),'SOFA_rule':'Recompute sum of the six stored organ-component scores in every cohort; not a reconstruction of standard SOFA from raw time-stamped measurements.','outer_cv':5,'inner_cv':3,'full_training_cv':5,'objective':'negative log loss','bootstrap':2000,'bootstrap_scope':'Conditional on fixed fitted models/predictions; does not repeat model fitting or recalibration within bootstrap.','versions':{'python':sys.version.split()[0],'numpy':np.__version__,'pandas':pd.__version__,'scipy':scipy.__version__,'scikit-learn':sklearn.__version__,'catboost':catboost.__version__,'lightgbm':lightgbm.__version__,'xgboost':xgboost.__version__},'input_sha256':{k:hashlib.sha256(v.read_bytes()).hexdigest() for k,v in paths.items()}}
    (out/'analysis_config.json').write_text(json.dumps(config,indent=2))
    print('DATA_LOADED', {k:{'n':len(yy),'deaths':int(yy.sum())} for k,(_,yy) in datasets.items()},flush=True)
    for name in ['LASSO','XGBoost','LightGBM','CatBoost','LightGBM_no_SOFA']:
        start=time.time();pipe,grid=definitions(name);oof[name]=np.zeros(len(yt));config.setdefault('search_grids',{})[name]=grid
        for fold,(tr,va) in enumerate(StratifiedKFold(5,shuffle=True,random_state=SEED).split(xt,yt),1):
            search=tune(pipe,grid,xt.iloc[tr],yt[tr],3,SEED+fold)
            p=search.predict_proba(xt.iloc[va])[:,1];oof[name][va]=p
            row={'model':name,'fold':fold,'n':len(va),'deaths':int(yt[va].sum()),**metrics(yt[va],p),'best_parameters':json.dumps(search.best_params_)};nested.append(row)
            print('NESTED',name,fold,'AUROC',round(row['AUROC'],4),'Brier',round(row['Brier'],4),flush=True)
        search=tune(pipe,grid,xt,yt,5);final[name]=search.best_estimator_;params[name]={'selected':search.best_params_,'all_fixed_parameters':final[name].named_steps['model'].get_params(),'best_cv_log_loss':float(-search.best_score_)}
        pd.DataFrame(search.cv_results_).to_csv(out/(name+'_tuning.csv'),index=False)
        thresholds[name]=youden(yt,oof[name]);pred[name]={key:final[name].predict_proba(xx)[:,1] for key,(xx,_) in datasets.items()}
        joblib.dump(final[name],private/(name+'.joblib'))
        print('FINAL',name,'seconds',round(time.time()-start),'parameters',search.best_params_,flush=True)
        pd.DataFrame(nested).to_csv(out/'nested_cv.csv',index=False)
        (out/'selected_hyperparameters.json').write_text(json.dumps(params,indent=2,default=str))
    # Score-only probability mapping is fitted on development data, without test recalibration.
    scorepipe=Pipeline([('preprocess',preprocess(score_only=True)),('model',LogisticRegression(penalty=None,max_iter=1000))])
    oof['SOFA_components_only']=cross_val_predict(scorepipe,xt,yt,cv=StratifiedKFold(5,shuffle=True,random_state=SEED),method='predict_proba')[:,1]
    scorepipe.fit(xt,yt);final['SOFA_components_only']=scorepipe;thresholds['SOFA_components_only']=youden(yt,oof['SOFA_components_only']);pred['SOFA_components_only']={key:scorepipe.predict_proba(xx)[:,1] for key,(xx,_) in datasets.items()}
    # A fixed-parameter class-weight sensitivity isolates the weighting choice.
    weighted=clone(final['LightGBM']);weighted.set_params(model__class_weight='balanced')
    oof['LightGBM_balanced']=cross_val_predict(weighted,xt,yt,cv=StratifiedKFold(5,shuffle=True,random_state=SEED),method='predict_proba')[:,1]
    weighted.fit(xt,yt);final['LightGBM_balanced']=weighted;thresholds['LightGBM_balanced']=youden(yt,oof['LightGBM_balanced']);pred['LightGBM_balanced']={key:weighted.predict_proba(xx)[:,1] for key,(xx,_) in datasets.items()}
    (out/'analysis_config.json').write_text(json.dumps(config,indent=2))
    (out/'thresholds.json').write_text(json.dumps(thresholds,indent=2))
    # Report nested development predictions separately from apparent fitted training values.
    records=[]
    for mi,(name,cohorts) in enumerate(pred.items()):
        for ci,(cohort,p) in enumerate(cohorts.items()):
            yy=datasets[cohort][1]
            mm=with_ci(yy,p,thresholds[name],SEED+mi*10+ci)
            records.append({'model':name,'cohort':cohort,'n':len(yy),'deaths':int(yy.sum()),'threshold':thresholds[name],**mm})
        print('BOOTSTRAP_COMPLETE',name,flush=True)
    pd.DataFrame(records).to_csv(out/'performance.csv',index=False)
    pd.DataFrame([{'model':name,'cohort':'Nested development OOF',**metrics(yt,p,thresholds[name])} for name,p in oof.items()]).to_csv(out/'oof_performance.csv',index=False)
    # Paired internal-test DeLong comparisons, with Holm adjustment over six pairs.
    names=['LASSO','XGBoost','LightGBM','CatBoost'];pairs=[];yy=datasets['Internal validation'][1]
    for i,a in enumerate(names):
        for b in names[i+1:]:
            diff,pv=paired_delong(yy,pred[a]['Internal validation'],pred[b]['Internal validation']);pairs.append({'model1':a,'model2':b,'AUROC_difference':diff,'p_raw':pv})
    order=np.argsort([r['p_raw'] for r in pairs]);prev=0
    for rank,j in enumerate(order):prev=max(prev,min(1,(len(pairs)-rank)*pairs[j]['p_raw']));pairs[j]['p_Holm']=prev
    pd.DataFrame(pairs).to_csv(out/'delong.csv',index=False)
    # Five-fold out-of-fold local recalibration; updating and evaluation observations are disjoint.
    recpred={};recrows=[];coeff=[]
    for ci,cohort in enumerate(['Internal validation','eICU','Single-center']):
        yy=datasets[cohort][1];base=pred['LightGBM'][cohort];z=logit(np.clip(base,1e-6,1-1e-6))
        for kind in ['intercept_only','intercept_and_slope']:
            pp=np.zeros(len(yy))
            for fold,(tr,va) in enumerate(StratifiedKFold(5,shuffle=True,random_state=SEED+100).split(z,yy),1):
                if kind=='intercept_only':
                    a=brentq(lambda a:np.sum(expit(a+z[tr])-yy[tr]),-30,30);b=1.
                else:a,b=calibration(yy[tr],base[tr])
                pp[va]=expit(a+b*z[va]);coeff.append({'cohort':cohort,'method':kind,'fold':fold,'intercept':a,'slope':b,'fitting_n':len(tr),'evaluation_n':len(va)})
            recpred[(cohort,kind)]=pp
            recrows.append({'cohort':cohort,'method':kind,'n':len(yy),**with_ci(yy,pp,thresholds['LightGBM'],SEED+1000+ci)})
    pd.DataFrame(recrows).to_csv(out/'recalibration.csv',index=False);pd.DataFrame(coeff).to_csv(out/'recalibration_coefficients.csv',index=False)
    # Patient-level prediction audit stays local; no identifier columns are exported.
    for cohort,(_,yy) in datasets.items():
        pd.DataFrame({'outcome':yy,**{name:values[cohort] for name,values in pred.items()}}).to_csv(private/(cohort.replace(' ','_')+'_predictions.csv'),index=False)
    # Aggregate plotting data for R only.
    rocrows=[];prrows=[];calrows=[];dcarows=[]
    for cohort in ['Internal validation','eICU','Single-center']:
        yy=datasets[cohort][1]
        plotseries={name:pred[name][cohort] for name in names+['SOFA_components_only','LightGBM_no_SOFA']}
        plotseries['LightGBM recalibrated']=recpred[(cohort,'intercept_and_slope')]
        for name,pp in plotseries.items():
            fpr,tpr,tt=roc_curve(yy,pp);rocrows.extend({'cohort':cohort,'model':name,'fpr':a,'tpr':b} for a,b in zip(fpr,tpr))
            precision,recall,_=precision_recall_curve(yy,pp);prrows.extend({'cohort':cohort,'model':name,'precision':a,'recall':b} for a,b in zip(precision,recall))
            # Equal-frequency bins use every evaluation observation and Wilson binomial intervals.
            bins=np.array_split(np.argsort(pp,kind='stable'),10)
            for j,idx in enumerate(bins,1):
                rate=yy[idx].mean();n=len(idx);center=(rate+1.96**2/(2*n))/(1+1.96**2/n);half=1.96*np.sqrt(rate*(1-rate)/n+1.96**2/(4*n*n))/(1+1.96**2/n)
                calrows.append({'cohort':cohort,'model':name,'bin':j,'n':n,'mean_prediction':float(pp[idx].mean()),'observed':float(rate),'lo':max(0,center-half),'hi':min(1,center+half)})
        ts=np.linspace(.05,.8,76);dseries={'LightGBM':pred['LightGBM'][cohort],'LightGBM recalibrated':recpred[(cohort,'intercept_and_slope')],'SOFA_components_only':pred['SOFA_components_only'][cohort]}
        rng=np.random.default_rng(SEED+2000);idxs=[rng.integers(0,len(yy),len(yy)) for _ in range(1000)]
        for name,pp in dseries.items():
            nb=netbenefit(yy,pp,ts);boot=np.vstack([netbenefit(yy[ix],pp[ix],ts) for ix in idxs]);lo,hi=np.quantile(boot,[.025,.975],axis=0)
            dcarows.extend({'cohort':cohort,'model':name,'threshold':float(t),'net_benefit':float(v),'lo':float(l),'hi':float(h)} for t,v,l,h in zip(ts,nb,lo,hi))
        prev=yy.mean()
        for t in ts:
            dcarows.extend([{'cohort':cohort,'model':'Treat all','threshold':float(t),'net_benefit':float(prev-(1-prev)*t/(1-t)),'lo':np.nan,'hi':np.nan},{'cohort':cohort,'model':'Treat none','threshold':float(t),'net_benefit':0.,'lo':np.nan,'hi':np.nan}])
    for filename,rows in [('roc',rocrows),('pr',prrows),('calibration_bins',calrows),('decision_curves',dcarows)]:pd.DataFrame(rows).to_csv(out/(filename+'.csv'),index=False)
    # Native TreeSHAP contributions, aggregated back to original predictor groups.
    importance=[];primary=final['LightGBM'];prep=primary.named_steps['preprocess'];features=prep.get_feature_names_out()
    for cohort in ['Internal validation','eICU','Single-center']:
        transformed=prep.transform(datasets[cohort][0]);sv=primary.named_steps['model'].booster_.predict(transformed,pred_contrib=True)[:,:-1];grouped=np.zeros((len(transformed),len(FEATURES)))
        for j,encoded in enumerate(features):
            en=encoded.split('__',1)[1]
            if en.startswith('missingindicator_'):base=en[len('missingindicator_'):]
            elif encoded.startswith('cat__'):base=next(c for c in CAT if en.startswith(c+'_'))
            else:base=en
            grouped[:,FEATURES.index(base)]+=sv[:,j]
        for feature,value in zip(FEATURES,np.abs(grouped).mean(axis=0)):importance.append({'cohort':cohort,'feature':feature,'mean_absolute_SHAP':float(value)})
    pd.DataFrame(importance).to_csv(out/'shap_importance.csv',index=False)
    # Score-version sensitivity changes only the single-center total used at prediction.
    legacy=datasets['Single-center'][0].copy();legacy['sofa_component_sum']=pd.to_numeric(frames['Single-center']['modified_sofa_24h']).to_numpy()
    plegacy=primary.predict_proba(legacy)[:,1]
    sens=[{'analysis':'Single-center archived total','cohort':'Single-center','n':179,**with_ci(y['Single-center'],plegacy,thresholds['LightGBM'],SEED+3000)}]
    # Timing sensitivity excludes only records whose stored hospital stay is <24 h.
    keep_train=pd.to_numeric(source.loc[mask,'hospital_los_days']).to_numpy()>=1
    timepipe=clone(primary);timepipe.fit(xt.loc[keep_train],yt[keep_train])
    for cohort,label,baseframe,select in [('Internal validation','MIMIC-IV',source,~mask),('eICU','eICU',frames['eICU'],np.ones(len(frames['eICU']),dtype=bool))]:
        xx,yy=datasets[cohort];keep=pd.to_numeric(baseframe.loc[select,'hospital_los_days']).to_numpy()>=1
        pp=timepipe.predict_proba(xx.loc[keep])[:,1];sens.append({'analysis':'Hospital stay at least 24 h sensitivity','cohort':cohort,'n':int(keep.sum()),**with_ci(yy[keep],pp,thresholds['LightGBM'],SEED+3100)})
    pd.DataFrame(sens).to_csv(out/'sensitivity.csv',index=False)
    # Descriptive feature and score audit, without changing original workbooks.
    miss=[];scoreaudit=[];baselines=[]
    for cohort,df in frames.items():
        xx=x[cohort];yy=y[cohort];old=pd.to_numeric(df['modified_sofa_24h']);new=xx['sofa_component_sum']
        scoreaudit.append({'cohort':cohort,'n':len(df),'changed_total_n':int((old.to_numpy()!=new.to_numpy()).sum()),'archived_median':float(old.median()),'archived_q25':float(old.quantile(.25)),'archived_q75':float(old.quantile(.75)),'recomputed_median':float(new.median()),'recomputed_q25':float(new.quantile(.25)),'recomputed_q75':float(new.quantile(.75))})
        subsets={'Overall':np.ones(len(df),bool)}
        if cohort=='MIMIC-IV':subsets.update({'Training':mask,'Internal validation':~mask})
        for subset,idx in subsets.items():
            for feature in FEATURES:
                a=xx.loc[idx,feature];miss.append({'cohort':cohort,'subset':subset,'feature':feature,'n':len(a),'missing_n':int(a.isna().sum()),'missing_pct':float(100*a.isna().mean())})
        for group,idx in [('Overall',np.ones(len(df),bool)),('Survivors',yy==0),('Deaths',yy==1)]:
            for feature in NUM:
                a=xx.loc[idx,feature].dropna();baselines.append({'cohort':cohort,'group':group,'feature':feature,'available_n':len(a),'median':float(a.median()),'q25':float(a.quantile(.25)),'q75':float(a.quantile(.75))})
    pd.DataFrame(miss).to_csv(out/'missingness.csv',index=False);pd.DataFrame(scoreaudit).to_csv(out/'score_audit.csv',index=False);pd.DataFrame(baselines).to_csv(out/'descriptive.csv',index=False)
    summary={'completed':True,'primary':'LightGBM','dataset_counts':{k:{'n':len(yy),'deaths':int(yy.sum())} for k,(_,yy) in datasets.items()},'threshold':thresholds['LightGBM'],'score_component_rule':COMP,'limitations':['No original screening SQL or raw time-stamped source measurements were supplied.','Stored organ-component provenance cannot be recovered solely from these cleaned workbooks.','Single-center 24-h landmark eligibility cannot be independently verified from the supplied fields.','No eICU hospital identifier was supplied; recalibration is cohort-specific, not hospital-specific.','The public code repository URL remains an author action.'],'versions':config['versions']}
    (out/'summary.json').write_text(json.dumps(summary,indent=2));print('ANALYSIS_COMPLETE',json.dumps(summary),flush=True)

if __name__=='__main__':main()
