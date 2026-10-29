# R-only figure drawing for the reproducible revision analysis.
# All quantitative inputs are aggregate outputs from reanalyse.py.
args <- commandArgs(trailingOnly=TRUE)
data_dir <- args[1]
out_dir <- args[2]
format <- if(length(args)>=3) args[3] else 'all'
dir.create(out_dir, showWarnings=FALSE, recursive=TRUE)
read <- function(name) read.csv(file.path(data_dir, paste0(name, '.csv')), check.names=FALSE)
perf <- read('performance')
roc <- read('roc'); pr <- read('pr'); cal <- read('calibration_bins')
dca <- read('decision_curves'); shap <- read('shap_importance')
nested <- read('nested_cv'); recal <- read('recalibration'); sens <- read('sensitivity')
cohorts <- c('Internal validation','eICU','Single-center')
cohort_titles <- c('Internal validation  n = 902','eICU  n = 1,057','Single center  n = 179')
models <- c('LASSO','XGBoost','LightGBM','CatBoost','SOFA_components_only')
colors <- c(LASSO='#6F747C', XGBoost='#9B85B4', LightGBM='#3B6C9E', CatBoost='#CA9B52', SOFA_components_only='#303030', LightGBM_no_SOFA='#5C9C92', LightGBM_balanced='#B4707C', 'LightGBM recalibrated'='#5C9C92', 'Treat all'='#9B866B', 'Treat none'='#333333')
labels <- c(LASSO='LASSO', XGBoost='XGBoost', LightGBM='LightGBM', CatBoost='CatBoost', SOFA_components_only='Component score', LightGBM_no_SOFA='Without score', LightGBM_balanced='Class weighted', 'LightGBM recalibrated'='Recalibrated OOF')
style <- function(mar=c(3.1,3.1,2.0,0.7)) par(family='sans', las=1, cex=0.80, cex.axis=0.84, cex.lab=0.92, cex.main=0.92, mgp=c(1.9,.5,0), tcl=-.22, bty='l', lend=1, mar=mar)
panel <- function(letter) mtext(letter, side=3, line=.55, adj=-.15, font=2, cex=1.15)
save_pub <- function(name, draw, width_mm=183, height_mm=120, dpi=600) {
  w <- width_mm/25.4; h <- height_mm/25.4
  if(format %in% c('svg','all')) {svglite::svglite(file.path(out_dir,paste0(name,'.svg')),width=w,height=h);draw();dev.off()}
  if(format %in% c('pdf','all')) {grDevices::cairo_pdf(file.path(out_dir,paste0(name,'.pdf')),width=w,height=h,family='Arial');draw();dev.off()}
  if(format %in% c('png','all')) {png(file.path(out_dir,paste0(name,'.png')),width=w,height=h,units='in',res=dpi,type='cairo',bg='white');draw();dev.off()}
  if(format %in% c('tiff','all')) {tiff(file.path(out_dir,paste0(name,'.tiff')),width=w,height=h,units='in',res=dpi,type='cairo',compression='lzw',bg='white');draw();dev.off()}
}

# Contract Figure 1: show exactly which data, preprocessing and evaluation support the revision.
draw_workflow <- function() {
  style(c(.3,.3,.3,.3)); plot.new(); plot.window(c(0,1),c(0,1),xaxs='i',yaxs='i')
  boxtext <- function(x1,y1,x2,y2,txt,fill='#F1F4F7',cex=.9) {rect(x1,y1,x2,y2,col=fill,border='#8B98A8',lwd=.8);text((x1+x2)/2,(y1+y2)/2,txt,cex=cex)}
  text(.02,.98,'Study design and analytical workflow',adj=c(0,1),font=2,cex=1.25)
  boxtext(.04,.75,.40,.9,'MIMIC-IV  n = 4,626\nDevelopment  n = 3,724\nInternal test  n = 902')
  boxtext(.60,.75,.96,.9,'Independent populations\neICU  n = 1,057\nSingle center  n = 179')
  boxtext(.04,.54,.96,.69,'Data from the first 24 h after ICU admission\n22 predictors  |  Six stored organ scores summed consistently\nMedian imputation, missing indicators, scaling and encoding fitted inside training folds')
  arrows(.22,.75,.22,.70,length=.06);arrows(.78,.75,.78,.70,length=.06)
  boxtext(.04,.32,.49,.48,'Development set only\nNested stratified CV: 5 outer x 3 inner folds\nFinal tuning: 5 folds; objective: log loss\nLASSO, XGBoost, LightGBM, CatBoost')
  boxtext(.54,.32,.96,.48,'Primary model  LightGBM\nFrozen model evaluated in held-out cohorts\nAUROC, AUPRC, Brier and calibration\nExploratory decision curves')
  arrows(.30,.54,.30,.49,length=.06);arrows(.72,.54,.72,.49,length=.06);arrows(.49,.40,.535,.40,length=.05)
  boxtext(.04,.10,.96,.25,'Robustness and updating\nScore-only reference; score ablation; class weighting; score-version and timing sensitivity\nFive-fold OOF local recalibration; native TreeSHAP\nIndependent populations retain different sepsis ascertainment',fill='#EEF4F2')
  arrows(.30,.32,.30,.26,length=.06);arrows(.72,.32,.72,.26,length=.06)
}
save_pub('Figure_1_workflow',draw_workflow,183,150)

# Contract Figure 2: discriminate mortality; PR curves retain prevalence references.
draw_discrimination <- function() {
  par(mfrow=c(2,3)); letters <- letters[1:6]
  for (j in 1:3) {
    style(); plot(c(0,1),c(0,1),type='n',xlab='False-positive rate',ylab=if(j==1)'True-positive rate' else '',main=cohort_titles[j],xaxs='i',yaxs='i'); abline(0,1,col='#D0D0D0',lty=2)
    for (m in models) {dd<-subset(roc,cohort==cohorts[j]&model==m);lines(dd$fpr,dd$tpr,col=colors[m],lwd=if(m=='LightGBM')1.7 else 1,lty=if(m=='SOFA_components_only')2 else 1)}
    vals <- sapply(models,function(m) subset(perf,cohort==cohorts[j]&model==m)$AUROC)
    legend('bottomright',legend=paste0(labels[models],'  ',sprintf('%.3f',vals)),col=colors[models],lty=c(1,1,1,1,2),lwd=c(1,1,1.7,1,1),bty='n',cex=.66,inset=.02)
    panel(letters[j])
  }
  for (j in 1:3) {
    style(); plot(c(0,1),c(0,1),type='n',xlab='Recall',ylab=if(j==1)'Precision' else '',xaxs='i',yaxs='i')
    row<-subset(perf,cohort==cohorts[j]&model=='LightGBM');abline(h=row$deaths/row$n,col='#B8B8B8',lty=3)
    for (m in models) {dd<-subset(pr,cohort==cohorts[j]&model==m);lines(dd$recall,dd$precision,col=colors[m],lwd=if(m=='LightGBM')1.7 else 1,lty=if(m=='SOFA_components_only')2 else 1)}
    vals <- sapply(models,function(m) subset(perf,cohort==cohorts[j]&model==m)$AUPRC)
    legend('bottomleft',legend=paste0(labels[models],'  ',sprintf('%.3f',vals)),col=colors[models],lty=c(1,1,1,1,2),lwd=c(1,1,1.7,1,1),bty='n',cex=.66,inset=.02)
    panel(letters[j+3])
  }
}
save_pub('Figure_2_discrimination',draw_discrimination,183,145)

# Contract Figure 3: show raw and independently evaluated local probability agreement.
draw_calibration <- function() {
  par(mfrow=c(1,3))
  for (j in 1:3) {
    style();plot(c(0,1),c(0,1),type='n',xlab='Mean predicted probability',ylab=if(j==1)'Observed mortality' else '',main=cohort_titles[j],xaxs='i',yaxs='i');abline(0,1,col='#A0A0A0',lty=2)
    for (m in c('SOFA_components_only','LightGBM','LightGBM recalibrated')) {
      dd<-subset(cal,cohort==cohorts[j]&model==m)
      arrows(dd$mean_prediction,dd$lo,dd$mean_prediction,dd$hi,angle=90,code=3,length=.018,col=adjustcolor(colors[m],.45),lwd=.65)
      lines(dd$mean_prediction,dd$observed,col=colors[m],lwd=1.2,type='o',pch=if(m=='LightGBM')16 else 1,cex=.5)
    }
    row<-subset(perf,cohort==cohorts[j]&model=='LightGBM')
    legend('bottomright',legend=c('LightGBM','Recalibrated OOF','Component score',sprintf('Raw intercept %.2f',row$cal_intercept),sprintf('Raw slope %.2f',row$cal_slope)),col=c(colors[c('LightGBM','LightGBM recalibrated','SOFA_components_only')],NA,NA),lty=c(1,1,1,0,0),bty='n',cex=.68)
    panel(letters[j])
  }
}
save_pub('Figure_3_calibration',draw_calibration,183,85)

# Contract Figure 4: net benefit is exploratory and threshold dependent.
draw_dca <- function() {
  par(mfrow=c(1,3))
  for (j in 1:3) {
    dd<-subset(dca,cohort==cohorts[j]);upper<-max(.36,max(dd$net_benefit))+.02
    style();plot(c(.05,.8),c(-.10,upper),type='n',xlab='Threshold probability',ylab=if(j==1)'Net benefit' else '',main=cohort_titles[j],xaxs='i',yaxs='i')
    pp<-subset(dd,model=='LightGBM');polygon(c(pp$threshold,rev(pp$threshold)),c(pp$lo,rev(pp$hi)),col=adjustcolor(colors['LightGBM'],.14),border=NA)
    for (m in c('Treat all','Treat none','SOFA_components_only','LightGBM','LightGBM recalibrated')) {p<-subset(dd,model==m);lines(p$threshold,p$net_benefit,col=colors[m],lty=if(m %in% c('Treat all','Treat none'))2 else 1,lwd=if(m=='LightGBM')1.6 else 1)}
    legend('topright',legend=c('LightGBM','Recalibrated OOF','Component score','Treat all','Treat none'),col=colors[c('LightGBM','LightGBM recalibrated','SOFA_components_only','Treat all','Treat none')],lty=c(1,1,1,2,2),bty='n',cex=.65)
    panel(letters[j])
  }
}
save_pub('Figure_4_decision_curves',draw_dca,183,85)

feature_names <- c(age='Age',bmi_model='BMI',charlson_comorbidity_index='Comorbidity index',heart_rate_24h_mean='Heart rate',map_24h_mean='MAP',urine_output_24h_mean='Urine output',lactate_24h_mean='Lactate',creatinine_24h_mean='Creatinine',glucose_24h_mean='Glucose',inr_24h_mean='INR',mechanical_ventilation_24h='Ventilation',vasopressor_24h='Vasopressor',rrt_24h='RRT',antibiotic_24h='Antibiotic',fluid_resuscitation_24h_ml='Fluid volume',lactate_24h_delta='Lactate change',map_24h_delta='MAP change',urine_output_24h_delta='Urine-output change',sofa_component_sum='Component score',sex='Sex',admission_source='Admission source',infection_source='Infection source')
# Contract Figure 5: describe the primary model, without causal interpretation.
draw_shap <- function() {
  par(mfrow=c(1,3))
  for (j in 1:3) {
    dd<-subset(shap,cohort==cohorts[j]);dd<-head(dd[order(-dd$mean_absolute_SHAP),],10);dd<-dd[nrow(dd):1,]
    style(c(3.1,6.0,2.0,.5));barplot(dd$mean_absolute_SHAP,names.arg=feature_names[dd$feature],horiz=TRUE,col=colors['LightGBM'],border=NA,las=1,xlab='Mean absolute SHAP value',main=cohort_titles[j],cex.names=.70,space=.35,xlim=c(0,max(shap$mean_absolute_SHAP)*1.07))
    mtext(letters[j],side=3,line=.55,adj=-.60,font=2,cex=1.15)
  }
}
save_pub('Figure_5_SHAP',draw_shap,183,105)

# Contract Figure 6: quantify robustness; do not disguise fold variability as independent replicates.
draw_robustness <- function() {
  set.seed(20261021)
  par(mfrow=c(2,2))
  style(c(3.1,4.3,2.0,.5));par(mgp=c(2.9,.55,0));dd<-subset(nested,model %in% c('LASSO','XGBoost','LightGBM','CatBoost'));dd$model<-factor(dd$model,levels=c('LASSO','XGBoost','LightGBM','CatBoost'))
  boxplot(Brier~model,data=dd,col=adjustcolor(colors[levels(dd$model)],.45),border='#555555',outline=FALSE,ylab='Outer-fold Brier score',xlab='',main='Nested cross-validation',cex.axis=.8)
  stripchart(Brier~model,data=dd,vertical=TRUE,method='jitter',pch=16,cex=.5,add=TRUE,col='#444444');panel('a')
  style(c(3.1,5.1,2.0,.5));plot(c(.45,1),c(.5,6.5),type='n',xlab='AUROC with 95% CI',ylab='',yaxt='n',main='Score ablation')
  at<-c(6,4,2)
  for(j in 1:3) for(k in 1:2) {m<-c('LightGBM','LightGBM_no_SOFA')[k];r<-subset(perf,cohort==cohorts[j]&model==m);pos<-at[j]-.5*(k-1);segments(r$AUROC_lo,pos,r$AUROC_hi,pos,col=colors[m]);points(r$AUROC,pos,pch=if(k==1)16 else 17,col=colors[m],cex=.8)}
  axis(2,at=at-.25,labels=c('Internal','eICU','Single center'),tick=FALSE,cex.axis=.8);legend('bottomright',legend=c('With component score','Without score'),pch=c(16,17),col=colors[c('LightGBM','LightGBM_no_SOFA')],bty='n',cex=.7);panel('b')
  style();vals<-sapply(c('LightGBM','LightGBM_balanced'),function(m)sapply(cohorts,function(co)subset(perf,model==m&cohort==co)$AUPRC));barplot(t(vals),beside=TRUE,col=colors[c('LightGBM','LightGBM_balanced')],border=NA,names.arg=c('Internal','eICU','Single center'),ylim=c(0,1),ylab='AUPRC',main='Class-weight sensitivity');legend('topleft',legend=c('Unweighted','Balanced weights'),fill=colors[c('LightGBM','LightGBM_balanced')],bty='n',cex=.7);panel('c')
  style();rr<-subset(perf,model=='LightGBM'&cohort=='Single-center');ss<-subset(sens,analysis=='Single-center archived total')
  values<-rbind(c(rr$AUROC,ss$AUROC),c(rr$Brier,ss$Brier));barplot(values,beside=TRUE,col=c('#3B6C9E','#9BB8D3'),border=NA,names.arg=c('Recomputed sum','Archived total'),ylim=c(0,1),ylab='Metric value',main='Single-center score version');legend('topleft',legend=c('AUROC','Brier score'),fill=c('#3B6C9E','#9BB8D3'),bty='n',cex=.7);panel('d')
}
save_pub('Figure_6_robustness',draw_robustness,183,145)
writeLines(capture.output(sessionInfo()),file.path(out_dir,'R_sessionInfo.txt'))
cat('R_FIGURES_COMPLETE\n')
