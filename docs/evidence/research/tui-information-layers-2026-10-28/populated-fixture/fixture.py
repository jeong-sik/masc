#!/usr/bin/env python3
"""Read-only loopback data for manual TUI observation, never a production server."""
import http.server
import json
import os
import pathlib
import socketserver
import sys
import urllib.parse

root = pathlib.Path(sys.argv[1]).resolve()
config = root / '.masc' / 'config'
(config / 'keepers').mkdir(parents=True, exist_ok=True)
(config / 'runtime.toml').write_text('[tui]\nopening = "keeper"\nopening_keeper = "fixture"\nhints_visible = false\nhelp_hint_shown = true\nreduce_motion = true\n')
(config / 'keepers' / 'fixture.toml').write_text('[keeper]\nactivation_mode = "manual"\nsandbox_profile = "docker"\nsandbox_image = "base"\ninstructions = "Synthetic fixture only."\n')
chat = [
    ('user', '이번 PR의 변경 사항을 확인해 줘'),
    ('assistant', '현재 작업: 소스와 기존 리뷰를 확인 중입니다.'),
    ('user', '큐에서 문서 검토를 먼저 처리해 줘'),
    ('assistant', '현재 턴이 끝난 뒤 대기 요청을 처리합니다.'),
    ('user', '테스트 결과도 알려 줘'),
    ('assistant', '빌드 결과는 아직 확인되지 않았습니다.'),
    ('user', '이 대화는 비교용 가상 내용입니다.'),
    ('assistant', '확인했습니다. 선택한 요청의 상태를 확인하세요.'),
]
messages = [dict(id='fixture-row-%02d' % index, role=role, content=text,
                 ts=1793170000.0+index, **({'speaker_authority':'owner'} if role == 'user' else {}))
            for index,(role,text) in enumerate(chat)]
rows = [dict(source='chat_operation_running', what='현재 PR 검토', since=1793170000.0,
             detail={'operation_id':'fixture-running'})]
rows += [dict(source='event_queue_pending',
              what='대기 이벤트 %02d · 변경 사항과 리뷰 내용을 확인' % index,
              since=1793170000.0+index,
              detail={'source_ref':'fixture-event-%02d' % index,
                      'source_incarnation':str(index)}) for index in range(1,19)]
rows += [dict(source='schedule_waiting', what='가상 예약 작업', since=1793170000.0,
              due_at=1793260000.0,
              detail={'status':'scheduled','schedule_id':'fixture-job',
                      'schedule_instance_id':'fixture-instance'})]
identity = {'status':'ok','version':'fixture','build':{'binary_commit':'fixture'},
            'paths':{'effective_base_path':str(root),'effective_masc_root':str(root / '.masc')},
            'startup':{'state_ready':True}}
page = {'schema':'masc.keeper_chat_history.page.v2','messages':messages,
        'has_more':False,'next_cursor':None}
inventory = {'global_waiting_on':[], 'keepers':[{'state':'busy','paused':False,'waiting_on':rows}]}

class Handler(http.server.BaseHTTPRequestHandler):
    def respond(self, status, value):
        body = json.dumps(value, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header('Content-Type','application/json; charset=utf-8')
        self.send_header('Content-Length',str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def do_GET(self):
        path = urllib.parse.urlsplit(self.path).path
        if path == '/health': self.respond(200, identity)
        elif path == '/api/v1/keepers/fixture/chat/history/page': self.respond(200, page)
        elif path == '/api/v1/keepers/fixture/chat/history': self.respond(200, messages)
        elif path == '/api/v1/keepers/fixture/waiting-inventory': self.respond(200, inventory)
        elif path == '/api/v1/keepers/fixture/chat/operations': self.respond(200, {'operations':[]})
        else: self.respond(503, {'error':'fixture unavailable'})
    def do_POST(self): self.respond(405, {'error':'fixture is read-only'})
    def log_message(self, format, *args): pass
class Server(socketserver.ThreadingMixIn, http.server.HTTPServer): daemon_threads = True
server = Server(('127.0.0.1',0), Handler)
print('FIXTURE_PORT=' + str(server.server_port), flush=True)
server.serve_forever()
