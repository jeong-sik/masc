"""Actual CodeMirror/LSP extension with synthetic responses, no MASC server."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

from playwright.sync_api import sync_playwright

parser = argparse.ArgumentParser()
parser.add_argument('--repo', type=Path, required=True)
parser.add_argument('--url', required=True)
parser.add_argument('--output-dir', type=Path, required=True)
args = parser.parse_args()
root = args.repo.resolve()
output = args.output_dir.resolve()
output.mkdir(parents=True, exist_ok=True)
paths = ['dashboard/src/components/ide/ide-lsp-client.ts',
         'dashboard/src/components/ide/ide-editor-extensions.ts',
         'lib/server/server_ide_lsp_proxy.ml',
         'docs/evidence/2026-10-04-ide-codelens-audit/codelens-fixture.ts']
result = {'scope': 'real CodeMirror and MASC LSP extension with synthetic WebSocket; no real language server or production execution',
          'checkout_head': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip(),
          'source_sha256': {name: hashlib.sha256((root / name).read_bytes()).hexdigest() for name in paths},
          'status': 'running', 'page_errors': []}
try:
    with sync_playwright() as driver:
        browser = driver.chromium.launch(headless=True)
        try:
            result['browser'] = browser.version
            page = browser.new_page(viewport={'width': 1280, 'height': 900})
            page.on('pageerror', lambda error: result['page_errors'].append(str(error)))
            page.route('**/api/v1/**', lambda route: route.fulfill(status=200, content_type='application/json', body='{}'))
            page.goto(args.url, wait_until='domcontentloaded')
            page.wait_for_function("document.querySelectorAll('.cm-codelens-marker').length === 2")
            before = page.evaluate('window.codeLensSnapshot()')
            page.locator('.cm-codelens-marker').first.hover()
            page.locator('.cm-codelens-marker').first.click()
            page.keyboard.press('Enter')
            page.keyboard.press('Space')
            page.keyboard.press('Tab')
            after = page.evaluate('window.codeLensSnapshot()')
            result['before'] = before
            result['after'] = after
            result['label_received_focus'] = page.evaluate("document.activeElement?.classList.contains('cm-codelens-marker') ?? false")
            page.locator('#observed').evaluate('(element, data) => element.textContent = JSON.stringify(data, null, 2)', after)
            page.screenshot(path=str(output / 'codelens-source-fixture.png'), full_page=True)
            assert [label['text'] for label in after['labels']] == ['Run tests', '2 references'], after
            assert all(label['cursor'] != 'pointer' for label in after['labels']), after
            assert all(label['tooltip'] == '읽기 전용 정보 · 실행할 수 없음' for label in after['labels']), after
            assert all(label['tabIndex'] == -1 and not label['interactive'] for label in after['labels']), after
            assert not result['label_received_focus'], result
            assert after['document'] == before['document'], after
            assert 'workspace/executeCommand' not in after['messages'], after
            assert not result['page_errors'], result
            result['status'] = 'passed'
        finally:
            browser.close()
except Exception as error:
    result['status'] = 'failed'
    result['error'] = str(error)
    raise
finally:
    (output / 'codelens-browser-result.json').write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
print('IDE CodeLens source-component browser fixture PASS')
