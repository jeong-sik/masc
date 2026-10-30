"""Run the actual bounded form-semantics section in an isolated Playwright browser.
The main WebDriver scene suite remains unexecuted; this is fixture evidence only.
"""
import ast,json,textwrap
from pathlib import Path
from playwright.sync_api import sync_playwright
root=Path('/private/tmp/masc-40187-controls-response')
out=Path('/private/tmp/masc-child-40187-rendered-controls-proof');out.mkdir(exist_ok=True)
scene=(root/'lib/browser_scene_script.ml').read_text().split('let runtime = {js|',1)[1].split('|js}',1)[0]
interaction=(root/'lib/browser_interaction.ml').read_text().split('let script = {js|',1)[1].split('|js}',1)[0]
elements_script=(root/'lib/browser_page_script.ml').read_text().split('let elements = {|',1)[1].split('|}',1)[0]
source=(root/'test/test_browser_scene.py').read_text();tree=ast.parse(source)
body=next(node.body for node in tree.body if isinstance(node,ast.Try))
start=next(i for i,node in enumerate(body) if isinstance(node,ast.Expr) and isinstance(node.value,ast.Call) and node.value.args and isinstance(node.value.args[0],ast.Constant) and isinstance(node.value.args[0].value,str) and 'id="explicit-label"' in node.value.args[0].value)
end=next(i for i,node in enumerate(body[start:],start) if isinstance(node,ast.Assign) and any(isinstance(t,ast.Name) and t.id=='form_png' for t in node.targets))
from types import SimpleNamespace
a=SimpleNamespace(out=out)
checks=[]
with sync_playwright() as p:
 browser=p.firefox.launch(headless=True,executable_path='/Users/dancer/Library/Caches/ms-playwright/firefox-1532/firefox/Nightly.app/Contents/MacOS/firefox')
 try:
  page=browser.new_page(viewport={'width':1400,'height':1800})
  def js(script,args=[]):
   value=page.evaluate('(args) => {return (new Function("arguments",'+json.dumps(script)+'))(args)}',args)
   if isinstance(value,dict) and 'interactionFailure' in value:raise RuntimeError(value['interactionFailure']['message'])
   return value
  def observe():return js(scene+'\nreturn browserScene(arguments[0]);',[{'mode':'read','maxChars':50000}])
  def control(s,label):return next(n for n in s['nodes'] if n['kind']=='control' and n['text']==label)
  def act(s,n,**kw):return js(scene+interaction,[{'documentId':s['documentId'],'nodeId':n['nodeId'],'expectedUrl':s['url'],**kw}])
  def check(name,condition,seen=None):
   if not condition:raise AssertionError((name,seen))
   checks.append(name)
  module=ast.Module(body=body[start:end],type_ignores=[])
  exec(compile(module,str(root/'test/test_browser_scene.py'),'exec'),globals())
  # Reading again must never alter page DOM/CSS or browser selection/focus.
  before=js('return document.documentElement.outerHTML;');seen=observe()
  check('read-only scene preserves DOM/CSS',before==js('return document.documentElement.outerHTML;'))
  page.screenshot(path=str(out/'fixture-firefox.png'),full_page=True)
  (out/'scene.json').write_text(json.dumps(seen,ensure_ascii=False,indent=2))
  (out/'proof.json').write_text(json.dumps({'scope':'isolated Firefox actual form semantics fixture; full WebDriver suite unexecuted','checks':checks,'source_head':'2e5dd424a65a564b3fb425ceb462cdef7f251b8f + uncommitted response','browser':browser.version},ensure_ascii=False,indent=2))
  print(json.dumps({'passed':len(checks),'browser':browser.version,'artifact':str(out)}))
 finally:browser.close()
