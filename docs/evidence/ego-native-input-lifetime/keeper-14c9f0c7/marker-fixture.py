from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
from pathlib import Path
import json,threading,time
ROOT=Path('/Users/dancer/me/workspace/yousleepwhen/masc-ego-native-lifetime-proof-20261025')
state=ROOT/'marker-state.json';lock=threading.Lock()
if not state.exists():state.write_text('[]\n')
html='''<!doctype html><meta charset="utf-8"><title>Native wait marker</title><style>body{font:20px system-ui;margin:50px}button{font:inherit;padding:12px}#pending{padding:20px;background:#eef}</style><h1>SDK 대기 수명 검증</h1><p>시작 버튼을 누르면 대기 표식은 130초 뒤 사라지고 완료 안내가 나타납니다. 시작은 한 번만 하세요.</p><button id="start">대기 검증 시작</button><div role="status" id="pending">대기 표식</div><h2 id="done" hidden>SDK 대기 검증 완료</h2><script>document.querySelector('#start').onclick=async e=>{e.target.disabled=true;const response=await fetch('/start',{method:'POST'});if(response.ok){document.querySelector('#pending').hidden=true;document.querySelector('#done').hidden=false;document.title='SDK 대기 검증 완료';}else{document.querySelector('#pending').textContent='시작 결과 불확실. 다시 누르지 마세요.'}};</script>'''
class Handler(BaseHTTPRequestHandler):
 def json(self,status,value):
  body=json.dumps(value,ensure_ascii=False).encode();self.send_response(status);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
 def do_GET(self):
  if self.path=='/state':return self.json(200,json.loads(state.read_text()))
  if self.path!='/':return self.json(404,{'error':'not found'})
  body=html.encode();self.send_response(200);self.send_header('Content-Type','text/html; charset=utf-8');self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
 def do_POST(self):
  if self.path!='/start':return self.json(404,{'error':'not found'})
  with lock:
   rows=json.loads(state.read_text())
   if rows:return self.json(409,{'error':'already started'})
   rows=[{'state':'processing','started_at':time.time()}];state.write_text(json.dumps(rows)+'\n')
  began=time.monotonic();time.sleep(130)
  with lock:
   rows[0].update(state='completed',completed_at=time.time(),elapsed_seconds=time.monotonic()-began);state.write_text(json.dumps(rows)+'\n')
  self.json(200,{'state':'completed'})
ThreadingHTTPServer(('127.0.0.1',9451),Handler).serve_forever()
