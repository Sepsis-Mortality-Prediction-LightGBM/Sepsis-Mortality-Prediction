"""Explicit encoding normalization only; does not infer absent treatment from missing data."""
import pandas as pd,numpy as np
BINARY_COLUMNS=['mechanical_ventilation_24h','vasopressor_24h','rrt_24h','antibiotic_24h']
def normalize_binary(series):
 yes={'1','1.0','yes','y','true','t'};no={'0','0.0','no','n','false','f'};missing={'','unknown','not recorded','na','n/a','nan','none','<na>'}
 def convert(v):
  if pd.isna(v):return np.nan
  text=str(v).strip().lower()
  if text in yes:return 1.0
  if text in no:return 0.0
  if text in missing:return np.nan
  raise ValueError('Unrecognized binary treatment encoding; review source field')
 return series.map(convert).astype(float)
