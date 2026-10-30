from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit, parse_qs
import json
root=Path(__file__).parent
class Handler(BaseHTTPRequestHandler):
 def do_GET(self):
  path=urlsplit(self.path)
  dataset=root/'produced-pages.json'
  if path.path=='/api/v1/dashboard/dev-token':
   self.send_error(404);return
  if path.path=='/api/v1/dashboard/tools':
   self.reply(200,{});return
  if not dataset.exists():
   self.reply(503,{'error':'Actual successful backend page rows have not been supplied'});return
  entries=json.loads(dataset.read_text())
  if path.path=='/api/test/cases':
   self.reply(200,{'cases':list(entries)});return
  key=parse_qs(urlsplit(self.headers.get('Referer','')).query).get('case',[None])[0]
  if key not in entries:
   self.reply(400,{'error':'An exact produced scenario is required','case':key});return
  entry=entries[key];row=entry['row']
  if path.path=='/api/v1/dashboard/scheduled-automation':
   query=parse_qs(path.query)
   if 'schedule_id' in query:
    if query['schedule_id']!=[row['schedule_id']]:
     self.reply(400,{'error':'lookup identity differs from produced row'});return
    body={'schema':'masc.dashboard.scheduled_automation.lookup.v1','source':'schedule_store','generated_at':'2026-10-25T00:00:00Z','status':'found','schedule_id':row['schedule_id'],'request':row,'wakes':[],'wake_count':0,'wake_retention_per_schedule':None}
   else:
    active=row['status'] in ['scheduled','due','running']
    # Only this envelope is controlled. The actual producer row remains byte-
    # equivalent JSON; counts describe this one-row QA projection, not a fleet.
    body={'schema':'masc.dashboard.scheduled_automation.v1','source':'schedule_store','generated_at':'2026-10-25T00:00:00Z','status':'ok','schedule_store_known':True,'schedule_store_read_error':None,'request_count':1,'request_limit':1,'truncated':False,'counts':{row['status']:1},'fsm':{'state':'active' if active else 'terminal','active_count':int(active),'terminal_count':int(not active)},'requests':[row],'signals':[],'warnings':[]}
   self.reply(200,body);return
  self.send_error(404)
 def reply(self,status,body):
  data=json.dumps(body,ensure_ascii=False).encode()
  self.send_response(status);self.send_header('Content-Type','application/json');self.send_header('Cache-Control','no-store');self.end_headers();self.wfile.write(data)
server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
print(f'fixture_port={server.server_port}',flush=True)
server.serve_forever()
