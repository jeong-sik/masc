from pathlib import Path
import json,os,sys,time,traceback,hashlib
root=Path('/Users/dancer/me/workspace/yousleepwhen/masc/.worktrees/fix-v0490-queue-fixture-20261004')
out=Path(__file__).parent
binary=Path('/tmp/masc-v0490-residual-fixtures-20261004/rc37142285007/masc-macos-arm64/masc-tui-macos-arm64')
os.environ['DYLD_LIBRARY_PATH']=str(binary.parent/'lib');os.environ['RUNNER_TEMP']=str(out)
sys.dont_write_bytecode=True;sys.path.insert(0,str(root/'test'))
import test_tui_remote_workspace_history_pty as m
p=root/'test/test_tui_remote_workspace_history_pty.py';digest=hashlib.sha256(p.read_bytes()).hexdigest()
original=m.h.run_terminal_scenario
rows=[]
def capture(*args,**kwargs):
 n=len(rows)+1;r={'description':kwargs['description'],'status':'running'};rows.append(r)
 f=kwargs['interact']
 def interact(proc,fd,slave,output,base):
  try:return f(proc,fd,slave,output,base)
  finally:
   (out/f'{n:02}.pty').write_bytes(output);(out/f'{n:02}.txt').write_bytes(m.h.screen_text(bytes(output)))
 kwargs['interact']=interact
 try:result=original(*args,**kwargs);r['status']='PASS';return result
 except Exception as ex:r['status']='FAIL';r['error']=str(ex).split(': b\'')[0][:1000];raise
 finally:(out/'scenarios.json').write_text(json.dumps(rows,indent=2)+'\n');print(n,r['description'],r['status'],flush=True)
m.h.run_terminal_scenario=capture
cases=[('queued_workspace_inputs',{}),('queued_workspace_inputs',{'root_only':True})]
for name,kw in cases:
 try:getattr(m,name)(str(binary),**kw)
 except Exception:traceback.print_exc()
assert hashlib.sha256(p.read_bytes()).hexdigest()==digest
result={'scope':'independent downstream diagnostic census, not official target PASS','script_sha256':digest,'binary_commit':'e4afdce8f0c4ba4cf02e4326ba423c4fe2207339','binary_sha256':hashlib.sha256(binary.read_bytes()).hexdigest(),'exit_code':int(any(r['status']!='PASS' for r in rows))}
(out/'manifest.json').write_text(json.dumps(result,indent=2)+'\n');sys.exit(result['exit_code'])
