"""Prepared only: attach to an explicitly started isolated candidate server, no browser actions."""
import argparse,base64,fcntl,hashlib,json,os,re,select,signal,struct,subprocess,sys,termios,time,urllib.request
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--tui',type=Path,required=True);p.add_argument('--port',type=int,required=True);p.add_argument('--commit',required=True);p.add_argument('--via-automation',action='store_true');a=p.parse_args()
root=Path('/var/folders/bv/cjrbl01x52s6j80krdfb63400000gp/T/masc-browser-handoff-yq3d680h').resolve()
evidence=root/'evidence-1789228067549703000';report=json.loads((evidence/'report.json').read_text());keeper=report['keeper']
out=root/('history-capture-'+str(time.time_ns()));out.mkdir();print('capture directory',out,flush=True)
token=json.loads((root/'login-private.json').read_text())['bearer_token']
opener=urllib.request.build_opener(urllib.request.ProxyHandler({}))
def read(path):
 req=urllib.request.Request(f'http://127.0.0.1:{a.port}'+path,headers={'Authorization':'Bearer '+token})
 with opener.open(req,timeout=15) as response:return json.load(response)
health=read('/health?full=1');assert Path(health['paths']['effective_base_path']).resolve()==root
assert health['build']['binary_commit']==a.commit
rows=read('/api/v1/keepers/'+keeper+'/tool-calls?limit=100')['entries']
expected={}
for row in rows:
 for ref in row.get('artifact_refs',[]):
  blob=ref.get('_blob',{})
  if blob.get('mime')!='application/vnd.masc.browser-scene+json':continue
  raw=(root/'.masc/tool_blobs'/blob['sha256'][:2]/blob['sha256']).read_bytes()
  assert hashlib.sha256(raw).hexdigest()==blob['sha256'] and len(raw)==blob['bytes']
  expected[row['execution_id']]=(row,json.loads(raw),blob)
assert len(expected)==4
sys.path.insert(0,'/private/tmp/masc-browser-observation-tui/test');import test_tui_keyboard_input as h
master,slave=os.openpty();os.set_blocking(master,False);fcntl.ioctl(slave,termios.TIOCSWINSZ,struct.pack('HHHH',35,130,0,0));output=bytearray();proc=None;contexts=[]
env={k:v for k,v in os.environ.items() if k in ('HOME','PATH','LANG','LC_ALL','TMPDIR','USER','LOGNAME','SHELL')};env.update(MASC_BASE_PATH=str(root),MASC_HOST='127.0.0.1',MASC_TOKEN=token,MASC_TUI_SYNC='off',TERM='xterm-256color',MASC_TUI_FORCE_COLOR='1')
def send(keys,needle):
 print('sending',keys.hex(),'awaiting',needle,flush=True)
 return h.send_and_wait(proc,master,output,keys,needle)
try:
 proc=subprocess.Popen([str(a.tui.resolve()),'--base-path',str(root),'--workspace',root.name,'--port',str(a.port)],cwd=root,env=env,stdin=slave,stdout=slave,stderr=slave,preexec_fn=h.configure_child_terminal,close_fds=True)
 h.wait_for_output(proc,master,output,b'MASC Overview',start=0,timeout=25)
 # Exact Keeper selection; copied context below verifies ownership, not merely roster text.
 send(b':go Keepers\r',b'MASC Keepers')
 # Long names are clipped in the roster, but the operator window title
 # names the selected Keeper in full. Observe that title on each cursor move.
 target_title=re.compile(rb'\x1b\]0;[^\x07]*'+re.escape(keeper.encode())+rb'(?=/| \xc2\xb7 )[^\x07]*\x07')
 for step in range(17):
  h.read_available(master,output)
  titles=list(re.finditer(rb'\x1b\]0;[^\x07]*\x07',bytes(output)))
  if titles and target_title.fullmatch(titles[-1].group()):break
  start=len(output);h.write_all(master,output,b'\x1b[B')
  h.wait_for_output(proc,master,output,h.FRAME_END,start=start,timeout=3)
 else:raise AssertionError('window title never selected the requested Keeper')
 send(b':go Browser Lane\r',b'Browser bridge not connected')
 # The earlier candidate needs this documented source-switch workaround.
 # It attempts an ordinary read without opening a browser session.
 if a.via_automation:send(b'a',b'automation')
 send(b'h',b'retained observations')
 osc=re.compile(rb'\x1b\]52;c;([A-Za-z0-9+/=]+)\x07')
 for index in range(4):
  # Wait for actual loaded scene: y emits no context until artifact loading completes.
  deadline=time.monotonic()+20;context=None
  while time.monotonic()<deadline:
   start=len(output);h.write_all(master,output,b'y')
   try:h.wait_for_output(proc,master,output,osc,start=start,timeout=1)
   except AssertionError:continue
   context=json.loads(base64.b64decode(osc.search(bytes(output[start:])).group(1)));break
  assert context is not None
  row,scene,blob=expected[context['execution_id']]
  assert context['keeper']==keeper and context['kind']=='retained_browser_observation' and context['current'] is False
  assert context['artifact']['_blob']==blob and context['documentId']==scene['documentId'] and context['url']==scene['url']
  assert context['observed_at']==row['ts'] and context['truncated']==scene['truncated']
  contexts.append(context);(out/f'observation-{index}.pty').write_bytes(output)
  if index<3:send(b']',f'Observation {index+2}/4'.encode())
 assert len({c['execution_id'] for c in contexts})==4
 send(b'[',b'Observation 3/4')
finally:
 (out/'history.pty').write_bytes(output)
 (out/'contexts.json').write_text(json.dumps(contexts,indent=2))
 if proc and proc.poll() is None:
  proc.terminate()
  deadline=time.monotonic()+5
  while proc.poll() is None and time.monotonic()<deadline:
   h.read_available(master,output);select.select([master],[],[],.05)
  if proc.poll() is None:
   proc.kill()
   deadline=time.monotonic()+5
   while proc.poll() is None and time.monotonic()<deadline:
    h.read_available(master,output);select.select([master],[],[],.05)
 (out/'history.pty').write_bytes(output)
 os.close(master);os.close(slave)
 if proc and proc.poll() is None:proc.wait(timeout=5)
print(out)
