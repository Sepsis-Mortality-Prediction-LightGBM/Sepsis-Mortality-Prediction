"""Offline-only validation; any socket creation is rejected during the checks."""
from pathlib import Path
import sys,json,unittest,subprocess,hashlib,socket
from unittest import mock
ROOT=Path(__file__).resolve().parents[1]
if str(ROOT/'scripts') not in sys.path:sys.path.insert(0,str(ROOT/'scripts'))
from static_sql_audit import Audit
attempts=[]
def deny_socket(*args,**kwargs):
 attempts.append('socket_attempt_blocked');raise RuntimeError('Offline checks prohibit all socket/database connections')
results=[]
with mock.patch('socket.socket',side_effect=deny_socket),mock.patch('socket.create_connection',side_effect=deny_socket):
 for file in sorted((ROOT/'sql').glob('*.sql')):
  result=Audit(file.read_text()).run();results.append({'file':file.name,'errors':result['errors'],'warnings':result['warnings'],'column_references_checked':result['column_references_checked'],'sql_sha256':hashlib.sha256(file.read_bytes()).hexdigest()})
 suite=unittest.defaultTestLoader.discover(str(ROOT/'tests/offline'),pattern='test_*.py')
 result=unittest.TextTestRunner(verbosity=2).run(suite)
report={'run_mode':'OFFLINE_ONLY','source_database_validation':'未经数据库验证 / NOT VALIDATED','tests_run':result.testsRun,'tests_passed':result.wasSuccessful(),'socket_attempts_blocked':len(attempts),'database_connections_permitted':False,'sql_static_checks':results,'real_source_data_reextracted':False}
(ROOT/'validation').mkdir(exist_ok=True);(ROOT/'validation/offline_checks_20261025.json').write_text(json.dumps(report,indent=2))
if not result.wasSuccessful() or attempts or any(x['errors'] for x in results):raise SystemExit(2)
print('Offline checks passed. No database connection was attempted.')
