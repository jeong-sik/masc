import json,pathlib,time,http.server,hashlib
ROOT=pathlib.Path(__file__).resolve().parent
BASE=str(ROOT/'workspace')
SCHEMA={'type':'object','required':['context','request_id','action'],'additionalProperties':False,'properties':{'context':{'type':'object','required':['instance_id','incarnation'],'additionalProperties':False,'properties':{'instance_id':{'type':'string'},'incarnation':{'type':'string'}}},'request_id':{'type':'string','minLength':36},'action':{'type':'object','required':['operation'],'additionalProperties':False,'properties':{'operation':{'type':'string','enum':['inspect']}}}}}
def worker(id,title,category,installation=None,path=None):
 return {'instance_id':id,'incarnation':id,'run_id':'proof-run','addon_id':id+'-package','title':title,'revision':'1','phase':{'kind':'attached'},'runtime_presence':'live','observation_seq':1,'rows_count':0,'configuration':None if installation is None else {'id':installation,'source_path':path,'revision':'r1'},'binding':{'sources':[]},'package':{'outputs':{},'skills_directory':None,'ui_category':category},'action_schema':SCHEMA}
def declaration(id,path,category,instance=None):
 return {'id':id,'source_path':path,'source_revision':'s1','desired_revision':'r1','enabled':instance is not None,'applied_revision':'r1' if instance else None,'instance_id':instance,'ui_category':category,'application':{'kind':'applied','instance_id':instance} if instance else {'kind':'inactive'}}
browser_path=BASE+'/.masc/config/lane-addons/browser.toml'
SNAP={'instances':[worker('worker-execution','Execution worker raw-first','execution_environment'),worker('worker-browser','Browser original target','analysis','browser-installation',browser_path),worker('worker-mismatch','Mismatch must stay unverified','analysis','mismatch-installation',BASE+'/mismatch-original.toml')],'rows':[],'coverage':[],'configuration':{'directory':BASE+'/.masc/config/lane-addons','complete':True,'declarations':[declaration('inactive-memory',BASE+'/memory.toml','memory_judgment'),declaration('browser-installation',browser_path,'browser','worker-browser'),declaration('mismatch-installation',BASE+'/different-path.toml','voice_media','worker-mismatch')],'issues':[]}}
(ROOT/'fixture-snapshot.json').write_text(json.dumps(SNAP,indent=2))
class H(http.server.BaseHTTPRequestHandler):
 def log_message(self,*args):pass
 def handle_request(self):
  raw=self.rfile.read(int(self.headers.get('Content-Length','0')));body=json.loads(raw) if raw else None
  with (ROOT/'http-events.jsonl').open('a') as f:f.write(json.dumps({'ts':time.time(),'method':self.command,'path':self.path,'body':body})+'\n')
  if self.path.startswith('/health'):
   result={'version':'0.63.0','build':{'binary_commit':'107c58401723313611f7c599bbe15225de5910da','executable_in_worktree':False},'paths':{'effective_base_path':BASE,'effective_masc_root':BASE+'/.masc'},'startup':{'state_ready':True},'status':'ok'}
  elif self.path.split('?')[0]=='/api/v1/lane-addons':result=SNAP
  elif self.path=='/api/v1/lane-addons/actions' and body:
   args={'action':body['action'],'context':{'incarnation':body['instance_id'],'instance_id':body['instance_id']},'request_id':body['request_id']}
   result={'instance_id':body['instance_id'],'incarnation':body['expected_incarnation'],'request_id':body['request_id'],'requester':'isolated-proof-fixture','executor':None,'input_sha256':hashlib.sha256(json.dumps(args,separators=(',',':'),sort_keys=True).encode()).hexdigest(),'action':body['action'],'state':'confirmed','result':{'fixture':True},'detail':None}
  elif self.path.startswith('/api/v1/keepers'):result={'keepers':[],'items':[],'asks':[],'approvals':[],'total':0}
  elif self.path.startswith('/api/v1/operator'):result={'status':{},'keepers':[],'tasks':[],'goals':[],'messages':[],'agents':[]}
  else:result={}
  data=json.dumps(result,separators=(',',':')).encode();self.send_response(200);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
 do_GET=handle_request
 do_POST=handle_request
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),H)
(ROOT/'fixture-port.txt').write_text(str(server.server_port));print(server.server_port,flush=True);server.serve_forever()
