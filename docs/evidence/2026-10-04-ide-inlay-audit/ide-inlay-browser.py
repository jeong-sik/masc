import argparse
import json
import subprocess
from pathlib import Path
from playwright.sync_api import sync_playwright
out = Path(__file__).resolve().parent
parser = argparse.ArgumentParser()
parser.add_argument('--repo', type=Path, required=True)
args = parser.parse_args()
source = args.repo.resolve()
with sync_playwright() as p:
    browser = p.chromium.launch(headless=True)
    page = browser.new_page(viewport={'width':1280,'height':1000})
    errors=[]
    page.on('pageerror',lambda error: errors.append(str(error)))
    page.route('**/api/v1/**',lambda route:route.fulfill(status=200,content_type='application/json',body='{}'))
    page.goto('http://127.0.0.1:5181/dashboard/audit-inlay-preview.html',wait_until='domcontentloaded')
    page.wait_for_function("document.querySelectorAll('.cm-inlayHint').length === 6")
    data=page.evaluate('window.inlaySnapshot()')
    assert [h['label'] for h in data['hints']] == [': int',' (inferred)','left:','right:','A','B'],data
    assert [h['position'] for h in data['hints']] == [9,9,16,18,len(data['document']),len(data['document'])],data
    assert data['hints'][0]['tooltip']=='inferred type',data
    assert data['hints'][0]['parts'][1]['tooltip']=='**integer**',data
    assert errors==[],errors
    page.locator('#observed').evaluate('''(element,data)=>element.textContent=data.hints.map(h=>JSON.stringify({position:h.position,label:h.label,tooltip:h.tooltip,parts:h.parts})).join('\\n')''',data)
    page.screenshot(path=str(out/'ide-inlay-source-fixture.png'),full_page=True)
    result={'scope':'real CodeMirror and MASC LSP extension with synthetic WebSocket; not an actual language-server or production integration test','source_commit':subprocess.check_output(['git','rev-parse','HEAD'],cwd=source,text=True).strip(),'data':data,'page_errors':errors}
    (out/'ide-inlay-browser-result.json').write_text(json.dumps(result,ensure_ascii=False,indent=2))
    print('IDE inlay source-component browser fixture PASS')
    browser.close()
