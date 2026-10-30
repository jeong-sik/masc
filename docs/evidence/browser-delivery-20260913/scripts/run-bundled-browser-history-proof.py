import argparse, hashlib, json, os, pathlib, signal, socket, subprocess, time, urllib.request
p=argparse.ArgumentParser()
p.add_argument('--runtime-dir',type=pathlib.Path,required=True)
p.add_argument('--source-commit',required=True)
p.add_argument('--preflight-only',action='store_true')
p.add_argument('--root',type=pathlib.Path,required=True)
p.add_argument('--evidence',type=pathlib.Path,required=True)
p.add_argument('--checkout',type=pathlib.Path,required=True)
a=p.parse_args()
root=a.root.resolve()
assert root==pathlib.Path('/var/folders/bv/cjrbl01x52s6j80krdfb63400000gp/T/masc-browser-handoff-yq3d680h').resolve(), 'only the owned scratch runtime is allowed'
assert a.evidence.resolve().parent==root
out=root/('history-runtime-'+str(time.time_ns()));out.mkdir()
server=a.runtime_dir.resolve()/'masc-macos-arm64'
tui=a.runtime_dir.resolve()/'masc-tui-macos-arm64'
env={k:v for k,v in os.environ.items() if k in ('HOME','PATH','LANG','LC_ALL','TMPDIR','USER','LOGNAME','SHELL')}
env['MASC_IMESSAGE_CHAT_DB_PATH']=str(root/'absent-message-fixture.db')
with socket.socket() as sock:
 sock.bind(('127.0.0.1',0));port=sock.getsockname()[1]
token=json.loads((root/'login-private.json').read_text())['bearer_token']
opener=urllib.request.build_opener(urllib.request.ProxyHandler({}))
def get(path):
 req=urllib.request.Request(f'http://127.0.0.1:{port}'+path,headers={'Authorization':'Bearer '+token})
 with opener.open(req,timeout=3) as response:return json.load(response)
report={'source_commit':a.source_commit,'server_sha256':hashlib.sha256(server.read_bytes()).hexdigest(),
 'tui_sha256':hashlib.sha256(tui.read_bytes()).hexdigest(),'port':port,'producer_evidence':str(a.evidence.resolve()),'scope':'owned scratch runtime; saved observation reader with no browser process'}
proc=None
try:
 with (out/'server.log').open('wb') as log:
  proc=subprocess.Popen([str(server),'start','--base-path',str(root),'--host','127.0.0.1','--port',str(port)],cwd=root,env=env,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
  deadline=time.monotonic()+60
  while True:
   assert proc.poll() is None,'owned server exited before readiness'
   try:
    health=get('/health?full=1')
    clients=get('/api/v1/dashboard/browser-lane/clients')
    if clients.get('ok') is True:break
   except (OSError,ValueError):pass
   assert time.monotonic()<deadline,'owned server startup deadline exceeded'
   time.sleep(.2)
  assert pathlib.Path(health['paths']['effective_base_path']).resolve()==root.resolve()
  assert health['build']['binary_commit']==a.source_commit
  assert health['build']['executable_sha256']==report['server_sha256']
  assert clients['data']['clients']==[],'scratch root has a connected browser'
  report['health_build']=health['build'];report['clients']=clients
  prior=json.loads((a.evidence/'report.json').read_text())
  assert prior['build']['binary_commit']==a.source_commit, 'producer source differs'
  keeper=prior['keeper'];report['keeper']=keeper
  rows=get('/api/v1/keepers/'+keeper+'/tool-calls?limit=100')
  (out/'tool-calls.json').write_text(json.dumps(rows,ensure_ascii=False,indent=2))
  roots=[]
  for row in rows['entries']:
   for artifact in row.get('artifact_refs',[]):
    blob=artifact.get('_blob',{})
    if blob.get('mime')!='application/vnd.masc.browser-scene+json':continue
    result=get('/api/v1/artifacts/'+blob['sha256'])
    raw=result['content'].encode()
    assert hashlib.sha256(raw).hexdigest()==blob['sha256'] and len(raw)==blob['bytes']
    roots.append({'execution_id':row['execution_id'],'artifact':blob,'url':json.loads(raw)['url']})
  report['verified_artifact_reads']=roots
  producer_audit=json.loads((a.evidence/'retained-observation-audit.json').read_text())
  expected={(o['execution_id'],o['reference']['sha256']) for o in producer_audit['observations']}
  actual={(r['execution_id'],r['artifact']['sha256']) for r in roots}
  assert actual==expected and actual, 'retained scenes differ from producer audit'
  print('real artifact API:',len(roots),'saved scenes verified; no browser connected',flush=True)
  if not a.preflight_only:
   result=subprocess.run(['python3','/tmp/capture-bundled-browser-history.py','--tui',str(tui),'--port',str(port),'--commit',a.source_commit]+(['--root',str(root),'--evidence',str(a.evidence.resolve()),'--checkout',str(a.checkout.resolve())]),env=env,cwd=root,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
   (out/'capture.log').write_text(result.stdout)
   report['capture_exit']=result.returncode
   report['capture_output']=result.stdout
   print('native TUI capture exit',result.returncode,flush=True)
   assert result.returncode==0,'native TUI reader did not pass; see capture.log'
  report['result']='preflight_pass' if a.preflight_only else 'native_reader_pass'
except Exception as error:
 report['result']='failed';report['error']=str(error);print(type(error).__name__,str(error),flush=True)
finally:
 if proc:
  if proc.poll() is None:
   os.killpg(proc.pid,signal.SIGTERM)
   try:proc.wait(timeout=10)
   except subprocess.TimeoutExpired:
    os.killpg(proc.pid,signal.SIGKILL);proc.wait(timeout=5)
  report['server_exit']=proc.returncode
 (out/'report.json').write_text(json.dumps(report,ensure_ascii=False,indent=2))
 print(out,flush=True)
if report['result']=='failed':raise SystemExit(1)
