import base64,hashlib,http.server,importlib.util,json,os,pathlib,re,socket,subprocess,tempfile,threading,time,traceback,urllib.request,urllib.error,uuid
import websocket
ROOT=pathlib.Path(json.loads(pathlib.Path('/tmp/browser-handoff-current.json').read_text())['root']).resolve()
OUT=ROOT/('bidi-tui-evidence-'+str(time.time_ns()));OUT.mkdir(); profile=OUT/'profile';profile.mkdir()
DIST=pathlib.Path('/tmp/browser-navigation-native-fd441');REPO=pathlib.Path('/private/tmp/masc-browser-navigation-continuity-native');REV='fd441e234f58f34e2889d8fde0fc20d3ea2be4d1'
assert subprocess.check_output(['git','-C',str(REPO),'rev-parse','HEAD'],text=True).strip()==REV
source_hashes={}
for f in (REPO/'test').rglob('*.py'):
 canonical=subprocess.check_output(['git','-C',str(REPO),'show',REV+':'+str(f.relative_to(REPO))]);assert f.read_bytes()==canonical;source_hashes[str(f.relative_to(REPO))]=hashlib.sha256(canonical).hexdigest()
(OUT/'helper-source-proof.json').write_text(json.dumps({'revision':REV,'files':source_hashes},indent=2))
bundle=json.loads((DIST/'bundle/bundle.json').read_text());assert bundle['source_commit']==REV
for n in ['masc-macos-arm64','masc-tui-macos-arm64']:
 assert hashlib.sha256((DIST/'runtime'/n).read_bytes()).hexdigest()==bundle['binaries'][n]
scene_source=subprocess.check_output(['git','-C',str(REPO),'show',REV+':lib/browser_scene_script.ml']).decode();scene=scene_source.split('{js|',1)[1].split('|js}',1)[0]
(OUT/'browser-scene.js').write_text(scene);(OUT/'bundle.json').write_text(json.dumps(bundle,indent=2))
# Reuse the owned fixture, without any script from the page becoming bridge commands.
baseprobe=pathlib.Path('/tmp/browser-tui-gesture-probe.py').read_text();a=baseprobe.index(" html='''");b=baseprobe.index(" (fixture/'index.html')",a);ns={};exec(baseprobe[a:b].replace('\n ', '\n').lstrip(),ns);html=ns['html'];(OUT/'fixture.html').write_text(html)
class Handler(http.server.BaseHTTPRequestHandler):
 def log_message(self,*a):pass
 def do_GET(self):
  data=html.encode();self.send_response(200);self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
fixture=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler);threading.Thread(target=fixture.serve_forever,daemon=True).start();url=f'http://127.0.0.1:{fixture.server_port}/'
def port():
 with socket.socket() as s:s.bind(('127.0.0.1',0));return s.getsockname()[1]
processes=[];logs=[];ws=None;seq=0;lock=threading.RLock();stop=threading.Event();raw=[];transport=[];report={'scope':'experimental Python BiDi Browser Lane live bridge; real fd441 MASC/TUI; no extension or Keeper','result':'failed','source_commit':REV};worker=None
opener=urllib.request.build_opener(urllib.request.ProxyHandler({}))
def post(path,data,headers={},timeout=35):
 req=urllib.request.Request(base+path,data=json.dumps(data).encode(),headers={'Content-Type':'application/json',**headers})
 with opener.open(req,timeout=timeout) as r:return json.load(r)
def launch(name,cmd):
 f=(OUT/(name+'.log')).open('wb');logs.append(f);p=subprocess.Popen(cmd,stdout=f,stderr=f,cwd=ROOT,env={k:v for k,v in os.environ.items() if k in ['HOME','PATH','LANG','TMPDIR','USER','SHELL']});processes.append((name,p));return p
def call(method,params):
 global seq
 with lock:
  seq+=1;req={'id':seq,'method':method,'params':params};ws.send(json.dumps(req))
  while True:
   r=json.loads(ws.recv());raw.append({'request':req,'reply':r})
   if r.get('id')==seq:
    if r.get('type')=='error':raise RuntimeError(r)
    return r['result']
def evaluate(ctx,expression):
 r=call('script.evaluate',{'expression':'JSON.stringify('+expression+')','target':{'context':ctx},'awaitPromise':False})
 if r['type']!='success':raise RuntimeError(r)
 return json.loads(r['result']['value'])
def observe(ctx,args):return evaluate(ctx,'('+scene+')('+json.dumps(args)+')')
def state(ctx):return evaluate(ctx,'({url:location.href,title:document.title,text:document.body.innerText})')
def dispatch(verb,args):
 with lock:
  if verb=='tabs.list':
   tree=call('browsingContext.getTree',{})['contexts'];existing={c['context'] for c in tree}
   return [dict(id=i,index=i-1,active=evaluate(c,'document.visibilityState === \"visible\"'),**{k:v for k,v in state(c).items() if k in ['url','title']}) for i,c in mapping.items() if c in existing]
  tab=args.get('tabId',1)
  if tab not in mapping:raise ValueError('unobserved_tab')
  ctx=mapping[tab]
  if verb=='page.read':
   if args.get('includeHtml'):raise ValueError('unsupported_includeHtml')
   p=state(ctx);text=p['text'];p.update(text=text[:args.get('maxChars',100000)],chars=len(text),truncated=len(text)>args.get('maxChars',100000),tabId=tab);return p
  if verb=='page.scene':return dict(tabId=tab,**observe(ctx,{**args,'mode':'read'}))
  if verb=='page.capture':
   before=state(ctx);vp=observe(ctx,{'mode':'viewport'});png=call('browsingContext.captureScreenshot',{'context':ctx})['data'];after=state(ctx)
   if before!=after or vp!=observe(ctx,{'mode':'viewport'}):raise ValueError('viewport_changed_during_capture')
   return dict(tabId=tab,url=after['url'],title=after['title'],mimeType='image/png',data=png,viewport=vp)
  if verb!='page.interact':raise ValueError('unsupported_verb')
  if args.get('action') not in ['drag','click_at','scroll_at']:raise ValueError('unsupported_action')
  p=state(ctx);vp=observe(ctx,{'mode':'viewport'})
  if args.get('expectedUrl')!=p['url']:raise ValueError('page_url_changed')
  if args.get('viewport')!=vp:raise ValueError('observed_viewport_changed')
  def point(v):
   if not isinstance(v,dict) or any(not isinstance(v.get(k),(int,float)) or not 0<=v[k]<1 for k in ['x','y']):raise ValueError('invalid_point')
   return {'x':int(v['x']*vp['width']),'y':int(v['y']*vp['height'])}
  action=args['action']
  if action=='scroll_at':
   coords=point(args['point']);acts={'type':'wheel','id':'wheel','actions':[dict(type='scroll',deltaX=args['x'],deltaY=args['y'],**coords)]}
  else:
   origin=point(args['from'] if action=='drag' else args['point']);steps=[dict(type='pointerMove',**origin),{'type':'pointerDown','button':0}]
   if action=='drag':steps.append(dict(type='pointerMove',duration=180,**point(args['to'])))
   steps.append({'type':'pointerUp','button':0});acts={'type':'pointer','id':'mouse','parameters':{'pointerType':'mouse'},'actions':steps}
  try:call('input.performActions',{'context':ctx,'actions':[acts]})
  finally:
   if action!='scroll_at':call('input.releaseActions',{'context':ctx})
  p2=state(ctx);return dict(action=action,urlBefore=p['url'],url=p2['url'],title=p2['title'])
try:
 fp=port();firefox=launch('firefox',['/Applications/Firefox.app/Contents/MacOS/firefox','--headless','--no-remote','--profile',str(profile),'--remote-debugging-port',str(fp)])
 end=time.monotonic()+20
 while True:
  try:ws=websocket.create_connection(f'ws://127.0.0.1:{fp}/session',timeout=15,suppress_origin=True);break
  except OSError:
   if time.monotonic()>end:raise
   time.sleep(.1)
 report['session']=call('session.new',{'capabilities':{}});mapping={i:call('browsingContext.create',{'type':'tab'})['context'] for i in [1,2]}
 for c in mapping.values():call('browsingContext.navigate',{'context':c,'url':url,'wait':'interactive'})
 call('browsingContext.activate',{'context':mapping[1]});report['initial_tree']=call('browsingContext.getTree',{});report['mapping']=mapping;report['before']={i:state(c) for i,c in mapping.items()}
 api_port=port();base=f'http://127.0.0.1:{api_port}';server=launch('masc',[str(DIST/'runtime/masc-macos-arm64'),'start','--base-path',str(ROOT),'--host','127.0.0.1','--port',str(api_port)])
 end=time.monotonic()+50
 while True:
  try:
   with opener.open(base+'/health?full=1',timeout=1) as r:health=json.load(r)
   if health.get('build',{}).get('binary_commit')==REV:break
  except (OSError,ValueError):pass
  if time.monotonic()>end or server.poll()!=None:raise RuntimeError('server startup failed')
  time.sleep(.2)
 report['health_build']=health['build'];token=json.loads((ROOT/'login-private.json').read_text())['bearer_token'];client=str(uuid.uuid4());lane_token=(ROOT/'.masc/browser-lane/token').read_text().strip();headers={'x-lane':'live','x-lane-token':lane_token,'x-browser-client-id':client,'x-browser-name':'firefox','x-browser-version':report['session']['capabilities']['browserVersion'],'x-browser-engine-version':report['session']['capabilities']['browserVersion']};report['client_id']=client
 def poll():
  while not stop.is_set():
   try:
    req=post('/browser-lane/poll',{},headers)
    if 'id' not in req:continue
    try:reply={'id':req['id'],'ok':True,'data':dispatch(req['verb'],req['args'])}
    except Exception as e:reply={'id':req['id'],'ok':False,'error':str(e)}
    transport.append({'request':req,'reply':reply});post('/browser-lane/result',reply,headers)
   except Exception as e:
    if not stop.is_set():report['bridge_error']=repr(e)
    break
 worker=threading.Thread(target=poll,daemon=True);worker.start()
 def obs(label):return post('/api/v1/dashboard/browser-lane/scene',{'lane':'live','clientId':client,'tabId':1,'view':'content'},{'Authorization':'Bearer '+token})['data']
 # Existing recorder remains unchanged except live selection and bounded drag-only sequence.
 text=pathlib.Path('/tmp/capture-real-browser-gestures.py').read_text();(OUT/'capture-original.py').write_text(text);text=text.replace('real automation Firefox','real experimental BiDi live Firefox');text=text.replace("send(b'a', b'Gesture Lab')","send(b'l', b'Gesture Lab')")
 start=text.index("        geometry = image_input(mouse(geometry, (.5, .06)")
 finish=text.index("        result['result'] = 'passed'",start)
 text=text[:start]+'''        geometry = image_input(mouse(geometry, (.24, .25), (.76, .25)), 'dragged')
        confirm('drag-observed', 'Card moved; down trusted=true; up trusted=true')
        actions = [r for r in receipts if r['path'].endswith('/interact')]
        assert len(actions)==1 and actions[0]['input']['action']=='drag'
        assert actions[0]['status']==200 and actions[0]['response']['ok'] is True
'''+text[finish:]
 path=OUT/'capture.py';path.write_text(text);spec=importlib.util.spec_from_file_location('capture_bidi',path);capture=importlib.util.module_from_spec(spec);spec.loader.exec_module(capture)
 report['gesture']=capture.run(repo=REPO,executable=DIST/'runtime/masc-tui-macos-arm64',base=ROOT,api_port=api_port,token=token,out=OUT,observe=obs,navigate=None)
 report['after']={i:state(c) for i,c in mapping.items()};assert report['after'][2]==report['before'][2];assert 'down trusted=true; up trusted=true' in report['after'][1]['text']
 old=[r['request']['args'] for r in transport if r['request']['verb']=='page.interact'][0]
 stale={**old,'viewport':{**old['viewport'],'documentId':'deliberately-stale-owned-probe'}}
 count_before=len([r for r in raw if r['request']['method']=='input.performActions'])
 try:dispatch('page.interact',stale);raise AssertionError('stale accepted')
 except ValueError as e:assert str(e)=='observed_viewport_changed';report['stale_rejection']=str(e)
 assert len([r for r in raw if r['request']['method']=='input.performActions'])==count_before
 assert state(mapping[1])==report['after'][1] and state(mapping[2])==report['before'][2]
 report['stale_input']=stale
 report['result']='passed'
except BaseException:report['error']=traceback.format_exc()
finally:
 stop.set(); cleanup_errors=[]
 def clean(stage,fn):
  try:fn()
  except BaseException as e:cleanup_errors.append({'stage':stage,'error':repr(e)})
 if worker:
  clean('disconnect',lambda:post('/browser-lane/disconnect',{},headers))
  clean('worker-join',lambda:worker.join(timeout=27))
  if worker.is_alive():cleanup_errors.append({'stage':'worker-join','error':'still alive'})
 if ws:
  clean('session-end',lambda:call('session.end',{}));clean('websocket-close',ws.close)
 for name,p in reversed(processes):
  def end_process():
   if p.poll() is None:
    p.terminate()
    try:p.wait(timeout=10)
    except subprocess.TimeoutExpired:p.kill();p.wait(timeout=5)
  clean(name,end_process)
  report.setdefault('cleanup',[]).append({'name':name,'pid':p.pid,'exit':p.returncode})
 clean('fixture-shutdown',fixture.shutdown);clean('fixture-close',fixture.server_close)
 for f in logs:clean('log-close',f.close)
 if cleanup_errors:report['result']='failed'
 report['cleanup_errors']=cleanup_errors
 (OUT/'bidi.json').write_text(json.dumps(raw,indent=2));(OUT/'transport.json').write_text(json.dumps(transport,indent=2));(OUT/'report.json').write_text(json.dumps(report,indent=2));(OUT/'probe.py').write_bytes(pathlib.Path(__file__).read_bytes())
 (OUT/'SHA256SUMS').write_text(''.join(hashlib.sha256(f.read_bytes()).hexdigest()+'  '+f.name+'\n' for f in sorted(OUT.iterdir()) if f.is_file()))
print(json.dumps({'out':str(OUT),'result':report['result'],'error':report.get('error'),'cleanup_errors':cleanup_errors}))
