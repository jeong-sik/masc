"""Isolated Firefox lifecycle prototype; never installs into a user profile.
Run only after review: --driver PATH --browser PATH --out NEW_DIRECTORY.
"""
import argparse,hashlib,http.server,json,socket,subprocess,threading,time,urllib.request,zipfile
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--driver',required=True);p.add_argument('--browser',required=True);p.add_argument('--out',type=Path,required=True);a=p.parse_args()
out=a.out.resolve();out.mkdir(parents=True,exist_ok=False)
source=Path(__file__).resolve().parents[1]/'connectors/browser/extension/background.js'
background=source.read_text()
interaction=background[background.index('function interactInPage(args)'):background.index('async function onHostMessage(')]
scene=source.read_text().split('function browserDocument()',1)[0]
assert scene.startswith('function browserScene(args)')
release=threading.Event();finished=threading.Event();events=[];requests=[]
class Handler(http.server.BaseHTTPRequestHandler):
 def log_message(self,*args):pass
 def do_GET(self):
  requests.append({"method":"GET","path":self.path,"time":time.time()})
  if self.path=='/broken':
   self.connection.shutdown(2);self.connection.close();return
  if self.path.startswith('/redirect'):
   self.send_response(302);self.send_header('Location','/final');self.end_headers();return
  if self.path.startswith('/slow.png'):
   release.wait();body=b''
  else:
   body=('<html><body><main><h1>Observed '+self.path+'</h1><a href="/first">destination</a><a href="/redirect">redirect</a><a href="#hash">hash</a><a href="/broken">broken</a></main>'+ ('' if self.path=='/initial' else '<img src="/slow.png">')+'</body></html>').encode()
  self.send_response(200);self.send_header('Content-Length',str(len(body)));self.end_headers()
  try:self.wfile.write(body)
  except (BrokenPipeError,ConnectionResetError):pass
 def do_POST(self):
  event=json.loads(self.rfile.read(int(self.headers['Content-Length'])));events.append(event)
  if event['kind'] in ['done','failure']:finished.set()
  self.send_response(200);self.end_headers()
srv=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler);srv.daemon_threads=True
threading.Thread(target=srv.serve_forever,daemon=True).start();site=f'http://127.0.0.1:{srv.server_port}'
script=r'''
const base=BASE, sceneSource=SCENE;
PRODUCTION

const report = data => fetch(base+'/report',{method:'POST',body:JSON.stringify(data)});
(async()=>{
 const tab=await browser.tabs.create({url:base+'/initial'});
 // Initialization only: no resource fixture has been opened yet.
 await new Promise((resolve,reject)=>{
  const changed=(id,change,tab)=>{if(id===tab.id && tab.url===base+'/initial' && tab.status==='complete')finish();};
  const removed=id=>{if(id===tab.id){cleanup();reject(new Error('initial tab removed'));}};
  const cleanup=()=>{browser.tabs.onUpdated.removeListener(changed);browser.tabs.onRemoved.removeListener(removed);};
  const finish=()=>{cleanup();resolve();};
  browser.tabs.onUpdated.addListener(changed);
  browser.tabs.onRemoved.addListener(removed);
  browser.tabs.get(tab.id).then(snapshot=>{if(snapshot.url===base+'/initial' && snapshot.status==='complete')finish();},error=>{cleanup();reject(error);});
 });
 await report({kind:'initialization',tab:await browser.tabs.get(tab.id)});
 let previous=null;
 for(const [name,path] of [['document-change','/first'],['same-url-reload','/first'],['redirect','/redirect'],['hash','/final#hash'],['destination-error','/broken']]) {
  let commit=null, effects_requested=0;
  const sourceFrame=await browser.webNavigation.getFrame({tabId:tab.id,frameId:0});
  await report({kind:'source-frame',name,sourceFrame,error_policy:'observation_only'});
  const events=[];
  let resolveReady,rejectReady;
  const ready=new Promise((resolve,reject)=>{resolveReady=resolve;rejectReady=reject});
  const snapshot=(await browser.tabs.executeScript(tab.id,{code:'('+sceneSource+')({mode:"read",view:"content",maxChars:20000})',runAt:'document_end'}))[0];
  const wanted=name==='hash'?base+'/final#hash':base+path;
  const link=snapshot.nodes.find(n=>n.href===wanted);
  const owned=d=>d.tabId===tab.id && d.frameId===0;
  const onHash=d=>{if(owned(d)){events.push({kind:'same-document',details:d});if(name==='hash')resolveReady(d);}};
  const onBefore=d=>{if(owned(d))events.push({kind:'before-navigate',details:d});};
  const onCommitted=d=>{if(owned(d)){commit=d;events.push({kind:'committed',details:d});}};
  const onReady=d=>{if(owned(d)&&commit && commit.documentId===d.documentId && commit.documentId!==sourceFrame.documentId){events.push({kind:'dom-ready',details:d});resolveReady(d);}};
  const onError=d=>{if(owned(d)){events.push({kind:'navigation-error',details:d});report({kind:'navigation-error-observed',name,sourceFrame,details:d,error_policy:'observation_only'});if(name==='destination-error')resolveReady(d);}};
  const onRemoved=id=>{if(id===tab.id)rejectReady(new Error('owned tab removed'));};
  browser.tabs.onRemoved.addListener(onRemoved);
  browser.webNavigation.onReferenceFragmentUpdated.addListener(onHash);
  browser.webNavigation.onBeforeNavigate.addListener(onBefore);
  browser.webNavigation.onCommitted.addListener(onCommitted);
  browser.webNavigation.onDOMContentLoaded.addListener(onReady);
  browser.webNavigation.onErrorOccurred.addListener(onError);
  try {
   effects_requested++;
   if(name==='same-url-reload') await browser.tabs.reload(tab.id);
   else {
    if(!link)throw new Error('observed destination anchor missing');
    const receipt=await pageInteract({action:'follow_link',tabId:tab.id,expectedUrl:snapshot.url,documentId:snapshot.documentId,nodeId:link.nodeId});
    await report({kind:'follow-receipt',name,receipt});
   }
   const event=await ready;
   if(name==='destination-error'){await report({kind:'case',name,effects_requested,sourceFrame,lifecycle:events,error_policy:'diagnostic_error_only'});continue;}
   if(name==='hash'){if(event.documentId!==sourceFrame.documentId)throw new Error('hash replaced native document');await report({kind:'case',name,effects_requested,sourceFrame,lifecycle:events});continue;}
   const result=await browser.tabs.executeScript(tab.id,{code:'('+sceneSource+')({mode:"read",view:"content",maxChars:20000})',runAt:'document_end'});
   const state=await browser.tabs.executeScript(tab.id,{code:'({url:location.href,ready:document.readyState,text:document.body.innerText})',runAt:'document_end'});
   await report({kind:'observed-before-assertions',name,effects_requested,sourceFrame,error_policy:'observation_only',lifecycle:events,readyEvent:event,state:state[0],sceneUrl:result[0]?.url});
   if(state[0].ready==='complete')throw new Error('unexpected load-complete before blocked image release');
   const finalPath=name==='redirect'?'/final':'/first';
   if(state[0].url!==base+finalPath || event.url!==state[0].url)throw new Error('destination identity mismatch');
   if(state[0].text.split('\n')[0]!=='Observed '+finalPath)throw new Error('fixture heading mismatch');
   const observed=result[0];
   if(observed.url!==event.url)throw new Error('scene URL differs from ready event');
   if(previous && observed.documentId===previous)throw new Error('document identity did not change');
   previous=observed.documentId;
   await report({kind:'case',name,effects_requested,sourceFrame,error_policy:'observation_only',lifecycle:events,readyUrl:event.url,state:state[0],scene:observed});
  } catch(error) {
   await report({kind:'case-failure',name,effects_requested,lifecycle:events,error:String(error)});
   throw error;
  } finally {
   browser.webNavigation.onReferenceFragmentUpdated.removeListener(onHash);
   browser.webNavigation.onBeforeNavigate.removeListener(onBefore);
   browser.tabs.onRemoved.removeListener(onRemoved);
   browser.webNavigation.onCommitted.removeListener(onCommitted);
   browser.webNavigation.onDOMContentLoaded.removeListener(onReady);
   browser.webNavigation.onErrorOccurred.removeListener(onError);
  }
 }
 await report({kind:'done'});
})().catch(error=>report({kind:'failure',error:String(error),stack:error.stack}));
'''.replace('BASE',json.dumps(site)).replace('SCENE',json.dumps(scene)).replace('PRODUCTION',scene+'\n'+interaction)
with zipfile.ZipFile(out/'probe.xpi','w') as z:
 z.writestr('manifest.json',json.dumps({'manifest_version':2,'name':'Owned navigation lifecycle prototype','version':'1.0','permissions':['tabs','webNavigation','http://127.0.0.1/*'],'background':{'scripts':['background.js']},'browser_specific_settings':{'gecko':{'id':'navigation-ready-probe@masc.local'}}}));z.writestr('background.js',script)
with socket.socket() as s:s.bind(('127.0.0.1',0));port=s.getsockname()[1]
log=(out/'driver.txt').open('w');driver=None;sid=None
base=f'http://127.0.0.1:{port}'
def call(path,data=None,method='POST'):
 req=urllib.request.Request(base+path,data=None if data is None else json.dumps(data).encode(),method=method,headers={'Content-Type':'application/json'})
 with urllib.request.urlopen(req,timeout=20) as r:return json.load(r)['value']
failure=None;cleanup=[]
try:
 driver=subprocess.Popen([a.driver,'--host','127.0.0.1','--port',str(port)],stdout=log,stderr=log)
 deadline=time.monotonic()+15
 while True:
  try:call('/status',method='GET');break
  except OSError:
   if driver.poll() is not None or time.monotonic()>deadline:raise
   time.sleep(.05)
 sid=call('/session',{'capabilities':{'alwaysMatch':{'browserName':'firefox','moz:firefoxOptions':{'binary':a.browser,'args':['-headless']}}}})['sessionId']
 call('/session/'+sid+'/moz/addon/install',{'path':str(out/'probe.xpi'),'temporary':True})
 assert finished.wait(30),'no terminal lifecycle result before test deadline'
 assert events[-1]['kind']=='done' and len([e for e in events if e['kind']=='case'])==5,events
except BaseException as error:
 failure=repr(error)
finally:
 release.set()
 def clean(label,action):
  try:action();cleanup.append({'stage':label,'ok':True})
  except BaseException as error:cleanup.append({'stage':label,'ok':False,'error':repr(error)})
 if sid:clean('webdriver session delete',lambda:call('/session/'+sid,method='DELETE'))
 if driver:
  def stop_driver():
   if driver.poll() is None:driver.terminate()
   try:driver.wait(timeout=10)
   except subprocess.TimeoutExpired:driver.kill();driver.wait(timeout=10)
  clean('driver stop',stop_driver)
 clean('HTTP shutdown',srv.shutdown)
 clean('HTTP close',srv.server_close)
 clean('driver log close',log.close)
 proof={'scene_source_sha256':hashlib.sha256(scene.encode()).hexdigest(),
  'source_commit':subprocess.check_output(['git','rev-parse','HEAD'],cwd=source.parents[3],text=True).strip(),
  'probe_sha256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
  'browser_sha256':hashlib.sha256(Path(a.browser).read_bytes()).hexdigest(),
  'driver_sha256':hashlib.sha256(Path(a.driver).read_bytes()).hexdigest(),
  'events_before_resource_release':events,'http_requests':requests,'failure':failure,'cleanup':cleanup,
  'scope':'temporary extension invokes exact production pageInteract follow_link plus reload case; error classification diagnostic only; effects_requested counts requests only','interaction_source_sha256':hashlib.sha256(interaction.encode()).hexdigest()}
 (out/'proof.json').write_text(json.dumps(proof,indent=2))
print(out/'proof.json')
if failure or any(not item['ok'] for item in cleanup):raise SystemExit(1)
