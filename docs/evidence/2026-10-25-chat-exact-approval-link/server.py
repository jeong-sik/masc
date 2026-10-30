from http.server import BaseHTTPRequestHandler,HTTPServer
from pathlib import Path
import json
root=Path(__file__).parent
class H(BaseHTTPRequestHandler):
 def do_GET(self):
  name='gate.json' if self.path.startswith('/api/v1/dashboard/gate') else 'history.json' if self.path=='/api/test/approval-history' else None
  if name:
   body=(root/name).read_bytes();self.send_response(200);self.send_header('Content-Type','application/json');self.end_headers();self.wfile.write(body)
  else:self.send_error(404)
HTTPServer(('127.0.0.1',18479),H).serve_forever()
