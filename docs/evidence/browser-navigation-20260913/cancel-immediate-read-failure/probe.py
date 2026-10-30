"""Isolated Firefox lifecycle prototype; never installs into a user profile.
Run only after review: --driver PATH --browser PATH --out NEW_DIRECTORY.
"""
import argparse,hashlib,http.server,json,socket,subprocess,threading,time,urllib.request,zipfile
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--driver',required=True);p.add_argument('--browser',required=True);p.add_argument('--out',type=Path,required=True);p.add_argument('--checkout',type=Path,required=True);p.add_argument('--source-commit',required=True);a=p.parse_args()
out=a.out.resolve();out.mkdir(parents=True,exist_ok=False)
checkout=a.checkout.resolve()
source_commit=subprocess.check_output(['git','rev-parse',a.source_commit+'^{commit}'],cwd=checkout,text=True).strip()
assert source_commit==a.source_commit, 'supply the full pinned commit SHA'
background_bytes=subprocess.check_output(['git','show',source_commit+':connectors/browser/extension/background.js'],cwd=checkout)
background=background_bytes.decode('utf-8')
interaction=background[background.index('function interactInPage(args)'):background.index('async function onHostMessage(')]
scene=background.split('function browserDocument()',1)[0]
assert scene.startswith('function browserScene(args)')
release=threading.Event();finished=threading.Event();events=[];requests=[]
class Handler(http.server.BaseHTTPRequestHandler):
 def log_message(self,*args):pass
 def do_GET(self):
  requests.append({"method":"GET","path":self.path,"time":time.time()})
  if self.path=='/pending':release.wait()
  if self.path=='/release':release.set()
  if self.path=='/broken':
   self.connection.shutdown(2);self.connection.close();return
  if self.path.startswith('/redirect'):
   self.send_response(302);self.send_header('Location','/final');self.end_headers();return
  if self.path.startswith('/slow.png'):
   release.wait();body=b''
  else:
   body=('<html><body><main><h1>Observed '+self.path+'</h1><a href="/pending">pending</a><a href="/first">destination</a><a href="/redirect">redirect</a><a href="#hash">hash</a><a href="/broken">broken</a></main>'+ ('' if self.path=='/initial' else '<img src="/slow.png">')+'</body></html>').encode()
  self.send_response(200);self.send_header('Content-Length',str(len(body)));self.end_headers()
  try:self.wfile.write(body)
  except (BrokenPipeError,ConnectionResetError):pass
 def do_POST(self):
  event=json.loads(self.rfile.read(int(self.headers['Content-Length'])));events.append(event)
  if event['kind'] in ['done','failure']:finished.set()
  self.send_response(200);self.end_headers()
srv=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler);srv.daemon_threads=True
threading.Thread(target=srv.serve_forever,daemon=True).start();site=f'http://127.0.0.1:{srv.server_port}'
assert background.endswith('connect();\n')
script=background[:-len('connect();\n')]+r"""
const fixtureBase=BASE;let sequence=0;
const emit=data=>fetch(fixtureBase+'/report',{method:'POST',body:JSON.stringify(data)});
const dispatch=async(verb,args,duration=10000)=>{const replies=[];await onHostMessage({id:++sequence,verb,args,deadlineMs:Date.now()+duration},{postMessage:r=>replies.push(r)});await emit({kind:'reply',verb,replies});if(replies.length!==1)throw new Error('reply count');return {answer:replies[0],replies};};
(async()=>{
 for(const name of ['closed-tab','read-deadline']){
  const tab=await browser.tabs.create({url:fixtureBase+'/initial'});
  await new Promise((resolve,reject)=>{const changed=(id,c,t)=>{if(id===tab.id&&t.status==='complete'&&t.url===fixtureBase+'/initial'){browser.tabs.onUpdated.removeListener(changed);resolve();}};browser.tabs.onUpdated.addListener(changed);browser.tabs.get(tab.id).then(t=>changed(tab.id,{},t),reject);});
  const nativeEvents=[];const listeners=[];
  for(const type of ['onBeforeNavigate','onCommitted','onErrorOccurred']){const fn=d=>{if(d.tabId===tab.id&&d.frameId===0)nativeEvents.push({type,details:d});};browser.webNavigation[type].addListener(fn);listeners.push([type,fn]);}
  try{
   const source=(await dispatch('page.scene',{tabId:tab.id,view:'content',maxChars:20000})).answer.data;
   const link=source.nodes.find(n=>n.href===fixtureBase+'/pending');if(!link)throw new Error('pending link absent');
   const follow=await dispatch('page.interact',{tabId:tab.id,action:'follow_link',expectedUrl:source.url,documentId:source.documentId,nodeId:link.nodeId},10000);
   if(!follow.answer.ok)throw new Error('follow refused');
   const read=dispatch('page.scene',{tabId:tab.id,view:'content',maxChars:20000},name==='read-deadline'?100:10000);
   if(name==='closed-tab')await browser.tabs.remove(tab.id);
   const rejected=await read;if(rejected.answer.ok)throw new Error('pending read unexpectedly succeeded');
   if(nativeEvents.some(e=>e.type==='onCommitted'))throw new Error('withheld destination committed early');
   if(name==='read-deadline'){
    await fetch(fixtureBase+'/release');
    const fresh=await dispatch('page.scene',{tabId:tab.id,view:'content',maxChars:20000});
    if(!fresh.answer.ok||fresh.answer.data.url!==fixtureBase+'/pending')throw new Error('fresh observation unavailable after release');
    if(rejected.replies.length!==1)throw new Error('expired reply revived');
    await emit({kind:'fresh-read',answer:fresh.answer});await browser.tabs.remove(tab.id);
   }
   await emit({kind:'case',name,follow:follow.answer,rejected:rejected.answer,nativeEvents});
  }finally{for(const[type,fn]of listeners)browser.webNavigation[type].removeListener(fn);}
 }
 await emit({kind:'done'});
})().catch(error=>emit({kind:'failure',error:String(error),stack:error.stack}));
""".replace('BASE',json.dumps(site))
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
 assert events[-1]['kind']=='done' and len([e for e in events if e['kind']=='case'])==2,events
except BaseException as error:
 failure=repr(error)
finally:
 before_release=json.loads(json.dumps(events))
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
  'source_commit':source_commit,
  'probe_sha256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
  'browser_sha256':hashlib.sha256(Path(a.browser).read_bytes()).hexdigest(),
  'driver_sha256':hashlib.sha256(Path(a.driver).read_bytes()).hexdigest(),
  'events_before_resource_release':before_release,'http_requests':requests,'failure':failure,'cleanup':cleanup,
  'scope':'exact candidate background with final connect disabled; manual onHostMessage replies with synthetic 10000ms per-command deadlines (native host uses 20000ms); no native MASC server/host proof','background_sha256':hashlib.sha256(background.encode()).hexdigest(),'interaction_source_sha256':hashlib.sha256(interaction.encode()).hexdigest()}
 (out/'proof.json').write_text(json.dumps(proof,indent=2))
print(out/'proof.json')
if failure or any(not item['ok'] for item in cleanup):raise SystemExit(1)
