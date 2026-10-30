#!/usr/bin/env python3
# Compile the actual production loop; no Dune or TaskSpace/Page calls.
from pathlib import Path
import argparse,tempfile,subprocess,socket,json,time,hashlib,shutil
p=argparse.ArgumentParser();p.add_argument('--source',type=Path,default=Path(__file__).resolve().parents[1]/'lib/browser_addon_live_ego.ml');p.add_argument('--output',type=Path,required=True);p.add_argument('--ego',action='store_true');p.add_argument('--observe-only',action='store_true');a=p.parse_args()
a.output.mkdir(parents=True,exist_ok=True)
found=shutil.which('ego-browser' if a.ego else 'node')
if found is None:raise SystemExit('required runtime is unavailable')
runtime_executable=Path(found).resolve()
runtime_hash=hashlib.sha256(runtime_executable.read_bytes()).hexdigest()
source=a.source.read_text();body=source[source.index('let session_loop ~socket ='):source.index('(* A started process:')]
with tempfile.TemporaryDirectory(prefix='ego-owner-') as tmp:
 root=Path(tmp);ml=root/'loop.ml';ml.write_text(body+'\nlet () = print_string (session_loop ~socket:Sys.argv.(1))\n')
 subprocess.run(['ocamlfind','ocamlc','-package','yojson','-linkpkg',str(ml),'-o',str(root/'emit')],check=True,stdout=subprocess.DEVNULL)
 results=[]
 for mode in ['idle_handles','pending_call','queued_after_owner_loss','owner_half_close','live_owner_pending']:
  d=root/mode;d.mkdir();ipc=d/'s';entered=d/'entered';late=d/'late'
  server=socket.socket(socket.AF_UNIX);server.bind(str(ipc));server.listen(1);server.settimeout(10)
  script=subprocess.check_output([str(root/'emit'),str(ipc)],text=True)
  command=[str(runtime_executable),'nodejs','-e',script] if a.ego else [str(runtime_executable),'--input-type=module','-e',script]
  log=(a.output/(mode+'.log')).open('w');child=subprocess.Popen(command,stdin=subprocess.DEVNULL,stdout=log,stderr=log)
  cleaned=False
  try:
   connection,_=server.accept();connection.settimeout(10)
   def send(id,code):connection.sendall((json.dumps({'id':id,'script':code})+'\n').encode())
   send(1,'setInterval(()=>{},1000); console.log("ready");')
   line=b''
   while not line.endswith(b'\n'):
    chunk=connection.recv(65536)
    if not chunk:raise RuntimeError('owner IPC ended before ready reply')
    line+=chunk
   assert json.loads(line)=={'id':1,'lines':['ready']}
   if mode!='idle_handles':
    wait='await new Promise(()=>{});' if mode=='pending_call' else 'await new Promise(resolve=>setTimeout(resolve,700));'
    call_started=time.monotonic()
    send(2,'await (await import("node:fs/promises")).writeFile('+json.dumps(str(entered))+',"entered");'+wait+'console.log("call-completed");')
    deadline=time.monotonic()+10
    while not entered.exists():
     assert child.poll() is None
     if time.monotonic()>deadline:raise RuntimeError('entry observation incomplete')
     time.sleep(.01)
    if mode=='queued_after_owner_loss':send(3,'await (await import("node:fs/promises")).writeFile('+json.dumps(str(late))+',"late effect");')
   live_owner_result=None;live_owner_elapsed=None
   if mode=='live_owner_pending':
    reply=b''
    while not reply.endswith(b'\n'):
     chunk=connection.recv(65536)
     if not chunk:raise RuntimeError('owner IPC ended before pending completion')
     reply+=chunk
    live_owner_result=json.loads(reply)
    assert live_owner_result=={'id':2,'lines':['call-completed']} and child.poll() is None
    live_owner_elapsed=time.monotonic()-call_started
   began=time.monotonic()
   connection.shutdown(socket.SHUT_WR if mode=='owner_half_close' else socket.SHUT_RDWR)
   if mode!='owner_half_close':connection.close()
   try:status=child.wait(timeout=1.5);running=False
   except subprocess.TimeoutExpired:status=None;running=child.poll() is None
   result={'case':mode,'runtime':'installed Ego nodejs' if a.ego else 'Node with simulated SDK handles','pid':child.pid,'observed_after_seconds':time.monotonic()-began,'exit_status':status,'still_running_after_owner_loss':running,'queued_effect_after_owner_loss':late.exists(),'scope':'actual extracted production session loop; no TaskSpace or Page APIs invoked'}
   result['live_owner_call_answered']=live_owner_result is not None
   result['live_owner_call_seconds']=live_owner_elapsed
   results.append(result)
   if mode=='owner_half_close':connection.close()
  finally:
   if child.poll() is None:child.terminate();child.wait(timeout=5);cleaned=True
   log.close();server.close()
   if results:results[-1]['owned_probe_process_terminated_for_cleanup']=cleaned
 (a.output/'results.json').write_text(json.dumps({'source_file':str(a.source),'source_sha256':hashlib.sha256(source.encode()).hexdigest(),'loop_sha256':hashlib.sha256(body.encode()).hexdigest(),'runtime_executable':str(runtime_executable),'runtime_executable_sha256':runtime_hash,'runtime_version':subprocess.check_output([str(runtime_executable),'--version'],text=True,stderr=subprocess.STDOUT).strip(),'assertions_enabled':not a.observe_only,'cases':results},indent=2)+'\n')
 if not a.observe_only:
  assert all(not r['still_running_after_owner_loss'] and not r['queued_effect_after_owner_loss'] and r['exit_status']==0 for r in results),results
  assert next(r for r in results if r['case']=='live_owner_pending')['live_owner_call_answered']
 print(json.dumps(results,indent=2))
