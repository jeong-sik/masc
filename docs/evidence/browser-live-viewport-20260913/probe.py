import argparse,sys,tomllib,shutil,base64,importlib.util,functools,hashlib,http.server,json,os,pathlib,signal,socket,subprocess,threading,time,urllib.request,urllib.error,zipfile,uuid
parser=argparse.ArgumentParser()
parser.add_argument('tui_binary',type=pathlib.Path)
parser.add_argument('--server-binary',type=pathlib.Path,required=True)
parser.add_argument('--server-commit',required=True)
parser.add_argument('--provider',default='glm-coding')
parser.add_argument('--model',default='glm-5.3-flash')
parser.add_argument('--checkout',type=pathlib.Path,required=True)
parser.add_argument('--bundled-skills',type=pathlib.Path,required=True)
args=parser.parse_args()
ROOT=pathlib.Path(json.loads(pathlib.Path('/tmp/browser-handoff-current.json').read_text())['root']).resolve()
assert ROOT.resolve()==pathlib.Path('/var/folders/bv/cjrbl01x52s6j80krdfb63400000gp/T/masc-browser-handoff-yq3d680h').resolve(), 'scratch root differs from owned experiment'
OUT=ROOT/('tui-gesture-evidence-'+str(time.time_ns())); OUT.mkdir()
(OUT/'probe.py').write_bytes(pathlib.Path(__file__).read_bytes())
bundle_manifest=json.loads((args.bundled_skills/'bundle.json').read_text())
assert bundle_manifest['source_commit']==args.server_commit
assert bundle_manifest['server_sha256']==hashlib.sha256(args.server_binary.read_bytes()).hexdigest()
runtime=args.server_binary.resolve().parent
provenance=json.loads((runtime/'runtime-provenance.json').read_text())
assert provenance['source_commit']==args.server_commit
assert bundle_manifest['binary_source_proof']['source_commit']==args.server_commit
binary_paths={'masc-macos-arm64':args.server_binary.resolve(),
 'masc-tui-macos-arm64':args.tui_binary.resolve(),
 'masc-browser-host-macos-arm64':runtime/'masc-browser-host-macos-arm64'}
for name,path in binary_paths.items():
 actual=hashlib.sha256(path.read_bytes()).hexdigest()
 assert actual==bundle_manifest['binaries'][name]==bundle_manifest['binary_source_proof']['sha256'][name], 'binary candidate mismatch: '+name
assert subprocess.check_output(['git','-C',str(args.checkout),'rev-parse','HEAD'],text=True).strip()==args.server_commit
assert not subprocess.check_output(['git','-C',str(args.checkout),'status','--porcelain','--untracked-files=no']), 'candidate tracked checkout is dirty'
source_files=['connectors/browser/install-host.sh','connectors/browser/extension/manifest.json',
 'connectors/browser/extension/background.js',
 'scripts/harness/workload/produce_natural_keeper_skill_proof.py',
 'scripts/harness/workload/proof_http.py']
# The capture imports the test harness and its local helper modules. Check all
# Python files in that import directory, including untracked shadow modules.
source_files += [str(path.relative_to(args.checkout)) for path in (args.checkout/'test').rglob('*.py')]
source_hashes={}
for relative in source_files:
 canonical=subprocess.check_output(['git','-C',str(args.checkout),'show',args.server_commit+':'+relative])
 assert (args.checkout/relative).read_bytes()==canonical, 'candidate source bytes differ: '+relative
 source_hashes[relative]=hashlib.sha256(canonical).hexdigest()
(OUT/'candidate-source-proof.json').write_text(json.dumps({'source_commit':args.server_commit,'tracked_clean':True,'files':source_hashes},indent=2))
for package, files in bundle_manifest['packages'].items():
 for rel, digest in files.items():
  assert hashlib.sha256((args.bundled_skills/package/rel).read_bytes()).hexdigest()==digest
(OUT/'bundle.json').write_text(json.dumps(bundle_manifest,indent=2))
ENV={k:v for k,v in os.environ.items() if k in ('HOME','PATH','LANG','LC_ALL','TMPDIR','USER','LOGNAME','SHELL')}
ENV['MASC_IMESSAGE_CHAT_DB_PATH']=str(ROOT/'absent-message-fixture.db')
MASC=str(args.server_binary.resolve()); DRIVER='/Users/dancer/me/.masc/browser-lane/driver/geckodriver'
report={'scope':'owned Gesture Lab; real native TUI inputs through unchanged HTTP forwarding to compiled MASC and live Firefox; no Keeper model','steps':[],'cleanup':[]}
processes=[]; opened=False; server=None; browser_session=None; keeper_created=False; mcp=None; host_manifest=None; host_manifest_bytes=None; live_client=None
opener=urllib.request.build_opener(urllib.request.ProxyHandler({}))
def port():
 with socket.socket() as s:s.bind(('127.0.0.1',0));return s.getsockname()[1]
def request(url,data=None,token=None,timeout=60):
 headers={'Content-Type':'application/json'}
 if token:headers['Authorization']='Bearer '+token
 req=urllib.request.Request(url, data=None if data is None else json.dumps(data).encode(),headers=headers)
 try:res=opener.open(req,timeout=timeout)
 except urllib.error.HTTPError as error:res=error
 with res:return res.status,json.load(res)
def launch(name,cmd):
 log=(ROOT/(name+'.log')).open('w')
 p=subprocess.Popen(cmd,env=ENV,cwd=ROOT,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
 processes.append((name,p,log));return p
def wait_http(url,p):
 deadline=time.monotonic()+50
 while True:
  if p.poll() is not None:raise RuntimeError('owned process exited '+str(p.returncode))
  try:
   status,data=request(url,timeout=1)
   if status==200:return data
  except (OSError,ValueError):pass
  if time.monotonic()>deadline:raise RuntimeError('startup observation deadline; handle still '+str(p.poll()))
  time.sleep(.2)
def save(name,value):
 (OUT/(name+'.json')).write_text(json.dumps(value,ensure_ascii=False,indent=2))
def api(label,path,data):
 start=time.monotonic();status,value=request(base+path,data,token)
 report['steps'].append({'label':label,'status':status,'elapsed_ms':round((time.monotonic()-start)*1000,2),'request':data})
 save(label,value);print(label,status,flush=True)
 if status!=200 or value.get('ok') is not True:raise RuntimeError(label+' failed: '+str(value.get('error')))
 return value['data']
try:
 driver_port,api_port=port(),port()
 config=ROOT/'.masc/config/runtime.toml'
 sys.path.insert(0,'/tmp/masc-browser-probe-deps')
 import tomli_w
 production=tomllib.loads(pathlib.Path('/Users/dancer/me/.masc/config/runtime.toml').read_text())
 provider=args.provider;model=args.model;runtime_id=provider+'.'+model
 credentials=production['providers'][provider].get('credentials')
 if credentials is not None:
  assert credentials['type']=='env', 'probe only supports environment credentials or configured native CLI provider'
  key_name=credentials['key'];ENV[key_name]=os.environ[key_name]
 else:
  assert production['providers'][provider]['protocol'] in ('codex-app-server','claude-code'), 'unsupported credential mechanism'
 selected={'runtime':{'default':runtime_id},'providers':{provider:production['providers'][provider]},
  'models':{model:production['models'][model]},provider:{model:production[provider][model]},
  'skills':{'sources':[{'id':'project-masc','anchor':'base-path','path':'.masc/skills','access':'read-only'}]},
  'browser':{'webdriver_url':'http://127.0.0.1:'+str(driver_port),'binary':'/Applications/Firefox.app/Contents/MacOS/firefox'}}
 del selected['skills']
 config.write_text(tomli_w.dumps(selected)+'\n[skills]\nresource-read-max-bytes = 65536\n\n[[skills.sources]]\nid = "project-masc"\nanchor = "base-path"\npath = ".masc/skills"\naccess = "read-only"\n')
 seed=ROOT/'.masc/config/keepers/imp.toml'
 if seed.exists():seed.unlink()
 candidate=args.bundled_skills.resolve()/'browser-lanes'
 installed=ROOT/'.masc/skills/browser-lanes'
 if installed.exists() or installed.is_symlink():installed.rename(OUT/'previous-browser-lanes')
 shutil.copytree(candidate,installed)
 installed_hashes={str(p.relative_to(installed)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(installed.rglob('*')) if p.is_file()}
 assert installed_hashes==bundle_manifest['packages']['browser-lanes'], 'installed instruction differs from binary export'
 composition=args.bundled_skills.resolve()/'browser-live-click-content'
 installed=ROOT/'.masc/skills/browser-live-click-content'
 if installed.exists() or installed.is_symlink():installed.rename(OUT/'previous-browser-live-click-content')
 shutil.copytree(composition,installed)
 installed_hashes={str(p.relative_to(installed)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(installed.rglob('*')) if p.is_file()}
 assert installed_hashes==bundle_manifest['packages']['browser-live-click-content'], 'installed composition differs from binary export'
 report['composition_source_commit']=args.server_commit
 assert subprocess.check_output(['git','-C',str(args.checkout),'rev-parse','HEAD'],text=True).strip()==args.server_commit, 'extension/harness source differs from runtime candidate'
 report['composition_distribution']='full package exported by this server binary'
 shutil.copytree(composition,OUT/'packaged-skill')
 report['composition_file_sha256']=hashlib.sha256((composition/'SKILL.md').read_bytes()).hexdigest()
 driver=launch('driver',[DRIVER,'--host','127.0.0.1','--port',str(driver_port),'--websocket-port','0'])
 wait_http('http://127.0.0.1:'+str(driver_port)+'/status',driver)
 runtime=launch('server',[MASC,'start','--base-path',str(ROOT),'--host','127.0.0.1','--port',str(api_port)])
 base='http://127.0.0.1:'+str(api_port)
 health=wait_http(base+'/health?full=1',runtime)
 assert pathlib.Path(health['paths']['effective_base_path']).resolve()==ROOT.resolve()
 report['build']=health.get('build');report['binary_sha256']=hashlib.file_digest(open(MASC,'rb'),'sha256').hexdigest()
 assert report['build']['binary_commit']==args.server_commit, 'candidate source commit differs'
 assert report['build']['executable_sha256']==report['binary_sha256'], 'health executable identity differs'
 report['driver_sha256']=hashlib.file_digest(open(DRIVER,'rb'),'sha256').hexdigest()
 report['api_port']=api_port;report['driver_port']=driver_port
 token=json.loads((ROOT/'login-private.json').read_text())['bearer_token']
 deadline=time.monotonic()+50
 while True:
  if runtime.poll() is not None:raise RuntimeError('server exited before browser readiness')
  status,ready=request(base+'/api/v1/dashboard/browser-lane/clients',token=token,timeout=2)
  if status==200 and ready.get('ok') is True:break
  if time.monotonic()>deadline:raise RuntimeError('browser readiness not observed; server handle '+str(runtime.poll()))
  time.sleep(.2)
 print('Browser Lane initialized',flush=True)

 report['scope']='Actual native TUI screenshot input through recording HTTP forwarder to compiled live Browser Lane and real Firefox; no Keeper/model in this gesture run'
 fixture=ROOT/'gesture-fixture';fixture.mkdir(exist_ok=True)
 html='''<!doctype html><meta charset="utf-8"><title>Gesture Lab</title>
 <style>body{margin:0;height:100vh;overflow:hidden;background:#f7fafc;color:#132438;font:22px sans-serif}#open{position:absolute;left:10vw;top:1vh;width:80vw;height:10vh;display:grid;place-items:center;background:#dcecff}#card,#zone{position:absolute;top:15vh;width:22vw;height:22vh;display:grid;place-items:center;border:3px solid #456;border-radius:10px}#card{left:13vw;background:#f8d986;touch-action:none;user-select:none}#zone{left:65vw;background:#c7efd9}#drag-result{position:absolute;top:38vh;left:10vw;margin:0;font-size:18px}#pane{position:absolute;top:45vh;left:10vw;width:80vw;height:42vh;overflow:auto;border:2px solid #456;background:white}#pane p{height:80px;margin:0;padding:10px}#state{position:absolute;top:90vh;left:10vw;margin:0}</style>
 <a id="open" href="#details">Open details</a><div id="card" role="button">Drag card</div><div id="zone" role="region" aria-label="Drop zone">Drop zone</div><p id="drag-result">Card not moved</p>
 <section id="pane" aria-label="Message pane">'''
 html+=''.join('<p>Message row '+str(i)+' — visible context</p>' for i in range(20))
 html+='''</section><p id="state">Gesture Lab; Pane scroll=0</p><script>
 const card=document.getElementById('card'),zone=document.getElementById('zone'),pane=document.getElementById('pane');let pressed=null;
 document.getElementById('open').addEventListener('click',()=>{document.getElementById('open').textContent='Details opened by link click'});
 card.addEventListener('pointerdown',e=>{pressed={trusted:e.isTrusted};card.setPointerCapture(e.pointerId);e.preventDefault()});
 card.addEventListener('pointerup',e=>{const r=zone.getBoundingClientRect();if(pressed&&e.clientX>=r.left&&e.clientX<=r.right&&e.clientY>=r.top&&e.clientY<=r.bottom){document.getElementById('drag-result').textContent='Card moved; down trusted='+pressed.trusted+'; up trusted='+e.isTrusted}pressed=null});
 pane.addEventListener('scroll',()=>{document.getElementById('state').textContent='Gesture Lab; Pane scroll='+pane.scrollTop});
 </script>'''
 (fixture/'index.html').write_text(html);(OUT/'fixture.html').write_text(html)
 class Quiet(http.server.SimpleHTTPRequestHandler):
  def log_message(self,*args):pass
 server=http.server.ThreadingHTTPServer(('127.0.0.1',0),functools.partial(Quiet,directory=str(fixture)))
 threading.Thread(target=server.serve_forever,daemon=True).start()
 url='http://127.0.0.1:'+str(server.server_port)+'/index.html'
 # Bootstrap a separate Firefox profile, then all page observations/actions use live Browser Lane.
 def wd(method,path,body=None):
  req=urllib.request.Request('http://127.0.0.1:'+str(driver_port)+path,
   data=None if body is None else json.dumps(body).encode(),method=method,headers={'Content-Type':'application/json'})
  with opener.open(req,timeout=60) as response:value=json.load(response)['value']
  if isinstance(value,dict) and 'error' in value:raise RuntimeError('owned WebDriver: '+value['error'])
  return value
 host_name='masc_browser_proof_'+uuid.uuid4().hex
 host_source=args.server_binary.resolve().parent/'masc-browser-host-macos-arm64'
 manifest_stage=OUT/'manifest-stage'
 subprocess.run(['bash',str(args.checkout/'connectors/browser/install-host.sh'),
  '--binary',str(host_source),'--base-path',str(ROOT),'--server',base,
  '--manifest-dir',str(manifest_stage)],check=True,stdout=subprocess.DEVNULL)
 manifest=json.loads((manifest_stage/'masc_browser_host.json').read_text());manifest['name']=host_name
 host_manifest=pathlib.Path.home()/'Library/Application Support/Mozilla/NativeMessagingHosts'/(host_name+'.json')
 host_manifest.parent.mkdir(parents=True,exist_ok=True)
 host_manifest_bytes=(json.dumps(manifest,indent=2)+'\n').encode()
 with host_manifest.open('xb') as stream:stream.write(host_manifest_bytes)
 extension=OUT/'extension';extension.mkdir()
 for name in ['manifest.json','background.js']:
  original=(args.checkout/'connectors/browser/extension'/name).read_bytes();content=original
  if name=='background.js':
   old=b'const HOST_NAME = "masc_browser_host";';assert original.count(old)==1
   content=original.replace(old,('const HOST_NAME = "'+host_name+'";').encode())
  (extension/name).write_bytes(content)
 report['live_extension']={'host_name':host_name,'native_host_sha256':hashlib.sha256(host_source.read_bytes()).hexdigest(),
  'changes':'Only HOST_NAME routes this isolated profile to its private test server; page scripts and manifest are unchanged.',
  'source_commit':report['composition_source_commit'],
  'files':{f.name:hashlib.sha256(f.read_bytes()).hexdigest() for f in extension.iterdir()}}
 addon=OUT/'extension.xpi'
 with zipfile.ZipFile(addon,'w') as archive:
  for f in extension.iterdir():archive.write(f,f.name)
 session=wd('POST','/session',{'capabilities':{'alwaysMatch':{'browserName':'firefox','moz:firefoxOptions':{
  'binary':'/Applications/Firefox.app/Contents/MacOS/firefox','args':['-headless']}}}})
 browser_session=session['sessionId'];opened=True
 report['webdriver_bootstrap']={'session_id':browser_session,'profile':session['capabilities']['moz:profile']}
 wd('POST','/session/'+browser_session+'/url',{'url':url})
 installed_addon=wd('POST','/session/'+browser_session+'/moz/addon/install',{'path':str(addon),'temporary':True})
 report['live_extension']['installed_addon']=installed_addon
 deadline=time.monotonic()+30
 while True:
  st,connected=request(base+'/api/v1/dashboard/browser-lane/clients',token=token,timeout=5)
  if st==200 and connected.get('ok') and connected['data']['clients']:
   clients=connected['data']['clients'];assert len(clients)==1,'unexpected client in owned runtime'
   live_client=clients[0]['clientId'];save('01-live-clients',connected);break
  if runtime.poll() is not None or driver.poll() is not None:raise RuntimeError('owned process exited during extension startup')
  if time.monotonic()>deadline:raise RuntimeError('extension registration not observed; owned processes still running')
  time.sleep(.2)
 print('Live Firefox connected',flush=True)
 page=api('03-page','/api/v1/dashboard/browser-lane/read',{'lane':'live','clientId':live_client})
 save('page-shape',page)
 tab=next(t for t in page['tabs'] if t['url']==url)['id']
 spec=importlib.util.spec_from_file_location('gesture_capture','/tmp/capture-live-browser-gestures.py')
 capture=importlib.util.module_from_spec(spec);spec.loader.exec_module(capture)
 count=[0]
 def observe(label):
  count[0]+=1
  return api(label+'-'+str(count[0]),'/api/v1/dashboard/browser-lane/scene',{'lane':'live','clientId':live_client,'tabId':tab,'view':'content'})
 def navigate(old_scroll):
  destination=url+'?actor=external'
  wd('POST','/session/'+browser_session+'/url',{'url':destination})
  status,body=request(base+'/api/v1/dashboard/browser-lane/interact',old_scroll,token=token)
  save('stale-viewport-probe',{'actor':'owned probe, outside TUI','input':old_scroll,'status':status,'response':body})
  # This HTTP route flattens browser failures to strings and does not expose
  # effect disposition. Require the specific guard failure, never any error.
  assert status==400 and body.get('ok') is False and body.get('error')=='page_url_changed', ('unexpected stale-probe result',status,body)
  report['stale_probe_effect_phase_wire']='not exposed by this HTTP route'
  page=observe('stale-viewport-after-rejection')
  assert page['url']==destination
  assert any(n.get('text')=='Gesture Lab; Pane scroll=0' for n in page['nodes'])
  report['stale_viewport_rejected_after_external_navigation']=True
  return destination
 (OUT/'gesture-capture.py').write_bytes(pathlib.Path('/tmp/capture-live-browser-gestures.py').read_bytes())
 report['gesture_capture_sha256']=hashlib.sha256(pathlib.Path('/tmp/capture-live-browser-gestures.py').read_bytes()).hexdigest()
 report['gesture']=capture.run(repo=args.checkout.resolve(),executable=args.tui_binary.resolve(),base=ROOT,api_port=api_port,token=token,out=OUT,observe=observe,navigate=navigate)
 report['result']='interaction_verified'
except Exception as error:
 report['result']='failed';report['error']=repr(error);print(type(error).__name__,str(error),flush=True)
finally:
 if opened:
  try:
   wd('DELETE','/session/'+browser_session);report['cleanup'].append('owned live Firefox profile closed')
  except Exception as error:report['cleanup'].append({'profile_cleanup_error':repr(error)})
 if host_manifest is not None:
  try:
   if host_manifest.exists():
    if host_manifest.read_bytes()!=host_manifest_bytes:
     raise RuntimeError('owned manifest changed externally; preserved')
    host_manifest.unlink()
   report['cleanup'].append('owned unique native host manifest removed')
  except Exception as error:report['cleanup'].append({'manifest_cleanup_error':repr(error)})
 if server:
  try:server.shutdown();server.server_close()
  except Exception as error:report['cleanup'].append({'fixture_cleanup_error':repr(error)})
 for name,p,log in reversed(processes):
  try:
   if p.poll() is None:
    os.killpg(p.pid,signal.SIGTERM)
    try:p.wait(timeout=10)
    except subprocess.TimeoutExpired:
     os.killpg(p.pid,signal.SIGKILL);p.wait(timeout=5)
   report['cleanup'].append({'name':name,'pid':p.pid,'exit':p.returncode})
  except Exception as error:report['cleanup'].append({'name':name,'cleanup_error':repr(error)})
  finally:
   try:log.close()
   except Exception as error:report['cleanup'].append({'name':name,'log_cleanup_error':repr(error)})
 cleanup_ok=('owned live Firefox profile closed' in report['cleanup']
  and 'owned unique native host manifest removed' in report['cleanup']
  and len([item for item in report['cleanup'] if isinstance(item,dict) and item.get('name') in ('server','driver') and item.get('exit')==0])==2
  and not any(isinstance(item,dict) and any('error' in key for key in item) for item in report['cleanup'])
  and not any(isinstance(item,str) and item.startswith('session close failed:') for item in report['cleanup']))
 report['cleanup_ok']=cleanup_ok
 if report.get('result')=='interaction_verified' and cleanup_ok:report['result']='passed'
 save('report',report);print('report',OUT/'report.json',flush=True)
if report.get('result')!='passed':raise SystemExit(1)
