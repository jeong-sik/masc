from pathlib import Path
import http.server,json,hashlib,os
import argparse
parser = argparse.ArgumentParser()
parser.add_argument('--out', type=Path, required=True)
ROOT = parser.parse_args().out
ROOT.mkdir(parents=True, exist_ok=True)
payloads={'/a':bytes(range(256))*160,'/b':bytes(range(255,-1,-1))*161,'/c':'MASC SYNTHETIC LOCAL UPLOAD\ncase=1\nUnicode: 별빛\n'.encode()}
class H(http.server.BaseHTTPRequestHandler):
 def do_GET(self):
  if self.path in payloads:
   data=payloads[self.path];self.send_response(200);self.send_header('Content-Type','application/octet-stream');self.send_header('Content-Disposition','attachment; filename="same.bin"' if self.path!='/c' else 'attachment; filename="unicode.txt"');self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data);return
  text='<h1>Zen download fixture</h1><a id="a" href="/a">Binary A</a><a id="b" href="/b">Binary B same filename</a><iframe id="frame" src="/frame"></iframe>'
  if self.path=='/frame':text='<h2>Frame download</h2><a id="c" href="/c" download="unicode.txt">Unicode with final LF</a>'
  data=('<!doctype html><meta charset="utf-8"><title>Zen downloads</title><style>body{font:24px sans-serif;padding:32px}a{display:block;margin:20px}iframe{height:220px}</style>'+text).encode();self.send_response(200);self.send_header('Content-Type','text/html; charset=utf-8');self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
 def log_message(self,*args):pass
s=http.server.ThreadingHTTPServer(('127.0.0.1',0),H)
(ROOT/'fixture.json').write_text(json.dumps({'url':'http://127.0.0.1:'+str(s.server_port),'pid':os.getpid(),'expected':{k:{'bytes':len(v),'sha256':hashlib.sha256(v).hexdigest()} for k,v in payloads.items()}},indent=2)+'\n')
for k,v in payloads.items():(ROOT/(k[1:]+'-expected.bin')).write_bytes(v)
s.serve_forever()
