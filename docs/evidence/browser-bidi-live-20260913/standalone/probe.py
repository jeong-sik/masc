import base64,hashlib,json,pathlib,socket,subprocess,tempfile,time,traceback,urllib.parse
import websocket
out=pathlib.Path(tempfile.mkdtemp(prefix='masc-bidi-pointer-',dir='/tmp')); profile=out/'profile';profile.mkdir()
log=(out/'firefox.log').open('wb'); sock=socket.socket();sock.bind(('127.0.0.1',0));port=sock.getsockname()[1];sock.close()
binary='/Applications/Firefox.app/Contents/MacOS/firefox'
cmd=[binary,'--headless','--no-remote','--profile',str(profile),'--remote-debugging-port',str(port)]
p=subprocess.Popen(cmd,stdout=log,stderr=log); ws=None; receipts=[]; seq=0; report={'command':cmd,'pid':p.pid,'success':False}
def call(method,params):
 global seq
 seq+=1; req={'id':seq,'method':method,'params':params}; ws.send(json.dumps(req))
 while True:
  reply=json.loads(ws.recv());receipts.append({'request':req,'reply':reply})
  if reply.get('id')==seq:
   if reply.get('type')=='error':raise RuntimeError(reply)
   return reply['result']
def read(ctx):
 r=call('script.evaluate',{'expression':'JSON.stringify({url:location.href,text:document.body.innerText,events:window.events})','target':{'context':ctx},'awaitPromise':False})
 assert r['type']=='success',r
 return json.loads(r['result']['value'])
def shot(ctx,name):
 r=call('browsingContext.captureScreenshot',{'context':ctx});(out/name).write_bytes(base64.b64decode(r['data']))
try:
 deadline=time.monotonic()+20
 while True:
  try:ws=websocket.create_connection(f'ws://127.0.0.1:{port}/session',timeout=10,suppress_origin=True);break
  except (ConnectionRefusedError,OSError):
   if p.poll() is not None or time.monotonic()>deadline:raise
   time.sleep(.1)
 report['session']=call('session.new',{'capabilities':{}})
 html='''<!doctype html><title>Owned BiDi drag fixture</title><style>#pad{width:450px;height:250px;background:lightblue}body{margin:0}</style><div id="pad">Drag this area</div><pre id="status">untouched</pre><script>window.events=[];let held=false;for(const type of ['pointerdown','pointermove','pointerup'])document.querySelector('#pad').addEventListener(type,e=>{if(type==='pointerdown')held=true;if(held){events.push({type:e.type,trusted:e.isTrusted,x:e.clientX,y:e.clientY});document.querySelector('#status').textContent=JSON.stringify(events)}if(type==='pointerup')held=false;});</script>'''
 (out/'fixture.html').write_text(html);url='data:text/html,'+urllib.parse.quote(html)
 contexts=[call('browsingContext.create',{'type':'tab'})['context'] for _ in range(2)]
 for ctx in contexts:call('browsingContext.navigate',{'context':ctx,'url':url,'wait':'interactive'})
 report['tree']=call('browsingContext.getTree',{});report['contexts']=contexts
 before=[read(c) for c in contexts]; assert before[0]==before[1] and before[0]['events']==[]
 report['before']=before;shot(contexts[0],'before.png')
 for i,ctx in enumerate(contexts):
  call('input.performActions',{'context':ctx,'actions':[{'type':'pointer','id':'mouse','parameters':{'pointerType':'mouse'},'actions':[{'type':'pointerMove','x':40,'y':40},{'type':'pointerDown','button':0},{'type':'pointerMove','x':180+i*30,'y':120,'duration':150},{'type':'pointerUp','button':0}]}]})
  call('input.releaseActions',{'context':ctx})
  state=[read(c) for c in contexts];events=state[i]['events'];assert events[0]['type']=='pointerdown' and events[-1]['type']=='pointerup' and all(e['trusted'] for e in events);assert events[-1]['x']==180+i*30
  if i==0:assert state[1]==before[1];report['after_first']=state
  else:assert state[0]==report['after_first'][0]
  shot(ctx,f'after-{i}.png')
 report['after']=state;report['success']=True
except BaseException:
 report['error']=traceback.format_exc()
finally:
 try:
  if ws:
   try:call('session.end',{})
   except BaseException:report['session_cleanup_error']=traceback.format_exc()
   finally:ws.close()
 finally:
  if p.poll() is None:
   p.terminate()
   try:p.wait(timeout=10)
   except subprocess.TimeoutExpired:p.kill();p.wait(timeout=5)
  log.close();report['process_returncode']=p.returncode;report['owned_process_exited']=p.poll() is not None
  (out/'receipts.json').write_text(json.dumps(receipts,indent=2));(out/'report.json').write_text(json.dumps(report,indent=2))
  (out/'probe.py').write_bytes(pathlib.Path(__file__).read_bytes())
  (out/'SHA256SUMS').write_text(''.join(hashlib.sha256(f.read_bytes()).hexdigest()+'  '+f.name+'\n' for f in sorted(out.iterdir()) if f.is_file()))
print(json.dumps({'out':str(out),'success':report['success'],'error':report.get('error'),'cleanup':report['owned_process_exited']}))
