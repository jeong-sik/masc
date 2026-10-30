import pathlib,json,threading,http.server,functools,hashlib,tarfile
from urllib.parse import urlparse
from playwright.sync_api import sync_playwright
P=pathlib.Path(__file__).parent
receipt=json.loads((P/'artifact/dashboard-build-receipt.json').read_text())
assert receipt['source_commit']=='5cdf1aee64aa0942a9c390387ad284e5b6bc37b2'
archive=P/'artifact'/receipt['archive']
assert hashlib.sha256(archive.read_bytes()).hexdigest()==receipt['archive_sha256']
(P/'bundle').mkdir(exist_ok=True)
with tarfile.open(archive) as f:f.extractall(P/'bundle',filter='data')
assert hashlib.sha256((P/'bundle/dashboard/index.html').read_bytes()).hexdigest()==receipt['index_sha256']
STAMP='2026-09-09T01:00:00Z'
task={'id':'cleanup-target','title':'Cleanup browser target','status':'todo','priority':3,'description':'Isolated deletion receipt scenario','created_at':STAMP,'updated_at':STAMP}
state={'present':True,'delete_calls':0}
requests=[]; errors=[]
class Handler(http.server.SimpleHTTPRequestHandler):
 def log_message(self,*_):pass
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),functools.partial(Handler,directory=str(P/'bundle')))
threading.Thread(target=server.serve_forever,daemon=True).start()
def fixture(path,method):
 if path=='/api/v1/dashboard/tasks/delete' and method=='POST':
  state['present']=False;state['delete_calls']+=1
  failed=state['delete_calls']==1
  return 200,{'ok':not failed,'task_id':task['id'],'task_deleted':True,'status':'cleanup_failed' if failed else 'already_absent','errors':['primary link store unreadable'] if failed else []}
 if path=='/api/v1/dashboard/execution':return 200,{'tasks':[task] if state['present'] else [],'agents':[],'keepers':[],'messages':[],'generated_at':STAMP,'status':{'project':'isolated-delete-proof'}}
 if path=='/api/v1/dashboard/planning':return 200,{'goals':[],'tasks':[task] if state['present'] else [],'mdal_loops':[],'generated_at':STAMP}
 if path=='/api/v1/dashboard/goals':return 200,{'approval_queue_state':{'state':'ready'},'tree':[],'summary':{'total_goals':0,'active_goals':0,'phase_counts':{},'total_tasks':int(state['present']),'done_tasks':0,'pending_approvals':0}}
 return (404 if path=='/api/v1/dashboard/dev-token' else 503),{'error':'isolated_fixture_endpoint_not_provided'}
try:
 with sync_playwright() as pw:
  browser=pw.chromium.launch(executable_path='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',headless=True)
  page=browser.new_page(viewport={'width':1700,'height':1200});page.on('pageerror',lambda e:errors.append(str(e)))
  def route(r):
   path=urlparse(r.request.url).path
   if '/api/' not in path and path not in ['/health','/mcp'] and 'events' not in path:r.continue_();return
   status,body=fixture(path,r.request.method)
   requests.append({'method':r.request.method,'path':path,'status':status,'request_body':r.request.post_data,'response':body})
   r.fulfill(status=status,content_type='application/json',body=json.dumps(body))
  page.route('**/*',route)
  try:
   page.goto(f'http://127.0.0.1:{server.server_port}/dashboard/index.html#workspace?section=planning&view=default',wait_until='domcontentloaded')
   page.get_by_role('button',name='태스크 삭제: Cleanup browser target',exact=True).click(timeout=20000)
   page.get_by_role('button',name='확인',exact=True).click()
   retry=page.get_by_role('button',name='삭제 후 정리 재시도',exact=True)
   retry.wait_for(timeout=15000)
   page.get_by_role('button',name='태스크 삭제: Cleanup browser target',exact=True).wait_for(state='detached')
   assert 'primary link store unreadable' in page.locator('body').inner_text()
   page.screenshot(path=str(P/'cleanup-pending.png'),full_page=True)
   (P/'cleanup-pending.txt').write_text(page.locator('body').inner_text())
   retry.click();retry.wait_for(state='detached')
   assert state['delete_calls']==2
   deletes=[x for x in requests if x['path']=='/api/v1/dashboard/tasks/delete']
   assert all(json.loads(x['request_body'])=={'task_id':'cleanup-target'} for x in deletes)
   page.screenshot(path=str(P/'cleanup-settled.png'),full_page=True)
   (P/'cleanup-settled.txt').write_text(page.locator('body').inner_text())
   result={'source_commit':receipt['source_commit'],'workflow_run_id':receipt['workflow_run_id'],'scope':'Real Chrome and CI-built Dashboard with synthetic HTTP deletion receipts; not backend runtime or deployment proof','passed':True,'same_id_delete_calls':2,'archive_sha256':receipt['archive_sha256'],'index_sha256':receipt['index_sha256'],'page_errors':errors}
   (P/'proof-receipt.json').write_text(json.dumps(result,indent=2));print(json.dumps(result))
  except Exception:
   page.screenshot(path=str(P/'failure.png'),full_page=True);(P/'failure.txt').write_text(page.locator('body').inner_text());raise
  finally:
   (P/'requests.json').write_text(json.dumps(requests,indent=2,ensure_ascii=False));(P/'page-errors.json').write_text(json.dumps(errors));browser.close()
finally:server.shutdown();server.server_close()
