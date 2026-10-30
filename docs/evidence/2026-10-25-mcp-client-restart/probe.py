#!/usr/bin/env python3
"""Run an isolated installed-server restart; publish no bearer or raw responses."""
import argparse, hashlib, json, os, pathlib, signal, socket, subprocess, tempfile, time, urllib.request, urllib.error

p=argparse.ArgumentParser();p.add_argument('--binary',required=True);p.add_argument('--output',required=True);a=p.parse_args()
binary=str(pathlib.Path(a.binary).resolve());root=pathlib.Path(tempfile.mkdtemp(prefix='masc-mcp-restart-')).resolve();root.chmod(0o700)
base=root/'workspace';base.mkdir();env=os.environ.copy()
for key in ['MASC_INTERNAL_MCP_TOKEN','MASC_ADMIN_TOKEN','MASC_BASE_PATH','MASC_HTTP_PORT','MASC_URL','MASC_HTTP_BASE_URL','MASC_OAUTH_ENABLED']:
 env.pop(key,None)
with socket.socket() as sock:sock.bind(('127.0.0.1',0));port=sock.getsockname()[1]
env['MASC_BASE_PATH']=str(base)
server=None;logs=[];result={'binary_sha256':hashlib.sha256(pathlib.Path(binary).read_bytes()).hexdigest(),'base_isolated':True,'server_runs':[]}
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
  status,headers,init=rpc('initialize',{'protocolVersion':'2025-03-26','capabilities':{},'clientInfo':{'name':'restart-proof','version':'1'}},token)
  assert status==200 and 'result' in init,{'stage':'initialize','http':status,'error_present':'error' in init}
  session=next((v for k,v in headers.items() if k.lower()=='mcp-session-id'),None)
  assert session,'initialize missing session'
  assert session not in sessions,'restart reused the old MCP session'
  sessions.append(session)
  notified,_,_=rpc('notifications/initialized',{},token,session,id=None);assert notified in(200,202,204),notified
  status,_,tools=rpc('tools/list',{},token,session,id=2);assert status==200 and 'result'in tools
  names=[x['name'] for x in tools['result']['tools']];assert 'masc_tool_help'in names,{'missing':'masc_tool_help','tools':names}
  status,_,call=rpc('tools/call',{'name':'masc_tool_help','arguments':{'tool_name':'masc_status'}},token,session,id=3)
  assert status==200 and 'result'in call and not call['result'].get('isError',False)
  assert raw.read_text().strip()==token and json.dumps(config,sort_keys=True)==frozen_config
  internal.append((base/'.masc/auth/internal_keeper.token.hash').read_bytes())
  result['server_runs'].append({'ordinal':index+1,'pid':server.pid,'effective_paths_matched':True,'unauthenticated_http_status':unauth_status,'initialize_http_status':200,'new_session':bool(session),'tools_list_count':len(names),'masc_tool_help_succeeded':True,'client_raw_token_unchanged':True})
  stop()
 result['distinct_session_ids']=len(set(sessions))==2
 result['internal_token_rotated']=internal[0]!=internal[1];assert result['internal_token_rotated']
 result['result']='PASS';result['server_processes_reaped']=True
 pathlib.Path(a.output).write_text(json.dumps(result,indent=2)+'\n')
 print(json.dumps(result))
finally:
 stop()
 for log in logs:log.close()
 import shutil;shutil.rmtree(root)
