"""Loopback-only interaction pilot; page events are the completion authority."""
import json
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

ROOT = Path(__file__).resolve().parent
LOCK = threading.Lock()
EVENTS = {}
HTML = r'''<!doctype html><html lang="en"><meta charset="utf-8">
<title>Browser interaction pilot</title>
<style>
body {font:18px system-ui;margin:32px;color:#172337;background:#f4f6fa}
button {font:inherit;padding:16px 24px;cursor:pointer} h1 {font-size:26px}
#menu {display:inline-block;position:relative;padding-bottom:16px}
#submenu {display:none;position:absolute;top:100%;left:0;width:240px;background:white;padding:12px;z-index:5}
#menu:hover #submenu {display:block} #submenu button {width:100%}
#board {display:flex;gap:80px;align-items:center;margin:40px 0}
#card {width:200px;height:100px;touch-action:none;user-select:none;background:#b7d8ff}
#done {width:240px;height:150px;border:3px dashed #458364;padding:20px}
#result {display:block;position:fixed;bottom:12px;right:12px;background:white;padding:12px;border:1px solid #ccc;z-index:10}
.far {margin-top:1800px} #cross-done {height:180px;border:3px dashed #458364;padding:20px}
</style>
<h1>Browser interaction pilot</h1><p id="goal"></p><main id="main"></main>
<output id="result" aria-live="polite">Not completed</output>
<script>
const q=new URLSearchParams(location.search),run=q.get('run'),task=q.get('task');
const main=document.querySelector('#main'),result=document.querySelector('#result');
let events=[];window.pilotState={task,completed:false,events};
function record(event,extra={}) {const entry={event,at:performance.now(),...extra};events.push(entry);fetch('/event',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({run,task,...entry})});}
function complete(e) {if(!e.isTrusted)return;window.pilotState.completed=true;result.textContent='Completed: '+task;record('completed',{trusted:e.isTrusted});}
if(task==='hover'){
 document.querySelector('#goal').textContent='Hover Reports, then choose Export CSV. Selectors: #reports and #export-csv.';
 main.innerHTML='<div id="menu"><button id="reports">Reports</button><div id="submenu"><button id="export-csv">Export CSV</button></div></div>';
 document.querySelector('#reports').addEventListener('pointerenter',e=>record('hover',{trusted:e.isTrusted}));
 document.querySelector('#export-csv').addEventListener('click',e=>{record('click',{trusted:e.isTrusted});complete(e)});
}else if(task==='scroll'){
 document.querySelector('#goal').textContent='Click Archive report, below the fold. Selector: #archive-report.';
 main.innerHTML='<p>Scroll down to the archive action.</p><section class="far"><h2>Archive</h2><button id="archive-report">Archive report</button></section>';
 document.querySelector('#archive-report').addEventListener('click',e=>{record('click',{trusted:e.isTrusted});complete(e)});
}else{
 const cross=task==='cross-drag';
 document.querySelector('#goal').textContent='Drag Task Alpha to Done. Selectors: #card and '+(cross?'#cross-done. The destination is below the fold.':'#done.');
 main.innerHTML='<section id="board"><button id="card">Task Alpha</button>'+(cross?'':'<section id="done" aria-label="Done"><h2>Done</h2></section>')+'</section>'+(cross?'<section id="cross-done" class="far" aria-label="Done"><h2>Done</h2></section>':'');
 const card=document.querySelector('#card'),done=document.querySelector(cross?'#cross-done':'#done');let held=false;
 card.addEventListener('pointerdown',e=>{if(e.button!==0)return;held=true;card.setPointerCapture(e.pointerId);record('pointerdown',{trusted:e.isTrusted,x:e.clientX,y:e.clientY})});
 card.addEventListener('pointerup',e=>{if(!held)return;held=false;const r=done.getBoundingClientRect();const inside=e.clientX>=r.left&&e.clientX<=r.right&&e.clientY>=r.top&&e.clientY<=r.bottom;record('pointerup',{trusted:e.isTrusted,x:e.clientX,y:e.clientY,inside});if(inside){done.appendChild(card);complete(e)}});
}
document.addEventListener('scroll',()=>record('scroll',{y:scrollY}),{passive:true});
record('loaded',{width:innerWidth,height:innerHeight});
</script></html>'''

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path == '/state':
            run = parse_qs(parsed.query).get('run', [''])[0]
            with LOCK:
                body = json.dumps(EVENTS.get(run, [])).encode()
            mime = 'application/json'
        else:
            body, mime = HTML.encode(), 'text/html; charset=utf-8'
        self.send_response(200)
        self.send_header('Content-Type', mime)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        if self.path != '/event':
            self.send_error(404)
            return
        entry = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        entry['received_at'] = time.time()
        with LOCK:
            EVENTS.setdefault(entry['run'], []).append(entry)
            with (ROOT / 'fixture-events.jsonl').open('a') as output:
                output.write(json.dumps(entry) + '\n')
        self.send_response(204)
        self.end_headers()

server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
(ROOT / 'fixture-address.json').write_text(json.dumps({'url': f'http://127.0.0.1:{server.server_port}', 'pid': __import__('os').getpid()}))
print(f'fixture http://127.0.0.1:{server.server_port}', flush=True)
server.serve_forever()
