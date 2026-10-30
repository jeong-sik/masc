from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import argparse, json, threading, time
parser=argparse.ArgumentParser()
parser.add_argument('--root',type=Path,required=True)
parser.add_argument('--port',type=int,required=True)
parser.add_argument('--delay-seconds',type=float,required=True)
a=parser.parse_args()
a.root.mkdir(parents=True,exist_ok=True)
state=a.root/'fixture-submissions.json'
if not state.exists():
    with state.open('x') as f:f.write('[]\n')
lock=threading.Lock()
def save(rows):
    temporary=state.with_suffix('.tmp')
    temporary.write_text(json.dumps(rows,ensure_ascii=False,indent=2)+'\n')
    temporary.replace(state)
html='''<!doctype html><html lang="ko"><meta charset="utf-8"><title>Ego native 장시간 처리 검증</title>
<style>body{font:18px system-ui;max-width:680px;margin:40px auto}label{display:block;margin:22px 0}input,select,button{font:inherit;padding:9px}select[multiple]{height:125px}#status{padding:18px;background:#eef}</style>
<h1>배송 신청</h1><p>이 검증 앱은 접수 뒤 서버에서 130초간 처리합니다. 완료 결과가 화면에 나타날 때까지 기다려 주세요.</p>
<form><label>신청인 이름 <input name="name" required></label>
<label>수령 방법 <select name="delivery" required><option value="">선택하세요</option><option value="pickup">직접 수령</option><option value="shipping">택배 배송</option></select></label>
<div id="address"></div><label>알림 수단 (복수 선택 가능)<br><select name="notifications" multiple required><option value="email">이메일</option><option value="sms">문자 메시지</option><option value="phone">전화</option></select></label>
<button>배송 신청하기</button></form><div id="status" role="status">접수 대기</div>
<script>
document.querySelector('[name=delivery]').onchange=e=>{document.querySelector('#address').innerHTML=e.target.value==='shipping'?'<label>배송 주소 <input name="address" required></label>':''};
document.querySelector('form').onsubmit=async e=>{e.preventDefault();const f=new FormData(e.target);document.querySelector('#status').textContent='접수되었습니다. 서버 처리 중입니다. 완료 결과가 나타날 때까지 기다려 주세요.';e.target.hidden=true;try{const res=await fetch('/submit',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({name:f.get('name'),delivery:f.get('delivery'),address:f.get('address'),notifications:f.getAll('notifications')})});if(!res.ok)throw Error('접수 응답 '+res.status);const result=await res.json();document.querySelector('#status').textContent='처리가 완료되었습니다.';const section=document.createElement('section');section.id='confirmation';section.innerHTML='<h2>배송 신청 완료</h2><p>신청 번호 '+result.id+'</p>';document.body.append(section);document.title='배송 신청 완료';}catch(error){document.querySelector('#status').textContent='결과를 확인하지 못했습니다. 다시 신청하지 말고 현재 상태를 확인해 주세요: '+error.message}};
</script></html>'''
class Handler(BaseHTTPRequestHandler):
    def send_json(self,status,value):
        body=json.dumps(value,ensure_ascii=False).encode()
        self.send_response(status);self.send_header('Content-Type','application/json; charset=utf-8');self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
    def do_GET(self):
        if self.path=='/state':
            with lock:rows=json.loads(state.read_text())
            return self.send_json(200,rows)
        if self.path!='/':return self.send_json(404,{'error':'not found'})
        body=html.encode();self.send_response(200);self.send_header('Content-Type','text/html; charset=utf-8');self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
    def do_POST(self):
        if self.path!='/submit':return self.send_json(404,{'error':'not found'})
        try:
            data=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
            assert set(data)=={'name','delivery','address','notifications'}
            assert isinstance(data['name'],str) and data['name']
            assert data['delivery'] in ['pickup','shipping']
            assert isinstance(data['notifications'],list) and data['notifications']
            assert all(x in ['email','sms','phone'] for x in data['notifications'])
            assert data['delivery']!='shipping' or isinstance(data['address'],str) and data['address']
        except (ValueError,KeyError,AssertionError):return self.send_json(422,{'error':'invalid form'})
        with lock:
            rows=json.loads(state.read_text());identifier=f'EGO-{len(rows)+1:03d}'
            rows.append({'id':identifier,'values':data,'state':'processing','accepted_at':time.time(),'delay_seconds':a.delay_seconds});save(rows)
        began=time.monotonic();time.sleep(a.delay_seconds)
        with lock:
            rows=json.loads(state.read_text())
            row=next(row for row in rows if row['id']==identifier)
            row.update(state='completed',completed_at=time.time(),processing_elapsed_s=time.monotonic()-began);save(rows)
        try:self.send_json(200,{'id':identifier,'state':'completed'})
        except (BrokenPipeError,ConnectionResetError):print('Browser disconnected before result delivery:',identifier,flush=True)
print(json.dumps({'root':str(a.root),'port':a.port,'delay_seconds':a.delay_seconds,'submissions':len(json.loads(state.read_text()))}),flush=True)
ThreadingHTTPServer(('127.0.0.1',a.port),Handler).serve_forever()
