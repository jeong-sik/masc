from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
from pathlib import Path
import json,threading,time
ROOT=Path('/Users/dancer/me/workspace/yousleepwhen/masc-ego-client-policy-proof-20261025')
state=ROOT/'fixture-clicks.json';lock=threading.Lock()
html='''<!doctype html><meta charset="utf-8"><title>Ego native transport check</title><style>body{font:20px system-ui;margin:50px}button{font:inherit;padding:12px}</style><h1>Ego native transport check</h1><button id="confirm">연결 검증 확인</button><h2 id="done" hidden>네이티브 연결 검증 완료</h2><script>document.querySelector('#confirm').onclick=async e=>{e.target.disabled=true;const r=await fetch('/confirm',{method:'POST'});if(r.ok){document.querySelector('#done').hidden=false;document.title='네이티브 연결 검증 완료';}};</script>'''
class Handler(BaseHTTPRequestHandler):
 def do_GET(self):
  if self.path!='/':self.send_error(404);return
  body=html.encode();self.send_response(200);self.send_header('Content-Type','text/html; charset=utf-8');self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
 def do_POST(self):
  if self.path!='/confirm':self.send_error(404);return
  with lock:
   rows=json.loads(state.read_text()) if state.exists() else []
   if rows:self.send_error(409,'already confirmed');return
   state.write_text(json.dumps([{'confirmed_at':time.time()}])+'\n')
  self.send_response(204);self.end_headers()
ThreadingHTTPServer(('127.0.0.1',9457),Handler).serve_forever()
