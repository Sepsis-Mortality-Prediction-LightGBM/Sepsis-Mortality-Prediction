"""Paired, fixed-prediction sensitivity contrasts for the revision analysis."""
from pathlib import Path
import argparse
import numpy as np,pandas as pd
from sklearn.metrics import roc_auc_score,average_precision_score,brier_score_loss
from reanalyse import paired_delong,SEED

def run(out):
    rows=[]
    for cohort in ['Internal validation','eICU','Single-center']:
        d=pd.read_csv(out/'private'/(cohort.replace(' ','_')+'_predictions.csv'));y=d.outcome.to_numpy(dtype=int);p=d.LightGBM.to_numpy()
        for comparator in ['SOFA_components_only','LightGBM_no_SOFA','CatBoost']:
            q=d[comparator].to_numpy();diff,pv=paired_delong(y,p,q);rng=np.random.default_rng(SEED+5000)
            funcs={'AUROC':roc_auc_score,'AUPRC':average_precision_score,'Brier':brier_score_loss};r={'cohort':cohort,'primary':'LightGBM','comparator':comparator,'DeLong_p':pv}
            for name,fun in funcs.items():
                boot=[]
                for _ in range(2000):
                    ix=rng.integers(0,len(y),len(y));yy=y[ix]
                    if yy.min()==yy.max():continue
                    boot.append(fun(yy,p[ix])-fun(yy,q[ix]))
                r[name+'_difference']=fun(y,p)-fun(y,q);r[name+'_lo'],r[name+'_hi']=np.quantile(boot,[.025,.975])
            rows.append(r)
    order=np.argsort([r['DeLong_p'] for r in rows]);prev=0
    for rank,j in enumerate(order):prev=max(prev,min(1,(len(rows)-rank)*rows[j]['DeLong_p']));rows[j]['DeLong_Holm_9']=prev
    pd.DataFrame(rows).to_csv(out/'paired_contrasts.csv',index=False)
    dca=pd.read_csv(out/'decision_curves.csv')
    dca[np.isclose(dca.threshold,.10)|np.isclose(dca.threshold,.20)|np.isclose(dca.threshold,.30)|np.isclose(dca.threshold,.50)].to_csv(out/'decision_curve_selected_thresholds.csv',index=False)
    print(pd.DataFrame(rows)[['cohort','comparator','AUROC_difference','AUROC_lo','AUROC_hi','DeLong_p','DeLong_Holm_9','Brier_difference','Brier_lo','Brier_hi']].round(5).to_string(index=False))

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--out-dir',type=Path,required=True);run(p.parse_args().out_dir)
