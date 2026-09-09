import argparse
import http.server,threading,json,urllib.request,socket,subprocess,tempfile,zipfile,time
from pathlib import Path
parser=argparse.ArgumentParser();parser.add_argument('--driver',required=True);parser.add_argument('--browser',required=True);parser.add_argument('--out',type=Path,required=True);a=parser.parse_args()
out=a.out.resolve();out.mkdir(parents=True,exist_ok=True)
release=threading.Event();start=threading.Event();events=[]
class H(http.server.BaseHTTPRequestHandler):
 def log_message(self,*a):pass
 def do_GET(self):
  if self.path=='/slow.png':release.wait(20);data=b''
  else:data=b'<html><body><main>Visible channel context</main><img src="/slow.png"></body></html>'
  self.send_response(200);self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
 def do_POST(self):
  d=json.loads(self.rfile.read(int(self.headers['Content-Length'])));events.append(d)
  if d.get('kind')=='early':start.set()
  self.send_response(200);self.end_headers()
srv=http.server.ThreadingHTTPServer(('127.0.0.1',0),H);threading.Thread(target=srv.serve_forever,daemon=True).start();url=f'http://127.0.0.1:{srv.server_port}'
js='''const base=BASE; let started=false;
const report = value => fetch(base+'/report',{method:'POST',body:JSON.stringify(value)});
browser.tabs.onUpdated.addListener(async (id,change,tab)=>{
 if(started || tab.url!==base+'/fixture' || change.status!=='loading')return;
 started=true;
 const code="({ready:document.readyState,text:document.body?.innerText||''})";
 browser.tabs.executeScript(id,{code}).then(x=>report({kind:'default',value:x}),e=>report({kind:'default-error',error:String(e)}));
 browser.tabs.executeScript(id,{code,runAt:'document_end'}).then(x=>report({kind:'early',value:x}),e=>report({kind:'early-error',error:String(e)}));
});
browser.tabs.create({url:base+'/fixture'});
'''.replace('BASE',json.dumps(url))
xpi=out/'probe.xpi'
with zipfile.ZipFile(xpi,'w') as z:
 z.writestr('manifest.json',json.dumps({'manifest_version':2,'name':'Browser injection timing fixture','version':'1.0','permissions':['tabs','http://127.0.0.1/*'],'background':{'scripts':['background.js']},'browser_specific_settings':{'gecko':{'id':'timing-probe@masc.local'}}}));z.writestr('background.js',js)
with socket.socket() as s:s.bind(('127.0.0.1',0));port=s.getsockname()[1]
log=(out/'driver.txt').open('w');driver=subprocess.Popen([a.driver,'--host','127.0.0.1','--port',str(port),'--websocket-port','0'],stdout=log,stderr=log);base=f'http://127.0.0.1:{port}';sid=None
def call(path,data=None,method='POST'):
 req=urllib.request.Request(base+path,data=None if data is None else json.dumps(data).encode(),method=method,headers={'Content-Type':'application/json'})
 with urllib.request.urlopen(req,timeout=30) as r:return json.load(r)['value']
try:
 for _ in range(100):
  try:call('/status',method='GET');break
  except OSError:time.sleep(.05)
 sid=call('/session',{'capabilities':{'alwaysMatch':{'browserName':'firefox','moz:firefoxOptions':{'binary':a.browser,'args':['-headless']}}}})['sessionId']
 call('/session/'+sid+'/moz/addon/install',{'path':str(xpi),'temporary':True})
 observed=start.wait(15)
 before=list(events);release.set()
 for _ in range(100):
  if any(e.get('kind')=='default' for e in events):break
  time.sleep(.05)
 result={'early_observed':observed,'before_resource_release':before,'after_resource_release':events};(out/'proof.json').write_text(json.dumps(result,indent=2));print(json.dumps(result),flush=True)
 assert observed and any(e.get('kind')=='early' and e['value'][0]['text']=='Visible channel context' for e in before),result
 assert not any(e.get('kind')=='default' for e in before),result
 assert any(e.get('kind')=='default' for e in events),result
finally:
 release.set()
 try:
  if sid:call('/session/'+sid,method='DELETE')
 finally:
  try:
   driver.terminate()
   driver.wait(timeout=10)
  finally:
   try:
    srv.shutdown()
   finally:
    try:srv.server_close()
    finally:log.close()
