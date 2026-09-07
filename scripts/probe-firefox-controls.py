#!/usr/bin/env python3
"""Run compiled or interpreted Firefox control code against an isolated local fixture."""
import argparse, base64, hashlib, http.server, json, os, pathlib, signal, socket, struct, subprocess, threading, time, urllib.request, zlib
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--geckodriver',type=pathlib.Path,required=True)
parser.add_argument('--firefox',type=pathlib.Path,required=True)
parser.add_argument('--out',type=pathlib.Path,required=True)
parser.add_argument('--compiled-probe',type=pathlib.Path,help='CI-built probe executable; omit to interpret source')
args=parser.parse_args()
repo=pathlib.Path(__file__).resolve().parents[1]
out=args.out.resolve();out.mkdir(parents=True,exist_ok=True)
# A failed rerun must not leave a previous screenshot looking like new evidence.
for name in ('screenshot.b64','screenshot.png'):(out/name).unlink(missing_ok=True)
(out/'probe.log').write_text('')
upload_path=out/'upload-fixture.txt';upload_path.write_text('Firefox upload 한글\n')
html='''<!doctype html><meta charset="utf-8"><title>Firefox controls fixture</title><style>body{font:20px sans-serif;padding:32px;min-height:1800px}input,select,button{font:inherit;margin:8px}output{display:block}</style><h1>Firefox fixture</h1><form><input aria-label="name"><input type="password" aria-label="password" value="private-fixture"><select aria-label="country"><option value="opaque-01">US</option><option value="opaque-02">Canada</option></select><button aria-label="submit">Apply</button></form><output>0 submissions</output><button onclick="alert('Firefox alert')" aria-label="alert">Alert</button><button onclick="document.querySelector('#dialog-result').textContent=String(confirm('Firefox confirm'))" aria-label="confirm">Confirm</button><button onclick="document.querySelector('#dialog-result').textContent=String(prompt('Firefox prompt'))" aria-label="prompt">Prompt</button><output id="dialog-result"></output><iframe id="outer-frame" src="/frame"></iframe><script>let count=0;document.querySelector('form').onsubmit=e=>{e.preventDefault();document.querySelector('output').textContent=(++count)+' submissions: '+document.querySelector('input').value+' / '+document.querySelector('select').value}</script>'''
class Handler(http.server.BaseHTTPRequestHandler):
 def do_GET(self):
  content=html
  if self.path=='/frame':content='<h1>Outer frame</h1><iframe id="nested-frame" src="http://localhost:'+str(self.server.server_port)+'/nested"></iframe>'
  elif self.path=='/nested':content='<h1>Nested frame</h1><input id="nested-input"><button id="nested-apply" onclick="document.querySelector(\'#nested-result\').textContent=document.querySelector(\'#nested-input\').value">Apply</button><output id="nested-result"></output>'
  elif self.path=='/upload':content='<form method="post" action="/uploaded" enctype="multipart/form-data"><input id="upload" name="attachment" type="file"><button id="send-upload">Upload</button></form>'
  data=content.encode();self.send_response(200);self.send_header('Content-Type','text/html; charset=utf-8');self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
 def do_POST(self):
  body=self.rfile.read(int(self.headers['Content-Length']))
  verified=upload_path.read_bytes() in body and b'filename="upload-fixture.txt"' in body
  data=('Upload verified' if verified else 'Upload invalid').encode()
  self.send_response(200 if verified else 400);self.send_header('Content-Type','text/html');self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
 def log_message(self,*args):pass
def stop_owned_group(process):
 # Each child starts a new session: only this probe's descendants receive signals.
 if process is None:return
 try:os.killpg(process.pid,signal.SIGTERM)
 except ProcessLookupError:pass
 try:process.wait(timeout=10)
 except subprocess.TimeoutExpired:pass
 finally:
  # The group leader may exit before Firefox or a curl child. Stop those too.
  try:os.killpg(process.pid,signal.SIGKILL)
  except ProcessLookupError:pass
  process.wait()

def validate_png(encoded):
 data=base64.b64decode(encoded,validate=True)
 if data[:8]!=b'\x89PNG\r\n\x1a\n':raise ValueError('screenshot is not a PNG')
 offset=8;dimensions=None;compressed=bytearray();ended=False
 while offset<len(data):
  if offset+12>len(data):raise ValueError('truncated PNG chunk')
  size=struct.unpack_from('>I',data,offset)[0]
  kind=data[offset+4:offset+8];end=offset+8+size
  if end+4>len(data):raise ValueError('truncated PNG data')
  payload=data[offset+8:end]
  if zlib.crc32(kind+payload)!=struct.unpack_from('>I',data,end)[0]:raise ValueError('invalid PNG checksum')
  if offset==8 and kind!=b'IHDR':raise ValueError('PNG is missing its header')
  if kind==b'IHDR':
   if dimensions is not None or size!=13:raise ValueError('invalid PNG header')
   width,height,depth,color,compression,filtering,interlace=struct.unpack('>IIBBBBB',payload)
   channels={0:1,2:3,3:1,4:2,6:4}.get(color)
   depths={0:(1,2,4,8,16),2:(8,16),3:(1,2,4,8),4:(8,16),6:(8,16)}
   if width==0 or height==0:raise ValueError('empty PNG viewport')
   # Firefox viewport screenshots are non-interlaced PNGs. Validate scanlines,
   # not just a PNG signature around arbitrary compressed bytes.
   if channels is None or depth not in depths[color] or compression or filtering or interlace:
    raise ValueError('unsupported Firefox PNG header')
   row_size=(width*channels*depth+7)//8+1
   dimensions={'width':width,'height':height}
  elif kind==b'IDAT':compressed.extend(payload)
  elif kind==b'IEND':
   if size!=0 or end+4!=len(data):raise ValueError('invalid PNG ending')
   ended=True
  offset=end+4
 if not ended or not compressed:raise ValueError('incomplete PNG image')
 pixels=zlib.decompressobj()
 raw=pixels.decompress(compressed)
 if not pixels.eof or pixels.unused_data or len(raw)!=height*row_size:
  raise ValueError('invalid PNG pixel stream')
 if any(raw[row]>4 for row in range(0,len(raw),row_size)):
  raise ValueError('invalid PNG scanline filter')
 return data,dimensions

def interrupted(signum,frame):
 raise SystemExit(128+signum)
signal.signal(signal.SIGTERM,interrupted)
server=None;driver=None;probe=None;log=None
execution={'mode':'compiled' if args.compiled_probe else 'interpreter','state':'starting',
 'returncode':None,'timed_out':False,'probe_sha256':None}
try:
 if args.compiled_probe:execution['probe_sha256']=hashlib.sha256(args.compiled_probe.read_bytes()).hexdigest()
 (out/'sources.json').write_text(json.dumps({p:hashlib.sha256((repo/p).read_bytes()).hexdigest() for p in [
  'lib/browser_webdriver.ml','lib/browser_lane/browser_action.ml','lib/browser_lane/browser_lane.ml',
  'lib/browser_page_script.ml','scripts/fixtures/firefox_controls_probe.ml','scripts/probe-firefox-controls.py','test/dune']},indent=2)+'\n')
 server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
 threading.Thread(target=server.serve_forever,daemon=True).start()
 with socket.socket() as sock:sock.bind(('127.0.0.1',0));port=sock.getsockname()[1]
 log=open(out/'geckodriver.log','w')
 driver=subprocess.Popen([str(args.geckodriver.resolve()),'--host','127.0.0.1','--port',str(port),
  '--binary',str(args.firefox.resolve())],stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
 execution['driver_pgid']=driver.pid
 for _ in range(100):
  try:
   if driver.poll() is not None:raise RuntimeError('owned geckodriver exited during startup')
   with urllib.request.urlopen(f'http://127.0.0.1:{port}/status',timeout=1):break
  except OSError:time.sleep(.1)
 else:raise RuntimeError('driver startup failed')
 if args.compiled_probe:
  command=[str(args.compiled_probe.resolve())]
 else:
  source='#use "topfind";;\n#require "eio_main,yojson,uri";;\nmodule Masc_http_client = struct module Pool = struct type http_method = [ `GET | `POST | `DELETE | `PUT | `PATCH | `HEAD ] end end;;\n'
  action=(repo/'lib/browser_lane/browser_action.ml').read_text()
  lane=(repo/'lib/browser_lane/browser_lane.ml').read_text()
  verbs=lane[lane.index('type verb ='):lane.index('\nlet verb_to_string')]
  answer=lane[lane.index('type answer ='):lane.index('(* The public tool surface')]
  source+='module Browser_action = struct\n'+action+'\nend;;\nmodule Browser_lane = struct module Action = Browser_action\n'+verbs+answer+'\nend;;\n'
  for module,path in [('Browser_page_script','lib/browser_page_script.ml'),('Driver','lib/browser_webdriver.ml')]:
   source+='module '+module+' = struct\n'+(repo/path).read_text()+'\nend;;\n'
  source+=(repo/'scripts/fixtures/firefox_controls_probe.ml').read_text()
  script=out/'probe.ml';script.write_text(source)
  command=['ocaml','-noinit',str(script)]
 env=dict(os.environ,MASC_PROBE_DRIVER_URL=f'http://127.0.0.1:{port}',MASC_PROBE_FIXTURE_URL=f'http://127.0.0.1:{server.server_port}',MASC_PROBE_SCREENSHOT_BASE64=str(out/'screenshot.b64'),MASC_PROBE_UPLOAD_PATH=str(upload_path))
 execution['state']='running'
 with (out/'probe.log').open('w') as probe_log:
  probe=subprocess.Popen(command,env=env,stdout=probe_log,stderr=subprocess.STDOUT,start_new_session=True)
  execution['probe_pgid']=probe.pid
  try:execution['returncode']=probe.wait(timeout=100)
  except subprocess.TimeoutExpired:
   execution['timed_out']=True
   execution['state']='timed_out'
   raise
 output=(out/'probe.log').read_text()
 print(output)
 if execution['returncode']!=0 or 'PASS old session target rejected' not in output:
  raise RuntimeError('Firefox scenario did not complete successfully')
 image,dimensions=validate_png((out/'screenshot.b64').read_text())
 (out/'screenshot.png').write_bytes(image)
 execution['screenshot']=dimensions
 print('PASS screenshot PNG structure and pixel stream')
 execution['state']='passed'
finally:
 try:
  stop_owned_group(probe)
 finally:
  try:stop_owned_group(driver)
  finally:
   if log is not None:log.close()
   if server is not None:server.shutdown();server.server_close()
   if execution['state'] not in ('passed','timed_out'):execution['state']='failed'
   if probe is not None:execution['returncode']=probe.returncode
   (out/'execution.json').write_text(json.dumps(execution,indent=2)+'\n')
