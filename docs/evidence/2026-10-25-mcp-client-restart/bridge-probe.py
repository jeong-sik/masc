#!/usr/bin/env python3
"""Run an isolated installed-server restart; publish no bearer or raw responses."""
import argparse, hashlib, json, os, pathlib, signal, socket, subprocess, tempfile, time, urllib.request, urllib.error, threading, queue

p=argparse.ArgumentParser();p.add_argument('--client-prefix',required=True);p.add_argument('--binary',required=True);p.add_argument('--output',required=True);a=p.parse_args()
binary=str(pathlib.Path(a.binary).resolve());root=pathlib.Path(tempfile.mkdtemp(prefix='masc-mcp-restart-')).resolve();root.chmod(0o700)
base=root/'workspace';base.mkdir();env=os.environ.copy()
for key in ['MASC_INTERNAL_MCP_TOKEN','MASC_ADMIN_TOKEN','MASC_BASE_PATH','MASC_HTTP_PORT','MASC_URL','MASC_HTTP_BASE_URL','MASC_OAUTH_ENABLED']:
 env.pop(key,None)
with socket.socket() as sock:sock.bind(('127.0.0.1',0));port=sock.getsockname()[1]
env['MASC_BASE_PATH']=str(base)
server=None;logs=[];bridge=None;result={'binary_sha256':hashlib.sha256(pathlib.Path(binary).read_bytes()).hexdigest(),'base_isolated':True,'server_runs':[]}
def run(args):
 r=subprocess.run([binary,*args],env=env,cwd=root,stdout=subprocess.PIPE,stderr=subprocess.PIPE,check=True)
 return r.stdout.decode()
def http(path,body=None,token=None,session=None):
 headers={'Accept':'application/json, text/event-stream','Content-Type':'application/json'}
 if token:headers['Authorization']='Bearer '+token
 if session:headers['Mcp-Session-Id']=session
 req=urllib.request.Request(f'http://127.0.0.1:{port}'+path,data=None if body is None else json.dumps(body).encode(),headers=headers)
 try:
  with urllib.request.urlopen(req,timeout=5) as response:return response.status,dict(response.headers),response.read().decode()
 except urllib.error.HTTPError as error:return error.code,dict(error.headers),error.read().decode()
def rpc(method,params,token,session=None,id=1):
 body={'jsonrpc':'2.0','method':method,'params':params}
 if id is not None:body['id']=id
 status,headers,text=http('/mcp',body,token,session)
 if any(line.startswith('data:') for line in text.splitlines()):
  entries=[json.loads(line[5:].strip()) for line in text.splitlines() if line.startswith('data:')]
  response=next((v for v in entries if v.get('id')==id),{})
 else:response=json.loads(text) if text else {}
 return status,headers,response
def stop():
 global server
 if server is not None:
  server.terminate()
  try:server.wait(timeout=30)
  except subprocess.TimeoutExpired:server.kill();server.wait();raise RuntimeError('isolated server did not stop gracefully')
  assert server.returncode is not None
  server=None
class Bridge:
 def __init__(self,entry):
  self.messages=queue.Queue();self.ids=0
  client_env=env.copy();client_env.update(entry['env']);client_env['MCP_REMOTE_CONFIG_DIR']=str(root/'remote-config')
  log=open(root/f'bridge-{time.monotonic_ns()}.log','wb');logs.append(log)
  self.child=subprocess.Popen([entry['command'],*entry['args']],env=client_env,cwd=a.client_prefix,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=log,text=True,start_new_session=True)
  def read():
   for line in self.child.stdout:
    try:self.messages.put(json.loads(line))
    except ValueError:continue
  threading.Thread(target=read,daemon=True).start()
 def request(self,method,params):
  self.ids+=1;ident=self.ids
  self.child.stdin.write(json.dumps({'jsonrpc':'2.0','id':ident,'method':method,'params':params})+'\n');self.child.stdin.flush()
  deadline=time.monotonic()+20
  while time.monotonic()<deadline:
   try:response=self.messages.get(timeout=.2)
   except queue.Empty:
    if self.child.poll() is not None:return {'process_exited':True}
    continue
   if response.get('id')==ident:return response
  return {'observation_timed_out':True,'process_live':self.child.poll() is None}
 def initialize(self):
  response=self.request('initialize',{'protocolVersion':'2025-03-26','capabilities':{},'clientInfo':{'name':'configured-bridge-proof','version':'1'}})
  assert 'result'in response,{'stage':'bridge initialize','response_keys':list(response)}
  self.child.stdin.write(json.dumps({'jsonrpc':'2.0','method':'notifications/initialized','params':{}})+'\n');self.child.stdin.flush()
 def close(self):
  if self.child.poll() is None:
   os.killpg(self.child.pid,signal.SIGTERM)
  try:self.child.wait(timeout=10)
  except subprocess.TimeoutExpired:os.killpg(self.child.pid,signal.SIGKILL);self.child.wait()
try:
 result['build_commit']=run(['build-commit']).strip()
 text=run(['mcp-config','--base-path',str(base),'--port',str(port),'--agent','restart-proof-client','--client','claude-desktop','--client-env','MASC_RESTART_PROOF_TOKEN'])
 config=json.loads(text[text.index('{'):]);entry=config['mcpServers']['masc'];token=entry['env']['MASC_RESTART_PROOF_TOKEN']
 frozen_config=json.dumps(config,sort_keys=True)
 assert entry['args'][2]==f'http://127.0.0.1:{port}/mcp'
 assert entry['args'][-1]=='Authorization: Bearer ${MASC_RESTART_PROOF_TOKEN}'
 raw=base/'.masc/auth/restart-proof-client.token';assert raw.read_text().strip()==token
 result['generated_client_config']={'kind':'claude-desktop/mcp-remote','agent':'restart-proof-client','role':'worker','same_static_config':True,'token_env_name':'MASC_RESTART_PROOF_TOKEN'}
 internal=[];sessions=[]
 for index in range(2):
  log=open(root/f'server-{index}.log','wb');logs.append(log)
  server=subprocess.Popen([binary,'start','--base-path',str(base),'--host','127.0.0.1','--port',str(port)],env=env,cwd=root,stdout=log,stderr=log)
  until=time.monotonic()+60
  while True:
   assert server.poll() is None,'isolated server exited before readiness'
   try:
    code,_,_=http('/health/ready')
    if code==200:
     code,_,health_body=http('/health?full=1');health=json.loads(health_body)
     if code==200:break
   except (OSError,ValueError):pass
   if time.monotonic()>until:raise RuntimeError('isolated readiness not observed within probe deadline')
   time.sleep(.2)
  paths=health['paths'];assert paths['effective_base_path']==str(base);assert paths['effective_masc_root']==str(base/'.masc')
  unauth_status,_,_=http('/mcp',{'jsonrpc':'2.0','id':1,'method':'initialize','params':{'protocolVersion':'2025-03-26','capabilities':{},'clientInfo':{'name':'restart-proof','version':'1'}}})
  assert unauth_status in (401,403),unauth_status
  if bridge is None:
   bridge=Bridge(entry);bridge.initialize()
   result['initial_bridge_pid']=bridge.child.pid
  else:
   response=bridge.request('tools/list',{})
   result['continuous_bridge_after_server_restart']={'same_process_live':bridge.child.poll() is None,'response_has_result':'result'in response,'response_has_error':'error'in response,'error_code':response.get('error',{}).get('code'),'timed_out':response.get('observation_timed_out',False)}
   if 'result'not in response:
    bridge.close();bridge=Bridge(entry);bridge.initialize()
    result['explicit_bridge_relaunch_required']=True
   else:result['explicit_bridge_relaunch_required']=False
  tools=bridge.request('tools/list',{});assert 'result'in tools,{'stage':'tools/list','response_keys':list(tools)}
  names=[x['name']for x in tools['result']['tools']];assert 'masc_tool_help'in names
  call=bridge.request('tools/call',{'name':'masc_tool_help','arguments':{'tool_name':'masc_status'}})
  assert 'result'in call and not call['result'].get('isError',False),{'stage':'tools/call','response_keys':list(call)}
  assert raw.read_text().strip()==token and json.dumps(config,sort_keys=True)==frozen_config
  internal.append((base/'.masc/auth/internal_keeper.token.hash').read_bytes())
  result['server_runs'].append({'ordinal':index+1,'pid':server.pid,'effective_paths_matched':True,'unauthenticated_http_status':unauth_status,'bridge_pid':bridge.child.pid,'tools_list_count':len(names),'masc_tool_help_succeeded':True,'client_credential_value_unchanged':True})
  stop()
 bridge.close();bridge=None
 result['client_package_version']=json.loads((pathlib.Path(a.client_prefix)/'node_modules/mcp-remote/package.json').read_text())['version']
 result['internal_token_rotated']=internal[0]!=internal[1];assert result['internal_token_rotated']
 result['result']='PASS';result['server_processes_reaped']=True
 pathlib.Path(a.output).write_text(json.dumps(result,indent=2)+'\n')
 print(json.dumps(result))
finally:
 if bridge is not None:bridge.close()
 stop()
 for log in logs:log.close()
 import shutil;shutil.rmtree(root)
