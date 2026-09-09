import argparse
import http.server,threading,json,urllib.request,socket,subprocess,zipfile,time,base64
from pathlib import Path
parser=argparse.ArgumentParser();parser.add_argument('--driver',required=True);parser.add_argument('--browser',required=True);parser.add_argument('--out',type=Path,required=True);args=parser.parse_args()
out=args.out.resolve();out.mkdir(parents=True,exist_ok=True)
done=threading.Event();events=[]
class H(http.server.BaseHTTPRequestHandler):
 def log_message(self,*args):pass
 def do_GET(self):
  data=b'<html><title>Background render fixture</title><main>Loading channel</main></html>'
  self.send_response(200);self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
 def do_POST(self):
  event=json.loads(self.rfile.read(int(self.headers['Content-Length'])));events.append(event)
  if event.get('kind') in ['done','error']:done.set()
  self.send_response(200);self.end_headers()
srv=http.server.ThreadingHTTPServer(('127.0.0.1',0),H);threading.Thread(target=srv.serve_forever,daemon=True).start();url=f'http://127.0.0.1:{srv.server_port}'
handler=(Path(__file__).resolve().parents[1]/'connectors/browser/extension/background.js').read_text().split('async function pageInteract')[1].split('async function onHostMessage')[0]
js='async function pageInteract'+handler+r'''const base=BASE;
const report=value=>fetch(base+'/report',{method:'POST',body:JSON.stringify(value)});
(async()=>{try{
 const keeper=await browser.tabs.create({url:base+'/foreground',active:true});
 const tab=await browser.tabs.create({url:base+'/channel',active:false});
 const read=async()=>({tab:await browser.tabs.get(tab.id),page:(await browser.tabs.executeScript(tab.id,{runAt:'document_end',code:`({visibility:document.visibilityState,ready:document.readyState,text:document.querySelector('main').textContent,at:performance.now(),scheduled:window.scheduledAt,frames:window.frameTimes,rendered:window.renderedAt})` }))[0]});
 await browser.tabs.executeScript(tab.id,{runAt:'document_end',code:`window.scheduledAt=performance.now();window.renderedAt=null;location.hash='dev-frontend';document.title='dev-frontend';window.frameTimes=[];const render=()=>{window.frameTimes.push(performance.now());if(window.frameTimes.length<8)requestAnimationFrame(render);else{window.renderedAt=performance.now();document.querySelector('main').textContent='Rendered channel context';}};requestAnimationFrame(render);`});
 await report({kind:'scheduled',...(await read())});
 await new Promise(resolve=>setTimeout(resolve,3000));
 await report({kind:'background-after-3s',...(await read())});
 const activatedAt=Date.now();const receipt=await pageInteract({tabId:tab.id,action:'activate_tab',expectedUrl:(await browser.tabs.get(tab.id)).url});await report({kind:'activation-receipt',receipt});
 const result=await browser.tabs.executeScript(tab.id,{runAt:'document_end',code:`new Promise(resolve=>{const poll=()=>{if(!window.renderedAt){requestAnimationFrame(poll);return;}resolve({visibility:document.visibilityState,text:document.querySelector('main').textContent,scheduled:window.scheduledAt,frames:window.frameTimes,rendered:window.renderedAt,at:performance.now()});};requestAnimationFrame(poll);})`});
 await report({kind:'done',activationToObservationMs:Date.now()-activatedAt,tab:await browser.tabs.get(tab.id),page:result[0]});
}catch(error){await report({kind:'error',error:String(error)});}})();'''.replace('BASE',json.dumps(url))
xpi=out/'probe.xpi'
with zipfile.ZipFile(xpi,'w') as z:
 z.writestr('manifest.json',json.dumps({'manifest_version':2,'name':'Background visibility experiment','version':'1.0','permissions':['tabs','http://127.0.0.1/*'],'background':{'scripts':['background.js']},'browser_specific_settings':{'gecko':{'id':'visibility-probe@masc.local'}}}));z.writestr('background.js',js)
with socket.socket() as sock:sock.bind(('127.0.0.1',0));port=sock.getsockname()[1]
log=(out/'driver.txt').open('w');driver=subprocess.Popen([args.driver,'--host','127.0.0.1','--port',str(port),'--websocket-port','0'],stdout=log,stderr=log);base=f'http://127.0.0.1:{port}';sid=None
def call(path,data=None,method='POST'):
 req=urllib.request.Request(base+path,data=None if data is None else json.dumps(data).encode(),method=method,headers={'Content-Type':'application/json'})
 with urllib.request.urlopen(req,timeout=30) as r:
  value=json.load(r)['value']
  if isinstance(value,dict) and 'error' in value:raise RuntimeError(value)
  return value
try:
 for _ in range(100):
  try:call('/status',method='GET');break
  except OSError:time.sleep(.05)
 session=call('/session',{'capabilities':{'alwaysMatch':{'browserName':'firefox','moz:firefoxOptions':{'binary':args.browser,'args':['-headless']}}}});sid=session['sessionId']
 call('/session/'+sid+'/moz/addon/install',{'path':str(xpi),'temporary':True})
 finished=done.wait(20)
 (out/'fixture.png').write_bytes(base64.b64decode(call('/session/'+sid+'/screenshot',method='GET')))
 result={'finished':finished,'events':events,'capabilities':session['capabilities'],'scope':'isolated Firefox extension fixture; no user browser or Slack touched'}
 (out/'proof.json').write_text(json.dumps(result,indent=2));print(json.dumps({'finished':finished,'events':[{'kind':e['kind'],'page':e.get('page'),'active':e.get('tab',{}).get('active'),'activationToObservationMs':e.get('activationToObservationMs'),'error':e.get('error')} for e in events]}))
 assert finished and events[-1]['kind']=='done'
 background=next(e for e in events if e['kind']=='background-after-3s')
 receipt=next(e['receipt'] for e in events if e['kind']=='activation-receipt')
 assert background['tab']['active'] is False and background['page']['visibility']=='hidden'
 # Background rendering speed is measured above, not a correctness gate.
 # Browsers that already rendered still must activate the same pinned tab.
 assert receipt['active'] is True and receipt['tabId']==background['tab']['id']
 assert receipt['url']==receipt['urlBefore']==background['tab']['url']
 assert events[-1]['page']['visibility']=='visible' and events[-1]['page']['text']=='Rendered channel context'
finally:
 if sid:call('/session/'+sid,method='DELETE')
 driver.terminate();driver.wait(timeout=10);srv.shutdown();srv.server_close();log.close()
