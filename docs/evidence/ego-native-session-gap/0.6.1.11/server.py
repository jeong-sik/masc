import http.server,json,sys
from pathlib import Path
root=Path(__file__).parent
class Handler(http.server.SimpleHTTPRequestHandler):
 def __init__(self,*a,**kw): super().__init__(*a,directory=str(root),**kw)
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
(root/'server.json').write_text(json.dumps({'port':server.server_port}))
server.serve_forever()
