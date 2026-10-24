from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import json
ROOT=Path('/Users/dancer/me/workspace/yousleepwhen/masc-ego-integration-7ee0dd6e')
STATE=ROOT/'fixture-submissions.json'
HTML='''<!doctype html><html lang="ko"><meta charset="utf-8"><title>Ego 배송 신청 검증</title>
<style>body{font:18px system-ui;max-width:640px;margin:40px auto}label{display:block;margin:22px 0}input,select,button{font:inherit;padding:9px}select[multiple]{height:125px}#status{padding:18px;background:#eef}</style>
<h1>배송 신청</h1><p>필수 항목을 입력하고 신청하세요. 완료 후 신청 번호가 표시됩니다.</p>
<form><label>신청인 이름 <input name="name" required></label>
<label>수령 방법 <select name="delivery" required><option value="">선택하세요</option><option value="pickup">직접 수령</option><option value="shipping">택배 배송</option></select></label>
<div id="address"></div><label>알림 수단 (복수 선택 가능)<br><select name="notifications" multiple required><option value="email">이메일</option><option value="sms">문자 메시지</option><option value="phone">전화</option></select></label>
<button>배송 신청하기</button></form><div id="status" role="status"></div>
<script>
document.querySelector('[name=delivery]').onchange=e=>{document.querySelector('#address').innerHTML=e.target.value==='shipping'?'<label>배송 주소 <input name="address" required></label>':''};
document.querySelector('form').onsubmit=async e=>{e.preventDefault();const f=new FormData(e.target);const res=await fetch('/submit',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({name:f.get('name'),delivery:f.get('delivery'),address:f.get('address'),notifications:f.getAll('notifications')})});if(res.ok)location.href='/confirmation'};
</script></html>'''
class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path=='/state': body=STATE.read_bytes() if STATE.exists() else b'[]'; ct='application/json'
        elif self.path=='/confirmation':
            n=len(json.loads(STATE.read_text())) if STATE.exists() else 0
            body=f'<!doctype html><html lang="ko"><meta charset="utf-8"><title>배송 신청 완료</title><h1>배송 신청 완료</h1><p role="status">신청 번호 EGO-{n:03d}</p></html>'.encode();ct='text/html; charset=utf-8'
        else: body=HTML.encode();ct='text/html; charset=utf-8'
        self.send_response(200);self.send_header('Content-Type',ct);self.end_headers();self.wfile.write(body)
    def do_POST(self):
        d=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        rows=json.loads(STATE.read_text()) if STATE.exists() else [];rows.append(d);STATE.write_text(json.dumps(rows,ensure_ascii=False,indent=2))
        self.send_response(200);self.end_headers();self.wfile.write(b'{"ok":true}')
ThreadingHTTPServer(('127.0.0.1',9448),Handler).serve_forever()
