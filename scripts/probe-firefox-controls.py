#!/usr/bin/env python3
"""Interpret production Firefox control code against an isolated local fixture (no MASC build)."""
import argparse, base64, hashlib, http.server, json, os, pathlib, socket, subprocess, threading, time, urllib.request
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--geckodriver',type=pathlib.Path,required=True)
parser.add_argument('--firefox',type=pathlib.Path,required=True)
parser.add_argument('--out',type=pathlib.Path,required=True)
args=parser.parse_args()
repo=pathlib.Path(__file__).resolve().parents[1]
out=args.out.resolve();out.mkdir(parents=True,exist_ok=True)
html='''<!doctype html><meta charset="utf-8"><title>Firefox controls fixture</title><style>body{font:20px sans-serif;padding:32px;min-height:1800px}input,select,button{font:inherit;margin:8px}output{display:block}</style><h1>Firefox fixture</h1><form><input aria-label="name"><input type="password" aria-label="password" value="private-fixture"><select aria-label="country"><option value="opaque-01">US</option><option value="opaque-02">Canada</option></select><button aria-label="submit">Apply</button></form><output>0 submissions</output><script>let count=0;document.querySelector('form').onsubmit=e=>{e.preventDefault();document.querySelector('output').textContent=(++count)+' submissions: '+document.querySelector('input').value+' / '+document.querySelector('select').value}</script>'''
class Handler(http.server.BaseHTTPRequestHandler):
 def do_GET(self):
  data=html.encode();self.send_response(200);self.send_header('Content-Type','text/html; charset=utf-8');self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
 def log_message(self,*args):pass
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler);threading.Thread(target=server.serve_forever,daemon=True).start()
with socket.socket() as sock:sock.bind(('127.0.0.1',0));port=sock.getsockname()[1]
log=open(out/'geckodriver.log','w');driver=subprocess.Popen([str(args.geckodriver.resolve()),'--host','127.0.0.1','--port',str(port),'--binary',str(args.firefox.resolve())],stdout=log,stderr=subprocess.STDOUT)
try:
 for _ in range(100):
  try:
   with urllib.request.urlopen(f'http://127.0.0.1:{port}/status',timeout=1):break
  except OSError:time.sleep(.1)
 else:raise RuntimeError('driver startup failed')
 source='#use "topfind";;\n#require "eio_main,yojson,uri";;\nmodule Masc_http_client = struct module Pool = struct type http_method = [ `GET | `POST | `DELETE ] end end;;\n'
 action=(repo/'lib/browser_lane/browser_action.ml').read_text()
 lane=(repo/'lib/browser_lane/browser_lane.ml').read_text()
 verbs=lane[lane.index('type verb ='):lane.index('\nlet verb_to_string')]
 answer=lane[lane.index('type answer ='):lane.index('(* The public tool surface')]
 source+='module Browser_action = struct\n'+action+'\nend;;\nmodule Browser_lane = struct module Action = Browser_action\n'+verbs+answer+'\nend;;\n'
 for module,path in [('Browser_page_script','lib/browser_page_script.ml'),('Driver','lib/browser_webdriver.ml')]:
  source+='module '+module+' = struct\n'+(repo/path).read_text()+'\nend;;\n'
 source+=(repo/'scripts/fixtures/firefox_controls_probe.ml').read_text()
 script=out/'probe.ml';script.write_text(source)
 env=dict(os.environ,MASC_PROBE_DRIVER_URL=f'http://127.0.0.1:{port}',MASC_PROBE_FIXTURE_URL=f'http://127.0.0.1:{server.server_port}',MASC_PROBE_SCREENSHOT_BASE64=str(out/'screenshot.b64'))
 result=subprocess.run(['ocaml','-noinit',str(script)],env=env,text=True,capture_output=True,timeout=100)
 (out/'probe.log').write_text(result.stdout+result.stderr)
 print(result.stdout);print(result.stderr)
 (out/'sources.json').write_text(json.dumps({p:hashlib.sha256((repo/p).read_bytes()).hexdigest() for p in ['lib/browser_webdriver.ml','lib/browser_lane/browser_action.ml','lib/browser_lane/browser_lane.ml','lib/browser_page_script.ml']},indent=2)+'\n')
 if (out/'screenshot.b64').exists():(out/'screenshot.png').write_bytes(base64.b64decode((out/'screenshot.b64').read_text()))
 assert result.returncode==0 and 'PASS old session target rejected' in result.stdout
finally:
 driver.terminate()
 try:driver.wait(timeout=10)
 except subprocess.TimeoutExpired:driver.kill();driver.wait()
 log.close();server.shutdown();server.server_close()
