#!/usr/bin/env python3
"""Real Gecko scene contract probe; needs existing geckodriver/browser binaries."""
import argparse,base64,hashlib,http.server,json,socket,subprocess,threading,time,urllib.request,urllib.error
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--driver',required=True);p.add_argument('--browser',required=True);p.add_argument('--out',type=Path,required=True);a=p.parse_args();a.out.mkdir(parents=True,exist_ok=True)
root=Path(__file__).resolve().parents[1]
scene=(root/'lib/browser_scene_script.ml').read_text().split('let runtime = {js|',1)[1].split('|js}',1)[0]
interaction=(root/'lib/browser_interaction.ml').read_text().split('let script = {js|',1)[1].split('|js}',1)[0]
guard=(root/'lib/browser_interaction.ml').read_text().split('let pointer_guard_script = {js|',1)[1].split('|js}',1)[0]
bg=(root/'connectors/browser/extension/background.js').read_text();assert bg.startswith(scene+'\n'), 'scene runtime differs between extension and driver'
html='''<!doctype html><meta charset="utf-8"><title>Semantic Zen fixture</title><style>body{font:22px sans-serif;margin:28px;background:#101d2c;color:#d8f4ee}.grid{display:grid;grid-template-columns:1fr 1fr;gap:20px}section{padding:24px;border:1px solid #55958c;border-radius:16px}button,textarea{font:inherit;padding:10px}canvas{background:linear-gradient(45deg,#3baaa0,#662db1)}.hidden{display:none}</style><h1>한글과 실제 DOM</h1><p>Copy exact text: 별빛🙂 café</p><div style="visibility:hidden">HIDDEN_PARENT<span style="visibility:visible">VISIBLE_CHILD</span></div><div class="grid"><section><button id="increment" onclick="document.querySelector('#count').textContent=String(+document.querySelector('#count').textContent+1)">Increase</button><p id="count">0</p><label>Message<textarea id="message" aria-label="Message"></textarea></label><input type="password" value="SECRET_VALUE_MUST_NOT_APPEAR"></section><section><canvas width="180" height="100" style="font-size:0" aria-label="Gradient canvas"></canvas><p class="hidden">HIDDEN_MUST_NOT_APPEAR</p></section></div>'''
class H(http.server.BaseHTTPRequestHandler):
 def do_GET(self):
  if self.path == '/redirect':
   self.send_response(302);self.send_header('Location','/canonical');self.send_header('Content-Length','0');self.end_headers();return
  b=html.encode();self.send_response(200);self.send_header('Content-Type','text/html; charset=utf-8');self.send_header('Content-Length',str(len(b)));self.end_headers();self.wfile.write(b)
 def log_message(self,*args):pass
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),H);threading.Thread(target=server.serve_forever,daemon=True).start()
with socket.socket() as sock:sock.bind(('127.0.0.1',0));driver_port=sock.getsockname()[1]
log=(a.out/'driver.log').open('wb');driver=subprocess.Popen([a.driver,'--host','127.0.0.1','--port',str(driver_port),'--websocket-port','0'],stdout=log,stderr=log)
base=f'http://127.0.0.1:{driver_port}';sid=None;checks=[]
def call(method,path,body=None):
 req=urllib.request.Request(base+path,data=None if body is None else json.dumps(body).encode(),method=method,headers={'Content-Type':'application/json'})
 try:
  with urllib.request.urlopen(req,timeout=30) as res:raw=res.read()
 except urllib.error.HTTPError as e:raw=e.read()
 value=json.loads(raw)['value']
 if isinstance(value,dict) and 'error' in value:raise RuntimeError(value['error']+': '+value.get('message',''))
 return value

def js(script,args=[]):
 value=call('POST','/session/'+sid+'/execute/sync',{'script':script,'args':args})
 if isinstance(value,dict) and 'interactionFailure' in value:raise RuntimeError(value['interactionFailure']['message'])
 return value
def observe():return js(scene+'\nreturn browserScene(arguments[0]);',[{'mode':'read','maxChars':50000}])
def control(s,label):return next(n for n in s['nodes'] if n['kind']=='control' and n['text']==label)
def act(s,n,**kw):return js(scene+interaction,[{'documentId':s['documentId'],'nodeId':n['nodeId'],'expectedUrl':s['url'],**kw}])
def check(name,condition):
 assert condition,name;checks.append(name)
try:
 deadline=time.monotonic()+10
 while True:
  try:call('GET','/status');break
  except (urllib.error.URLError,ConnectionError):
   if time.monotonic()>deadline:raise
   time.sleep(.05)
 caps=call('POST','/session',{'capabilities':{'alwaysMatch':{'browserName':'firefox','moz:firefoxOptions':{'binary':a.browser,'args':['-headless']}}}});sid=caps['sessionId']
 call('POST','/session/'+sid+'/url',{'url':f'http://127.0.0.1:{server.server_port}/'})
 before=js('return document.documentElement.outerHTML;');start=time.monotonic();s=observe();elapsed=(time.monotonic()-start)*1000
 (a.out/'scene.json').write_text(json.dumps(s,ensure_ascii=False,indent=2))
 check('scene does not mutate page DOM/CSS',before==js('return document.documentElement.outerHTML;'))
 text=''.join(n['text'] for n in s['nodes']);check('Unicode survives as real text','별빛🙂 café' in text)
 check('hidden text and password value absent','HIDDEN_MUST_NOT_APPEAR' not in text and 'SECRET_VALUE_MUST_NOT_APPEAR' not in json.dumps(s))
 check('visibility override preserves visible descendant','VISIBLE_CHILD' in text and 'HIDDEN_PARENT' not in text)
 check('raster fallback includes zero-font-size canvas',any(n['kind']=='raster' and n['fontSize']==0 for n in s['nodes']))
 button=control(s,'Increase');s2=observe();check('stable identity between reads',button['nodeId']==control(s2,'Increase')['nodeId'] and s['documentId']==s2['documentId'])
 js("document.querySelector('#increment').parentElement.append(document.querySelector('#increment'));")
 act(s,button,action='click');check('reordering does not retarget click',js("return document.querySelector('#count').textContent;")=='1')
 message=control(s,'Message');payload='별빛🙂 café\nexact final LF\n';act(s,message,action='fill',text=payload)
 check('reference fill preserves exact Unicode and final LF',js("return document.querySelector('#message').value;")==payload)
 js("const old=document.querySelector('#increment');old.replaceWith(old.cloneNode(true));")
 try:act(s,button,action='click');raise AssertionError('replaced element accepted')
 except RuntimeError as e:check('replaced node fails rather than clicking replacement','scene_node_detached' in str(e))
 s3=observe();check('replacement gets a new reference',control(s3,'Increase')['nodeId']!=button['nodeId'])
 call('POST','/session/'+sid+'/refresh',{})
 try:act(s3,control(s3,'Increase'),action='click');raise AssertionError('reload accepted old reference')
 except RuntimeError as e:check('same-URL reload rejects old document','scene_document_changed' in str(e))
 latest=observe();check('same-URL reload gets new document ID',latest['documentId']!=s['documentId'])
 # Screenshot positions are normalized CSS viewport coordinates, independent of PNG scale.
 viewport=js(scene+"\nreturn browserScene({mode:'viewport'});")
 point=js("const r=document.querySelector('#increment').getBoundingClientRect();return {x:(r.x+r.width/2)/innerWidth,y:(r.y+r.height/2)/innerHeight};")
 args={'action':'click_at','point':point,'viewport':viewport,'expectedUrl':latest['url']}
 js(scene+interaction,[args]);check('screenshot point clicks observed button',js("return document.querySelector('#count').textContent;")=='1')
 js("window.pointerEvents=[];document.addEventListener('pointerdown',e=>pointerEvents.push({type:e.type,trusted:e.isTrusted,x:e.clientX,y:e.clientY}));document.addEventListener('pointerup',e=>pointerEvents.push({type:e.type,trusted:e.isTrusted,x:e.clientX,y:e.clientY}));")
 js(scene+guard,[args])
 def move(p):return {'type':'pointerMove','duration':0,'origin':'viewport','x':int(p['x']*viewport['width']),'y':int(p['y']*viewport['height'])}
 destination={'x':point['x']+.15,'y':point['y']+.1}
 call('POST','/session/'+sid+'/actions',{'actions':[{'type':'pointer','id':'masc-browser-pointer','parameters':{'pointerType':'mouse'},'actions':[move(point),{'type':'pointerDown','button':0},move(destination),{'type':'pointerUp','button':0}]}]})
 call('DELETE','/session/'+sid+'/actions')
 events=js('return pointerEvents;')
 check('native drag produces trusted press and release at distinct coordinates',len(events)==2 and all(e['trusted'] for e in events) and events[0]['x']!=events[1]['x'] and events[0]['y']!=events[1]['y'])
 js("document.body.style.minHeight='3000px';window.scrollTo(0,200);")
 try:js(scene+interaction,[args]);raise AssertionError('stale viewport accepted')
 except RuntimeError as e:check('scroll invalidates screenshot point','observed_viewport_changed' in str(e))
 js('window.scrollTo(0,0);')
 call('POST','/session/'+sid+'/refresh',{})
 try:js(scene+guard,[args]);raise AssertionError('reloaded screenshot accepted')
 except RuntimeError as e:check('reload invalidates native pointer gesture','observed_viewport_changed' in str(e))

 js("document.body.innerHTML='<h1>Nested browser panes</h1><section id=messages style=\"position:absolute;left:20px;top:100px;width:350px;height:220px;overflow:auto\"></section><section id=sidebar style=\"position:absolute;left:450px;top:100px;width:350px;height:220px;overflow:auto\"></section>';for(const id of ['messages','sidebar'])document.getElementById(id).innerHTML=Array.from({length:80},(_,i)=>'<p>'+id+' message '+i+'</p>').join('');")
 viewport=js(scene+"\nreturn browserScene({mode:'viewport'});")
 point=js("const r=document.querySelector('#messages').getBoundingClientRect();return {x:(r.x+r.width/2)/innerWidth,y:(r.y+r.height/2)/innerHeight};")
 args={'action':'scroll_at','point':point,'viewport':viewport,'expectedUrl':latest['url'],'x':0,'y':120}
 js(scene+interaction,[args])
 positions=js("return {messages:document.querySelector('#messages').scrollTop,sidebar:document.querySelector('#sidebar').scrollTop,root:scrollY};")
 check('live point scroll moves only the selected nested pane',positions=={'messages':120,'sidebar':0,'root':0})
 js("document.querySelector('#messages').scrollTop=0;window.wheelTrusted=false;document.addEventListener('wheel',e=>window.wheelTrusted=e.isTrusted);")
 js(scene+guard,[args])
 call('POST','/session/'+sid+'/actions',{'actions':[{'type':'wheel','id':'masc-browser-wheel','actions':[{'type':'scroll','duration':0,'origin':'viewport','x':int(point['x']*viewport['width']),'y':int(point['y']*viewport['height']),'deltaX':0,'deltaY':160}]}]})
 # Match production: guard, wheel, page metadata, capture, metadata.
 # A wheel does not enter pressed-pointer release cleanup.
 js('return {url:location.href,title:document.title};')
 js(scene+"\nreturn browserScene({mode:'viewport'});")
 wheel_png=call('GET','/session/'+sid+'/screenshot')
 js('return {url:location.href,title:document.title};')
 js(scene+"\nreturn browserScene({mode:'viewport'});")
 positions=js("return {messages:document.querySelector('#messages').scrollTop,sidebar:document.querySelector('#sidebar').scrollTop,root:scrollY,trusted:wheelTrusted};")
 check('native wheel scroll is trusted and targets the nested pane',positions['messages']>0 and positions['sidebar']==0 and positions['root']==0 and positions['trusted'])
 # Exercise negative scroll positions used by reverse-flow chat timelines.
 js("const p=document.querySelector('#messages');p.style.display='flex';p.style.flexDirection='column-reverse';for(const n of p.children)n.style.flexShrink='0';p.scrollTop=0;")
 viewport=js(scene+"\nreturn browserScene({mode:'viewport'});")
 args.update(viewport=viewport,y=-120)
 js(scene+interaction,[args])
 reverse=js("return {pane:document.querySelector('#messages').scrollTop,root:scrollY};")
 check('reverse-flow chat scroll consumes negative position in its own pane',reverse['pane']==-120 and reverse['root']==0)
 js("const pane=document.querySelector('#messages');pane.style.display='block';pane.scrollTop=0;pane.setAttribute('aria-label','채널 메시지');document.querySelector('#sidebar').setAttribute('aria-label','채널 목록');pane.insertAdjacentHTML('afterbegin','<a href=\"#thread\">Observed thread</a>');")
 regions=js(scene+"\nreturn browserScene(arguments[0]);",[{'mode':'read','view':'regions','maxChars':5000}])
 region=next(n for n in regions['nodes'] if n['text']=='채널 메시지')
 scope={'documentId':regions['documentId'],'nodeId':region['nodeId']}
 scoped=js(scene+"\nreturn browserScene(arguments[0]);",[{'mode':'read','scope':scope,'maxChars':5000}])
 whole=observe()
 check('semantic outline identifies actual page regions',len(regions['nodes'])==2 and all(n['kind']=='region' for n in regions['nodes']))
 check('scoped read excludes the sidebar',all('sidebar' not in n['text'] for n in scoped['nodes']))
 check('overflow-clipped messages are excluded from scene',not any('messages message 5' in n['text'] for n in scoped['nodes']))
 check('scoped read returns fewer bytes than whole visible scene',len(json.dumps(scoped))<len(json.dumps(whole)))
 link=control(scoped,'Observed thread');act(scoped,link,action='click')
 check('scoped link retains usable observed click reference',js('return location.hash;')=='#thread')
 refreshed=js(scene+"\nreturn browserScene(arguments[0]);",[{'mode':'read','scope':scope,'maxChars':5000}])
 check('same-document link refresh preserves region scope',refreshed['scope']==scope and all('sidebar' not in n['text'] for n in refreshed['nodes']))
 region_measurement={'whole_scene_bytes':len(json.dumps(whole,ensure_ascii=False).encode()),'scoped_scene_bytes':len(json.dumps(scoped,ensure_ascii=False).encode()),'regions_bytes':len(json.dumps(regions,ensure_ascii=False).encode())}
 (a.out/'regions.json').write_text(json.dumps({'outline':regions,'scoped':scoped,'measurement':region_measurement},ensure_ascii=False,indent=2))
 js("const pane=document.querySelector('#messages');pane.replaceWith(pane.cloneNode(true));")
 try:js(scene+"\nreturn browserScene(arguments[0]);",[{'mode':'read','scope':scope,'maxChars':5000}]);raise AssertionError('detached scope accepted')
 except RuntimeError as e:check('replaced region rejects old scope','scene_node_detached' in str(e))
 js("document.body.innerHTML='<header>Site banner</header><div role=banner>ARIA banner</div><footer>Site footer</footer><div role=contentinfo>ARIA footer</div><search>Native search</search><div role=search>ARIA search</div><form aria-label=Filters>Form body</form><div role=form aria-label=Preferences>Preferences body</div>';")
 landmarks=js(scene+"\nreturn browserScene(arguments[0]);",[{'mode':'read','view':'regions','maxChars':5000}])
 check('outline includes native and ARIA standard landmarks',len(landmarks['nodes'])==8)
 for landmark in landmarks['nodes']:
  selected={'documentId':landmarks['documentId'],'nodeId':landmark['nodeId']}
  read=js(scene+"\nreturn browserScene(arguments[0]);",[{'mode':'read','scope':selected,'maxChars':5000}])
  check('landmark scope reads '+landmark['text'],read['scope']==selected and len(read['nodes'])==1)
 js("document.body.innerHTML='<div style=\"overflow:hidden;width:50px;height:50px\"><div style=\"position:fixed;left:400px;top:120px\"><button id=popup>Visible fixed popup</button></div></div>';")
 popup_scene=observe()
 popup=control(popup_scene,'Visible fixed popup')
 check('fixed popup escapes overflow ancestor and remains observable',bool(popup['rects']))
 js("document.querySelector('#popup').onclick=()=>document.body.dataset.popupClicked='yes';")
 act(popup_scene,popup,action='click')
 check('escaped fixed popup observed reference remains clickable',js('return document.body.dataset.popupClicked;')=='yes')
 js("document.body.innerHTML='<a id=follow href=\"#destination\" target=\"_blank\">Follow observed link</a><p>Previous channel content</p>';window.followHandlerRan=false;document.querySelector('#follow').onclick=()=>{window.followHandlerRan=true;};")
 follow_scene=observe();follow_node=control(follow_scene,'Follow observed link')
 try:act(follow_scene,follow_node,action='follow_link');raise AssertionError('new-tab follow accepted')
 except RuntimeError as e:check('observed new-tab anchor rejects before follow','follow_link_requires_same_tab' in str(e))
 check('rejected follow keeps original URL',js('return location.href;')==follow_scene['url'])
 js("document.querySelector('#follow').target='_self';")
 js("document.querySelector('#follow').href='#recycled-channel';")
 try:act(follow_scene,follow_node,action='follow_link');raise AssertionError('recycled anchor followed')
 except RuntimeError as e:check('recycled anchor href rejects before navigation','scene_link_destination_changed' in str(e) and js('return location.href;')==follow_scene['url'])
 recycled_scene=observe();recycled_node=control(recycled_scene,'Follow observed link')
 check('new observation exposes changed href under a new reference',recycled_node['nodeId']!=follow_node['nodeId'] and recycled_node['href'].endswith('#recycled-channel'))
 try:act(follow_scene,follow_node,action='follow_link');raise AssertionError('new observation repinned old reference')
 except RuntimeError as e:check('new observation does not overwrite old destination pin','scene_link_destination_changed' in str(e))
 js("document.querySelector('#follow').href='#destination';")
 receipt=act(follow_scene,follow_node,action='follow_link')
 after_follow=observe()
 check('observed same-tab href reaches destination URL',after_follow['url']==receipt['destinationUrl'])
 check('follow bypasses application click handler',not js('return window.followHandlerRan;'))
 check('SPA URL acknowledgement does not imply destination content readiness',after_follow['documentId']==follow_scene['documentId'] and any(n['text']=='Previous channel content' for n in after_follow['nodes']))
 js("document.body.innerHTML='<div id=host></div>';const outer=document.querySelector('#host').attachShadow({mode:'open'});outer.innerHTML='<div id=inner></div>';const inner=outer.querySelector('#inner').attachShadow({mode:'open'});inner.innerHTML='<div id=pane style=\"height:180px;width:400px;overflow:auto\"><div style=\"height:1600px\">Shadow channel context</div></div>';window.shadowPane=inner.querySelector('#pane');window.scrollTo(0,0);")
 viewport=js(scene+"\nreturn browserScene({mode:'viewport'});")
 point=js("const r=shadowPane.getBoundingClientRect();return {x:(r.x+30)/innerWidth,y:(r.y+30)/innerHeight};")
 js(scene+interaction,[{'action':'scroll_at','point':point,'viewport':viewport,'expectedUrl':js('return location.href;'),'x':0,'y':120}])
 positions=js('return {pane:shadowPane.scrollTop,root:scrollY};')
 check('nested open shadow roots scroll the internal pane without moving the page',positions=={'pane':120,'root':0})
 # Same-origin frame inside an open shadow tree, with another frame nested inside.
 js("""document.body.innerHTML='<div id=host></div><div style=height:3000px>Outer document</div>';const r=document.querySelector('#host').attachShadow({mode:'open'});r.innerHTML='<iframe style="width:500px;height:300px;border:7px solid"></iframe>';window.frame=r.querySelector('iframe');const d=frame.contentDocument;d.open();d.write('<body style=margin:0><iframe id=nested style="width:400px;height:220px;border:5px solid"></iframe>');d.close();window.nested=frame.contentDocument.querySelector('#nested');const n=nested.contentDocument;n.open();n.write('<body style=margin:0><div id=pane style="overflow:auto;height:150px"><div style=height:1600px>Frame channel</div></div><div style=height:2000px>Frame root</div>');n.close();window.scrollTo(0,0);""")
 viewport=js(scene+"\nreturn browserScene({mode:'viewport'});")
 point=js("const a=frame.getBoundingClientRect(),b=nested.getBoundingClientRect();return {x:(a.left+frame.clientLeft+b.left+nested.clientLeft+30)/innerWidth,y:(a.top+frame.clientTop+b.top+nested.clientTop+30)/innerHeight};")
 frame_args={'action':'scroll_at','point':point,'viewport':viewport,'expectedUrl':js('return location.href;'),'x':0,'y':120}
 js(scene+interaction,[frame_args])
 check('nested same-origin frames inside shadow root scroll only the pointed pane',js("return {pane:nested.contentDocument.querySelector('#pane').scrollTop,inner:nested.contentWindow.scrollY,frame:frame.contentWindow.scrollY,outer:scrollY};")=={'pane':120,'inner':0,'frame':0,'outer':0})
 js("nested.contentDocument.querySelector('#pane').style.overflow='hidden';")
 js(scene+interaction,[frame_args])
 check('frame fallback scrolls deepest document only',js('return {inner:nested.contentWindow.scrollY,frame:frame.contentWindow.scrollY,outer:scrollY};')=={'inner':120,'frame':0,'outer':0})
 js("frame.style.transform='rotate(5deg)';")
 try:js(scene+interaction,[frame_args]);raise AssertionError('transformed frame accepted')
 except RuntimeError as e:check('transformed frame rejects without outer scroll','scroll_frame_geometry_unsupported' in str(e) and js('return scrollY;')==0)
 js("frame.style.transform='none';frame.setAttribute('sandbox','');frame.srcdoc='<div style=height:3000px>Opaque frame</div>';")
 # WebDriver's async callback follows the frame load; no guessed settling sleep.
 call('POST','/session/'+sid+'/execute/async',{'script':"const done=arguments[arguments.length-1];if(!frame.contentDocument)done();else frame.addEventListener('load',()=>done(),{once:true});",'args':[]})
 try:js(scene+interaction,[frame_args]);raise AssertionError('opaque frame accepted')
 except RuntimeError as e:check('inaccessible frame rejects without outer scroll','scroll_frame_inaccessible' in str(e) and js('return scrollY;')==0)
 js("document.body.innerHTML='<a href=\"/redirect\">Canonical channel link</a>';")
 redirect_source=observe();redirect_link=control(redirect_source,'Canonical channel link')
 redirect_receipt=act(redirect_source,redirect_link,action='follow_link')
 first_redirect_observation=observe()
 # Reobserve URL and pixels after the initial scene; none of these receipts
 # alone declares that the requested application content has been verified.
 call('GET','/session/'+sid+'/url')
 call('GET','/session/'+sid+'/screenshot')
 redirected=observe()
 check('HTTP302 final observation differs from original href',redirect_receipt['destinationUrl'].endswith('/redirect') and redirected['url'].endswith('/canonical'))
 check('redirect recovery reads actual destination content',any(n['text']=='Copy exact text: 별빛🙂 café' for n in redirected['nodes']))
 (a.out/'redirect.json').write_text(json.dumps({'follow':redirect_receipt,'first_observed_url':first_redirect_observation['url'],'observed_url':redirected['url'],'title':redirected['title'],'application_verified':False},ensure_ascii=False,indent=2))
 png=base64.b64decode(call('GET','/session/'+sid+'/screenshot'),validate=True);(a.out/'fixture.png').write_bytes(png)
 report={'checks':checks,'scene_elapsed_ms':elapsed,'scene_json_utf8_bytes':len(json.dumps(s,ensure_ascii=False,separators=(',',':')).encode()),'png_bytes':len(png),'png_sha256':hashlib.sha256(png).hexdigest(),'scene_runtime_sha256':hashlib.sha256(scene.encode()).hexdigest(),'browser_capabilities':caps['capabilities'],'scope':'real Gecko executes shared scripts; OCaml HTTP/TUI binary not measured by this probe'}
 (a.out/'proof.json').write_text(json.dumps(report,indent=2));print(json.dumps({k:v for k,v in report.items() if k!='browser_capabilities'}))
finally:
 if sid:
  try:call('DELETE','/session/'+sid)
  except (urllib.error.URLError,RuntimeError):pass
 driver.terminate();driver.wait(timeout=5);log.close();server.shutdown();server.server_close()
