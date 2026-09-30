"""Capture isolated synthetic fixture screens; never open an operator session."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from playwright.sync_api import sync_playwright

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'docs/evidence/tui-audit-2026-09-30/baseline'
sys.path.insert(0, str(ROOT / 'test'))
import test_tui_keyboard_input as h
spec = importlib.util.spec_from_file_location('capture', ROOT / 'scripts/capture-tui-screenshots.py')
c = importlib.util.module_from_spec(spec)
spec.loader.exec_module(c)
c.EXECUTABLE = Path(sys.argv[1]).resolve()
start_hash = hashlib.sha256(c.EXECUTABLE.read_bytes()).hexdigest()
commit = subprocess.check_output([str(c.EXECUTABLE), '--build-commit'], text=True).strip()
OUT.mkdir(parents=True, exist_ok=True)
os.environ['MASC_TOKEN'] = 'masc-tui-keyboard-regression-token'
os.environ['PATH'] = h.path_without_masc(os.environ.get('PATH', ''))
fixtures = h.overview_event_http_fixtures()
fixtures.update(h.keeper_runtime_http_fixtures())
fixtures.update(h.row_budget_http_fixtures())
fixtures[h.REPOSITORIES_PATH] = h.repositories_fixture()
post = h.board_selection_post('layout', '댓글 폭 기준 화면', '본문과 댓글의 독립적인 폭을 확인합니다.\n' * 8)
comments = [dict(h.board_detail_comment('layout-comment',
            '긴 댓글 본문은 작성자 옆의 좁은 잔여 폭이 아닌 댓글 영역 전체를 사용해야 합니다.\n' * 10),
            author='wkbl-layout-reviewer-with-long-name')]
post['comment_count'] = 1
fixtures['/api/v1/board?sort_by=hot'] = (200, {'posts': [post]})
fixtures['/api/v1/board/post-layout?format=flat'] = (200, {'post': post, 'comments': comments})
results = []

def shot(page, stem):
    page.wait_for_timeout(200)
    text = page.evaluate("""() => {const b=window.term.buffer.active;return Array.from({length:window.term.rows},(_,i)=>b.getLine(b.viewportY+i)?.translateToString(true)||'').join('\\n');}""")
    (OUT / (stem + '.txt')).write_text(text)
    page.locator('.xterm-screen').screenshot(path=str(OUT / (stem + '.png')))
    dims = page.evaluate('() => ({columns: window.term.cols, rows: window.term.rows})')
    results.append({'stem': stem, 'terminal': dims, 'provenance': 'baseline_binary_fixture_PTY'})
    (OUT / 'manifest.json').write_text(json.dumps({'binary_commit':commit,'binary_sha256':start_hash,
        'captures':results,'complete':False,'limitations':['Synthetic fixture data','Baseline before fixes','Missing fixture API returns HTTP503','Terminal dimensions are measured, not filename values']},ensure_ascii=False,indent=2)+'\n')
    print(json.dumps(results[-1]), flush=True)

surfaces = [('dashboard','go Dashboard','MASC Dashboard'),('work','go Work','MASC Work'),
            ('keepers','go Keepers','MASC Keepers'),('usage','go Usage','MASC Usage'),
            ('board','go Board','MASC Board'),('workspace','go Workspace','MASC Workspace'),
            ('system','go System','runtime.toml')]
with tempfile.TemporaryDirectory(prefix='masc-tui-audit-fixture-') as base:
    h.seed_workspace(base)
    h.seed_row_budget_workspace(base)
    with h.test_http_endpoint(h.with_workspace_identity(fixtures, base), None) as (port, start, identity):
        identity(base)
        start()
        with sync_playwright() as p:
            browser = p.chromium.launch(headless=True)
            with c.ttyd_session(browser, Path(base), port, 120, 38, 'tui-audit-fixture') as page:
                for width in (80,120,240):
                    page.set_viewport_size({'width':int(width*8.5)+24,'height':38*17+24})
                    for name,query,needle in surfaces:
                        if not c.goto_surface(page,query,needle):
                            raise AssertionError((query,c.screen_text(page)))
                        shot(page,f'{name}-{width}')
                    if not c.goto_surface(page,'go Board','MASC Board'):
                        raise AssertionError('Board unavailable')
                    page.keyboard.press('Enter')
                    page.wait_for_timeout(700)
                    shot(page,f'board-detail-{width}')
            browser.close()
assert hashlib.sha256(c.EXECUTABLE.read_bytes()).hexdigest() == start_hash
(OUT / 'manifest.json').write_text(json.dumps({'binary_commit':commit,'binary_sha256':start_hash,
    'captures':results,'complete':True,'limitations':['Synthetic fixture data','Baseline before fixes','Missing fixture API returns HTTP503','Terminal dimensions are measured, not filename values']},ensure_ascii=False,indent=2)+'\n')
