"""Offline PostgreSQL AST/schema audit. No database driver, socket or connection.
Checks syntactic SELECT-only status, catalog relations/columns, derived CTE columns,
expected 22 outputs and a conservative PostgreSQL function inventory.
Static compatibility is not execution against the actual database installation.
"""
from pathlib import Path
import argparse,json,hashlib
from pglast import parse_sql,ast
ROOT=Path(__file__).resolve().parents[1]
SUPPORTED_FUNCTIONS={'avg','min','max','sum','count','bool_and','row_number','lag','lead','ceil','ceiling','round','to_char','to_timestamp','date_trunc','date_part','extract','unnest','generate_series','concat_ws','string_agg','lower','upper','trim','btrim','replace','substring','substr','power','length','abs','coalesce','greatest','least','nullif','regexp_replace'}
def walk(value):
 if isinstance(value,ast.Node):
  yield value
  for name in value.__slots__:yield from walk(getattr(value,name,None))
 elif isinstance(value,(tuple,list)):
  for item in value:yield from walk(item)
def sval(x):return x.sval if isinstance(x,ast.String) else str(x)
def catalog():
 result={}
 for file in ['mimic_schema.sql','eicu_schema.sql']:
  for raw in parse_sql((ROOT/'tests'/file).read_text()):
   node=raw.stmt
   if isinstance(node,ast.CreateStmt):
    schema=node.relation.schemaname or 'eicu_crd'
    result[(schema,node.relation.relname)]={c.colname for c in node.tableElts if isinstance(c,ast.ColumnDef)}
 return result
class Audit:
 def __init__(self,source):self.source=source;self.errors=[];self.warnings=[];self.references=0;self.tables=set();self.cat=catalog()
 def issue(self,code,detail,node=None):
  loc=getattr(node,'location',None);line=self.source.encode()[:loc].count(b'\n')+1 if loc is not None and loc>=0 else None
  self.errors.append({'code':code,'detail':detail,'line':line})
 def expr(self,obj,env,ctes,outputs=None):
  if isinstance(obj,ast.SelectStmt):self.select(obj,ctes,env);return
  if isinstance(obj,ast.ColumnRef):
   fields=[sval(f) for f in obj.fields if not isinstance(f,ast.A_Star)]
   if not fields:return
   self.references+=1
   if len(fields)>=2:
    alias,col=fields[-2:]
    if alias not in env:self.issue('UNKNOWN_ALIAS','.'.join(fields),obj)
    elif env[alias] is not None and col not in env[alias]:self.issue('UNKNOWN_COLUMN','.'.join(fields),obj)
   else:
    col=fields[0]
    if col not in (outputs or set()) and not any(cols is None or col in cols for cols in env.values()):self.issue('UNKNOWN_UNQUALIFIED_COLUMN',col,obj)
   return
  if isinstance(obj,ast.Node):
   for name in obj.__slots__:self.expr(getattr(obj,name,None),env,ctes,outputs)
  elif isinstance(obj,(tuple,list)):
   for item in obj:self.expr(item,env,ctes,outputs)
 def relation(self,node,ctes,env):
  if isinstance(node,ast.RangeVar):
   key=(node.schemaname,node.relname)
   if node.schemaname:
    self.tables.add('.'.join(key));cols=self.cat.get(key)
    if cols is None:self.issue('UNKNOWN_SOURCE_TABLE','.'.join(key),node)
   elif node.relname in ctes:cols=ctes[node.relname]
   else:cols=None;self.issue('UNKNOWN_CTE_OR_TABLE',node.relname,node)
   alias=node.alias.aliasname if node.alias else node.relname
   if node.alias and node.alias.colnames:cols={sval(c) for c in node.alias.colnames}
   return {alias:cols}
  if isinstance(node,ast.RangeSubselect):
   cols=self.select(node.subquery,ctes,env)
   alias=node.alias.aliasname if node.alias else '_subquery'
   if node.alias and node.alias.colnames:cols={sval(c) for c in node.alias.colnames}
   return {alias:cols}
  if isinstance(node,ast.JoinExpr):
   left=self.relation(node.larg,ctes,env);right=self.relation(node.rarg,ctes,{**env,**left})
   full={**env,**left,**right};self.expr(node.quals,full,ctes)
   for f in node.usingClause or ():
    col=sval(f)
    if not any(c is None or col in c for c in left.values()):self.issue('USING_COLUMN_MISSING_LEFT',col,node)
    if not any(c is None or col in c for c in right.values()):self.issue('USING_COLUMN_MISSING_RIGHT',col,node)
   if node.alias:
    allcols=set().union(*(c or set() for c in [*left.values(),*right.values()]))
    return {node.alias.aliasname:allcols}
   return {**left,**right}
  if isinstance(node,ast.RangeFunction):
   self.expr(node.functions,env,ctes)
   if node.alias:
    return {node.alias.aliasname:{sval(c) for c in node.alias.colnames} if node.alias.colnames else None}
   return {'_function':None}
  self.issue('UNSUPPORTED_FROM_NODE',type(node).__name__,node);return {}
 def target_name(self,node):
  if isinstance(node,ast.ColumnRef):return sval(node.fields[-1])
  if isinstance(node,ast.TypeCast):return self.target_name(node.arg)
  if isinstance(node,ast.FuncCall):return sval(node.funcname[-1])
  if isinstance(node,ast.CoalesceExpr):return 'coalesce'
  return '?column?'
 def select(self,node,ctes=None,outer=None):
  ctes=dict(ctes or {});env=dict(outer or {})
  if node.withClause:
   for cte in node.withClause.ctes:
    cols=self.select(cte.ctequery,ctes,env)
    if cte.aliascolnames:cols={sval(c) for c in cte.aliascolnames}
    ctes[cte.ctename]=cols
  if node.larg is not None:
   left=self.select(node.larg,ctes,env);self.select(node.rarg,ctes,env)
   self.expr(node.sortClause,env,ctes,left);return left
  if node.valuesLists:return {'column'+str(i+1) for i in range(len(node.valuesLists[0]))}
  local={}
  for rel in node.fromClause or ():local.update(self.relation(rel,ctes,{**env,**local}))
  env.update(local);outputs=set()
  for target in node.targetList or ():
   value=target.val
   if isinstance(value,ast.ColumnRef) and any(isinstance(f,ast.A_Star) for f in value.fields):
    names=[sval(f) for f in value.fields if not isinstance(f,ast.A_Star)]
    aliases=[names[-1]] if names else list(local)
    for alias in aliases:
     if alias not in env:self.issue('UNKNOWN_STAR_ALIAS',alias,value)
     elif env[alias] is None:self.warnings.append('Unknown output columns for star '+alias)
     else:outputs.update(env[alias])
   else:self.expr(value,env,ctes);outputs.add(target.name or self.target_name(value))
  for name in ['whereClause','groupClause','havingClause','windowClause','limitOffset','limitCount']:self.expr(getattr(node,name,None),env,ctes,outputs)
  self.expr(node.sortClause,env,ctes,outputs)
  return outputs
 def run(self):
  stmts=parse_sql(self.source)
  if len(stmts)!=1 or not isinstance(stmts[0].stmt,ast.SelectStmt):self.issue('NOT_SINGLE_SELECT','Shipping SQL must be one SELECT');return {}
  for node in walk(stmts[0].stmt):
   if isinstance(node,(ast.InsertStmt,ast.UpdateStmt,ast.DeleteStmt)) or (isinstance(node,ast.SelectStmt) and node.intoClause is not None):self.issue('WRITE_OR_SELECT_INTO','Only read-only SELECT constructs are permitted',node)
  outputs=self.select(stmts[0].stmt)
  functions=sorted({sval(n.funcname[-1]).lower() for n in walk(stmts[0].stmt) if isinstance(n,ast.FuncCall)})
  for f in functions:
   if f not in SUPPORTED_FUNCTIONS:self.warnings.append('Function requires manual version review: '+f)
  return {'outputs':sorted(outputs),'functions':functions,'source_tables':sorted(self.tables),'column_references_checked':self.references,'errors':self.errors,'warnings':sorted(set(self.warnings))}
def main():
 p=argparse.ArgumentParser();p.add_argument('--out',type=Path,default=ROOT/'validation/static_sql_audit.json');args=p.parse_args();results=[]
 for path in sorted((ROOT/'sql').glob('*.sql')):
  a=Audit(path.read_text());result=a.run()
  if path.name.startswith(('03_','04_')):
   expected=set(json.loads((ROOT/'analysis/analysis_config.json').read_text())['feature_columns'])
   missing=expected-set(result['outputs'])
   if missing:a.issue('MISSING_PREDICTOR_OUTPUT',','.join(sorted(missing)))
   result['expected_predictor_count']=len(expected);result['predictor_outputs_present']=len(expected-missing)
  result.update(file=path.name,sql_sha256=hashlib.sha256(path.read_bytes()).hexdigest(),status='PASS_STATIC' if not a.errors else 'FAIL_STATIC');results.append(result)
 report={'audit_type':'OFFLINE_STATIC_ONLY_NO_DATABASE_CONNECTION','target_engine':'PostgreSQL 14+ syntax/features; no actual installation compatibility claim','database_versions_from_manuscript':{'mimic':'2.2','eicu':'2.0'},'catalog_source':'bundled MIT-LCP official DDL snapshots; installation/version must be verified in a future authorized run','source_database_validation':'未经数据库验证 / NOT VALIDATED','results':results}
 args.out.parent.mkdir(parents=True,exist_ok=True);args.out.write_text(json.dumps(report,indent=2));print(json.dumps({'queries':len(results),'static_errors':sum(len(x['errors']) for x in results),'static_warnings':sum(len(x['warnings']) for x in results)},indent=2))
 if any(x['errors'] for x in results):raise SystemExit(2)
if __name__=='__main__':main()
