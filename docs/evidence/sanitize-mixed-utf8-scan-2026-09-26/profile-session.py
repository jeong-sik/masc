from pathlib import Path
import argparse,gzip,hashlib,http.client,http.server,json,os,signal,socket,subprocess,sys,threading,time
P=argparse.ArgumentParser();P.add_argument('artifact',type=Path);P.add_argument('output',type=Path);P.add_argument('--cycles',type=int,default=2);P.add_argument('--tasks',type=int,default=20);P.add_argument('--repo',type=Path,required=True);P.add_argument('--encoding',choices=('identity','gzip'),required=True);P.add_argument('--commit',required=True);P.add_argument('--run',type=int,required=True);P.add_argument('--artifact-id',type=int,required=True);a=P.parse_args()
assert a.cycles>0 and a.tasks>0
root=a.repo.resolve();artifact=a.artifact.resolve();out=a.output.resolve();out.mkdir(exist_ok=False)
meta=json.loads((artifact/'artifact.json').read_text());manifest=json.loads((artifact/'manifest.json').read_text())
assert meta['id']==a.artifact_id and meta['workflow_run']['id']==a.run and manifest['commit']==a.commit
assert meta['workflow_run']['head_repository_id']==1136640865
assert meta['workflow_run']['repository_id']==1136640865 and meta['workflow_run']['head_sha']==manifest['commit'] and not meta['expired']
assert manifest['arch']=='macos-arm64' and set(manifest['sha256'])=={'main_eio.exe','masc_tui.exe','masc_browser_host.exe'}
for name,digest in manifest['sha256'].items():
 assert not (artifact/name).is_symlink() and hashlib.sha256((artifact/name).read_bytes()).hexdigest()==digest
binary=artifact/'main_eio.exe';binary.chmod(binary.stat().st_mode|0o100)
base=out/'workspace';cfg=base/'.masc/config';cfg.mkdir(parents=True);(cfg/'keepers').mkdir();(cfg/'prompts').mkdir()
model_requests=[]
class ModelStub(http.server.BaseHTTPRequestHandler):
 def do_GET(self):self.reply()
 def do_POST(self):self.reply()
 def reply(self):
  model_requests.append({'method':self.command,'path':self.path});self.send_response(503);self.send_header('Content-Length','0');self.end_headers()
 def log_message(self,*args):pass
stub=http.server.ThreadingHTTPServer(('127.0.0.1',0),ModelStub);threading.Thread(target=stub.serve_forever,daemon=True).start()
fixture=(root/'scripts/fixtures/release-evidence/runtime.toml').read_text();assert fixture.count('http://127.0.0.1:9/v1')==1
(cfg/'runtime.toml').write_text(fixture.replace('http://127.0.0.1:9/v1',f'http://127.0.0.1:{stub.server_port}/v1'))
with socket.socket() as sock:sock.bind(('127.0.0.1',0));port=sock.getsockname()[1]
assert port!=8935 and port!=stub.server_port
# Exact allowlist: no credentials or real connector/model configuration inherited.
env={'PATH':os.environ['PATH'],'LANG':'en_US.UTF-8','MASC_BASE_PATH':str(base),'MASC_CONFIG_DIR':str(cfg),'MASC_CONFIG_BOOTSTRAP':'skip','MASC_KEEPER_AUTONOMOUS_ENABLED':'false','MASC_ORCHESTRATOR_ENABLED':'false','MASC_GRPC_ENABLED':'0','MASC_WS_ENABLED':'0'}
headers={'Accept':'application/json, text/event-stream'};seq=0;observations=[];setup=[];responses=[]
def request(method,path,payload=None,extra=None,timed=False):
 c=http.client.HTTPConnection('127.0.0.1',port,timeout=10)
 body=None if payload is None else json.dumps(payload).encode()
 hs=dict(headers if path=='/mcp' else {'Accept':'application/json'});hs.update(extra or {})
 if body is not None:hs['Content-Type']='application/json'
 start=time.perf_counter_ns()
 try:
  c.request(method,path,body,hs);r=c.getresponse();received_headers=time.perf_counter_ns();wire=r.read();end=time.perf_counter_ns();rh={k.lower():v for k,v in r.getheaders()};status=r.status
 finally:c.close()
 raw=gzip.decompress(wire) if rh.get('content-encoding')=='gzip' else wire
 try:obj=json.loads(raw)
 except json.JSONDecodeError:
  events=[json.loads(line[5:].strip()) for line in raw.decode().splitlines() if line.startswith('data:')]
  assert len(events)==1,raw[:200];obj=events[0]
 return status,obj,rh,{'wire_ms':(end-start)/1e6,'headers_ms':(received_headers-start)/1e6,'body_read_ms':(end-received_headers)/1e6,'wire_bytes':len(wire),'json_bytes':len(raw),'body_sha256':hashlib.sha256(raw).hexdigest(),'server_timing':rh.get('server-timing'),'encoding':rh.get('content-encoding'),'etag':rh.get('etag')}
def rpc(method,params):
 global seq
 seq+=1;status,obj,rh,_=request('POST','/mcp',{'jsonrpc':'2.0','id':seq,'method':method,'params':params})
 assert status==200,(status,obj);assert 'error' not in obj,obj
 if method=='initialize':
  assert rh.get('mcp-session-id');headers['Mcp-Session-Id']=rh['mcp-session-id'];headers['Mcp-Protocol-Version']=rh['mcp-protocol-version']
 return obj['result']
def tool(name,args):
 r=rpc('tools/call',{'name':name,'arguments':args});assert not r.get('isError',False) and r['structuredContent']['ok'] is True,r
 setup.append({'tool':name,'arguments_sha256':hashlib.sha256(json.dumps(args,sort_keys=True).encode()).hexdigest(),'result':r})
 return r
def interrupted(signum,_frame):
 raise SystemExit(128+signum)
signal.signal(signal.SIGTERM,interrupted)
signal.signal(signal.SIGINT,interrupted)
log=(out/'server.log').open('wb');process=subprocess.Popen([str(binary),'--host','127.0.0.1','--base-path',str(base),'--port',str(port)],cwd=base,env=env,stdout=log,stderr=log,start_new_session=True)
sampler=None;sample_log=None;profile={}
try:
 identity={'source':manifest['commit'],'binary_sha256':manifest['sha256']['main_eio.exe'],'base':str(base),'port':port,'pid':process.pid,'artifact_id':meta['id'],'artifact_run':meta['workflow_run']['id'],'runner_sha256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),'environment_keys':sorted(env),'model_endpoint':f'http://127.0.0.1:{stub.server_port}/v1','requested_encoding':a.encoding,'seed_tasks':a.tasks,'cycles':a.cycles,'command':[sys.executable,*sys.argv],'python':sys.version,'runtime_config_sha256':hashlib.sha256((cfg/'runtime.toml').read_bytes()).hexdigest(),'runtime_fixture_sha256':hashlib.sha256(fixture.encode()).hexdigest()}
 (out/'identity.json').write_text(json.dumps(identity,indent=2)+'\n')
 deadline=time.monotonic()+45
 while True:
  assert process.poll() is None,('early server exit',process.returncode)
  try:
   status,health,_,_=request('GET','/health?full=1')
   if status==200 and health.get('startup',{}).get('state_ready'):break
  except (OSError,TimeoutError,http.client.HTTPException):pass
  if time.monotonic()>=deadline:raise RuntimeError('isolated server readiness deadline')
  time.sleep(.1)
 assert health['paths']['effective_masc_root']==str(base/'.masc'),health['paths']
 assert health['build']['binary_commit']==manifest['commit'],health['build']
 assert health['build']['executable_sha256']==manifest['sha256']['main_eio.exe']
 assert health['keeper_fibers']==0,health['keeper_fibers']
 (out/'health.json').write_text(json.dumps(health,indent=2)+'\n')
 status,token,_,_=request('GET','/api/v1/dashboard/dev-token');assert status==200 and token.get('token'),(status,token)
 headers['Authorization']='Bearer '+token['token']
 rpc('initialize',{'protocolVersion':'2025-11-25','capabilities':{},'clientInfo':{'name':'synthetic-cold-response-comparison','version':'1'}})
 listed=rpc('tools/list',{});names={t['name'] for t in listed['tools']};assert {'masc_add_task','masc_batch_add_tasks'}<=names
 for offset in range(0,a.tasks,20):
  tool('masc_batch_add_tasks',{'tasks':[{'title':f'Synthetic backlog {n:04d}','description':'Synthetic response fixture. '+('검증 ASCII payload '+str(n)+' ')*50,'priority':3} for n in range(offset,min(offset+20,a.tasks))]})
 status,warm,_,wm=request('GET','/api/v1/dashboard/execution',extra={'Accept-Encoding':a.encoding});assert status==200 and len(warm['tasks'])==a.tasks,(status,warm.keys())
 generation=warm['execution_publication_generation']
 profile={'scope':'native sampling during interleaved MCP task mutations and first/warm HTTP GETs; profiled timing is not benchmark evidence','duration_requested_seconds':5,'interval_requested_ms':1,'server_pid':process.pid,'workload_started_ns':time.perf_counter_ns()}
 sample_log=(out/'sample-command.log').open('wb')
 sample_command=['/usr/bin/sample',str(process.pid),'5','1','-file',str(out/'native-sample.txt')]
 sampler=subprocess.Popen(sample_command,stdout=sample_log,stderr=sample_log)
 profile.update({'sampler_pid':sampler.pid,'command':sample_command})
 for cycle in range(1,a.cycles+1):
  tool('masc_add_task',{'title':f'Synthetic invalidation {cycle:04d}','description':'Owned fixture cache invalidation','priority':3})
  for phase in ('cold','warm'):
   status,obj,rh,obs=request('GET','/api/v1/dashboard/execution',extra={'Accept-Encoding':a.encoding})
   # Profiling retains observations, not every large parsed response; observer differs from paired benchmark.
   obs.update({'cycle':cycle,'phase':phase,'status':status,'task_count':len(obj.get('tasks',[])),'generation':obj.get('execution_publication_generation'),'query':obj.get('query'),'cache':obj.get('cache')});observations.append(obs)
   assert status==200 and len(obj['tasks'])==a.tasks+cycle,obs
   assert obj['query']['default_light_request'] is True and obj['query']['actor'] is None,obs
   assert obj.get('execution_invalidated') is False,obs
   if phase=='cold':
    assert obj['execution_publication_generation']>generation,obs
    assert 'cache_compute' in (obs['server_timing'] or ''),obs
    generation=obj['execution_publication_generation']
   else:
    assert 'cache_compute' not in (obs['server_timing'] or ''),obs
    assert obs['body_sha256']==observations[-2]['body_sha256'],(observations[-2],obs)
 profile['workload_finished_ns']=time.perf_counter_ns()
 profile['sample_returncode']=sampler.wait(timeout=10)
 assert profile['sample_returncode']==0,profile
 status,after,_,_=request('GET','/health?full=1');assert after['build']['runtime_instance_id']==health['build']['runtime_instance_id']
 assert all(x=={'method':'GET','path':'/v1/models'} for x in model_requests),model_requests
 print(json.dumps({'source':manifest['commit'],'sample_count':len(observations),'requested_encoding':a.encoding,'model_requests':model_requests}),flush=True)
finally:
 if sampler is not None:
  if sampler.poll() is None:
   sampler.terminate()
   try:sampler.wait(timeout=5)
   except subprocess.TimeoutExpired:sampler.kill();sampler.wait(timeout=5)
  profile['sample_returncode']=sampler.returncode
  profile['sample_reaped']=sampler.poll() is not None
 if sample_log is not None:sample_log.close()
 (out/'profile.json').write_text(json.dumps(profile,indent=2)+'\n')
 if process.poll() is None:
  os.killpg(process.pid,signal.SIGTERM)
  try:process.wait(timeout=10)
  except subprocess.TimeoutExpired:os.killpg(process.pid,signal.SIGKILL);process.wait(timeout=5)
 stub.shutdown();stub.server_close();log.close()
 (out/'responses.json.gz').write_bytes(gzip.compress(json.dumps(responses,ensure_ascii=False).encode(),mtime=0))
 (out/'observations.json').write_text(json.dumps(observations,indent=2)+'\n');(out/'setup.json').write_text(json.dumps(setup,indent=2)+'\n');(out/'cleanup.json').write_text(json.dumps({'returncode':process.returncode,'model_requests':model_requests,'reaped':process.poll() is not None},indent=2)+'\n')
