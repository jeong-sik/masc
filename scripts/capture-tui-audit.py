"""Capture isolated synthetic fixture screens; never open an operator session."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SCREEN_JS = """() => {const b=window.term.buffer.active;return Array.from({length:window.term.rows},(_,i)=>b.getLine(b.viewportY+i)?.translateToString(true)||'').join('\\n');}"""


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_manifest(out, manifest):
    temporary = out / 'manifest.json.tmp'
    temporary.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')
    temporary.replace(out / 'manifest.json')


def require_unchanged(paths, hashes):
    for name, path in paths.items():
        if digest(path) != hashes[name]:
            raise RuntimeError(f'capture input changed during the run: {name}')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('executable', help='native TUI executable, launched directly by ttyd')
    parser.add_argument('--out', default='docs/evidence/tui-audit-2026-09-30/baseline')
    parser.add_argument('--provenance', default='baseline_binary_fixture_PTY')
    parser.add_argument('--binary-file', help='optional alias for the same executable; wrappers are refused')
    parser.add_argument('--ttyd', default='ttyd', help='ttyd executable name on PATH or explicit path')
    parser.add_argument('--board-only', action='store_true')
    parser.add_argument('--panes-only', action='store_true')
    parser.add_argument('--rows', type=int, default=32)
    parser.add_argument('--workspace-currency', action='store_true')
    parser.add_argument('--author', default='wkbl-layout-reviewer-with-long-name')
    args = parser.parse_args()
    if args.board_only and args.panes_only:
        parser.error('--board-only and --panes-only are mutually exclusive')
    out = ROOT / args.out
    out.mkdir(parents=True, exist_ok=True)
    manifest = {
        'captures': [], 'complete': False,
        'limitations': ['Synthetic fixture data', 'Direct native executable only; no wrapper provenance claim',
                       'Missing fixture API returns HTTP503', 'Terminal dimensions are measured, not filename values'],
    }
    # A failed refresh must not leave the previous run's complete manifest.
    write_manifest(out, manifest)
    executable = Path(args.executable).resolve(strict=True)
    binary_path = Path(args.binary_file or args.executable).resolve(strict=True)
    if not executable.samefile(binary_path):
        raise ValueError('--binary-file must identify the executable actually launched; run capture inside the binary host')
    # ELF and Mach-O (including universal) executables have an authoritative
    # file-format signature. A shell/Python driver cannot attest another file.
    with executable.open('rb') as stream:
        magic = stream.read(4)
    if magic not in (b'\x7fELF', b'\xfe\xed\xfa\xce', b'\xce\xfa\xed\xfe',
                     b'\xfe\xed\xfa\xcf', b'\xcf\xfa\xed\xfe',
                     b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca',
                     b'\xca\xfe\xba\xbf', b'\xbf\xba\xfe\xca'):
        raise ValueError('capture requires the native TUI executable, not a wrapper script')
    ttyd = shutil.which(args.ttyd)
    if ttyd is None:
        raise FileNotFoundError(f'ttyd is not executable: {args.ttyd}')
    inputs = {
        'executable': executable,
        'capture_script': Path(__file__).resolve(),
        'fixture_helper': ROOT / 'test/test_tui_keyboard_input.py',
        'terminal_helper': ROOT / 'scripts/capture-tui-screenshots.py',
    }
    hashes = {name: digest(path) for name, path in inputs.items()}
    commit = subprocess.check_output([str(executable), '--build-commit'], text=True).strip()
    manifest.update(binary_commit=commit, binary_sha256=hashes['executable'],
                    launched_executable=str(executable), input_sha256=hashes,
                    fixture_parameters={'author': args.author, 'board_only': args.board_only, 'panes_only': args.panes_only,
                                        'workspace_currency': args.workspace_currency})
    write_manifest(out, manifest)

    from playwright.sync_api import sync_playwright, TimeoutError as PlaywrightTimeoutError
    sys.path.insert(0, str(ROOT / 'test'))
    import test_tui_keyboard_input as h
    spec = importlib.util.spec_from_file_location('capture', inputs['terminal_helper'])
    c = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(c)
    c.EXECUTABLE = executable
    c.TTYD = Path(ttyd).resolve()
    os.environ['MASC_TOKEN'] = 'masc-tui-keyboard-regression-token'
    os.environ['PATH'] = h.path_without_masc(os.environ.get('PATH', ''))
    fixtures = h.overview_event_http_fixtures()
    fixtures.update(h.keeper_runtime_http_fixtures())
    fixtures.update(h.row_budget_http_fixtures())
    fixtures["/api/v1/gate/keepers?detailed=true"] = h.keeper_runtime_http_fixtures()["/api/v1/gate/keepers?detailed=true"]
    fixtures["/api/v1/runtime/config/raw"] = (503, {"error": "runtime config load failed: fixture configuration unavailable"})
    if args.workspace_currency:
        _, roster = fixtures["/api/v1/gate/keepers?detailed=true"]
        roster["candle"] = {"status": "ready", "issued_milli": "100000", "burned_milli": "10000", "circulating_milli": "90000"}
        for keeper in roster["keepers"]:
            keeper["candle_balance_milli"] = "12500"
            keeper["candle_account_revision"] = "a" * 64
    fixtures[h.REPOSITORIES_PATH] = h.repositories_fixture()
    goal = h.planning_goal('goal-audit-ready', 'Audit goal')
    goal.update(metric='checks', target_value='5', task_count=1, task_done_count=0,
                measurement={'state': 'not_recorded'}, stagnation_seconds=None,
                tasks=[{'id': 'task-audit-ready'}], children=[])
    fixtures[h.PLANNING_PATH] = h.planning_snapshot([goal])
    fixtures[h.DASHBOARD_GOALS_PATH] = (200, {'tree': [goal]})
    _, runtime = h.empty_runtime_resolved_fixture()
    runtime['provider_usage_windows'] = [{
        'scope': 'provider:audit', 'scope_id': hashlib.md5(b'provider:audit').hexdigest(),
        'providers': [{'id': 'audit', 'display_name': 'Audit provider'}],
        'state': 'reported', 'windows': [{
            'limit_id': None, 'window': {'kind': 'five_hour'}, 'role': 'gates_model_calls',
            'utilization': {'unit': 'fraction', 'value': 0.4},
            'resets_at': None, 'observed_at': 1787356800.0, 'source': 'fixture'}],
    }]
    fixtures[h.RUNTIME_RESOLVED_PATH] = (200, runtime)
    post = h.board_selection_post('layout', '댓글 폭 기준 화면', '본문과 댓글의 독립적인 폭을 확인합니다.\n' * 8)
    comments = [dict(h.board_detail_comment('layout-comment',
                '긴 댓글 본문은 작성자 옆의 좁은 잔여 폭이 아닌 댓글 영역 전체를 사용해야 합니다.\n' * 10),
                author=args.author)]
    post['comment_count'] = 1
    fixtures['/api/v1/board?sort_by=hot'] = (200, {'posts': [post]})
    fixtures['/api/v1/board/post-layout?format=flat'] = (200, h.board_detail_page(post, comments))
    if args.panes_only:
        fixtures.update(h.code_lane_fixtures())
        fixtures['/mcp'] = h.resources_mcp_fixture()['/mcp']
        run = h.fusion_run('pane-audit', keeper='alpha')
        fixtures[h.FUSION_RUNS_PATH] = h.fusion_runs_response([run])
        fixtures[f'{h.FUSION_RUNS_PATH}/pane-audit'] = h.fusion_detail_response(run, 'Pane audit synthesis')
    # The MCP callable is bound by the hashed fixture helper, while the other
    # actual response values remain in the fixture digest.
    fixture_values = {key: ({'factory': 'resources_mcp_fixture'} if key == '/mcp' and args.panes_only else value)
                      for key, value in fixtures.items()}
    manifest['fixture_sha256'] = hashlib.sha256(json.dumps(fixture_values, sort_keys=True, ensure_ascii=False).encode()).hexdigest()
    write_manifest(out, manifest)

    def wait_ready(page, markers):
        try:
            page.wait_for_function(
                '(markers) => {const text=(' + SCREEN_JS + ')(); return markers.every(marker => text.includes(marker));}',
                arg=markers, timeout=15000)
        except PlaywrightTimeoutError as error:
            observed = page.evaluate(SCREEN_JS)
            raise RuntimeError(f'fixture readiness missing {markers!r}: {observed}') from error

    def board_list(page):
        if not c.goto_surface(page, 'go Board', 'MASC Board'):
            raise RuntimeError(('Board unavailable', c.screen_text(page)))
        # Re-selecting Board retains its reader mode. Left explicitly closes it.
        page.keyboard.press('ArrowLeft')
        wait_ready(page, ['Sort [s]', '댓글 폭 기준 화면'])

    def shot(page, stem, markers):
        wait_ready(page, markers)
        if not page.evaluate(c.FREEZE_JS):
            raise RuntimeError('terminal is unavailable to freeze')
        try:
            # Drain writes already queued before freeze and let the DOM paint
            # that same buffer before reading either half of the evidence pair.
            page.evaluate('''async () => {
                await new Promise(resolve => window.__mascWrite('', resolve));
                await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
            }''')
            text = page.evaluate(SCREEN_JS)
            if not all(marker in text for marker in markers):
                raise RuntimeError(f'fixture readiness changed before capture: {stem}: {text}')
            text_path, image_path = out / (stem + '.txt'), out / (stem + '.png')
            text_path.write_text('\n'.join(line.rstrip() for line in text.splitlines()) + '\n')
            page.locator('.xterm-screen').screenshot(path=str(image_path))
            dims = page.evaluate('() => ({columns: window.term.cols, rows: window.term.rows})')
            entry = {'stem': stem, 'terminal': dims, 'provenance': args.provenance,
                     'ready_markers': markers, 'text_sha256': digest(text_path), 'png_sha256': digest(image_path)}
            manifest['captures'].append(entry)
            write_manifest(out, manifest)
            print(json.dumps(entry), flush=True)
        finally:
            page.evaluate(c.THAW_JS)

    surfaces = [
        ('dashboard', 'go Dashboard', 'MASC Dashboard', ['Health: ok']),
        ('work', 'go Work', 'MASC Work', ['Audit goal']),
        ('keepers', 'go Keepers', 'MASC Keepers', ['alpha', 'beta']),
        ('usage', 'go Usage', 'MASC Usage', ['Audit provider', '40%']),
        ('board', 'go Board', 'MASC Board', ['Sort [s]', '댓글 폭 기준 화면']),
        ('workspace', 'go Workspace', 'MASC Workspace', ['/srv/masc/workspace/masc']),
        ('system', 'go System', 'runtime.toml', ['runtime config load failed:']),
    ]
    with tempfile.TemporaryDirectory(prefix='masc-tui-audit-fixture-') as base:
        h.seed_workspace(base)
        h.seed_row_budget_workspace(base)
        with h.test_http_endpoint(h.with_workspace_identity(fixtures, base), None) as (port, start, identity):
            identity(base)
            start()
            with sync_playwright() as p:
                browser = p.chromium.launch(headless=True)
                try:
                    with c.ttyd_session(browser, Path(base), port, 120, args.rows, 'tui-audit-fixture') as page:
                        for width in ((240,) if args.board_only else (80, 120, 240)):
                            geometry = page.evaluate('''() => {
                                const rect = document.querySelector('.xterm-screen').getBoundingClientRect();
                                return {cols: window.term.cols, rows: window.term.rows,
                                        cellWidth: rect.width / window.term.cols,
                                        cellHeight: rect.height / window.term.rows};
                            }''')
                            viewport = page.viewport_size
                            page.set_viewport_size({
                                'width': round(viewport['width'] + (width - geometry['cols']) * geometry['cellWidth']),
                                'height': round(viewport['height'] + (args.rows - geometry['rows']) * geometry['cellHeight']),
                            })
                            page.wait_for_function('(size) => window.term.cols === size[0] && window.term.rows === size[1]',
                                                   arg=[width, args.rows], timeout=15000)
                            if args.panes_only:
                                c.goto_surface(page, 'go System', 'runtime.toml')
                                page.keyboard.press('s')
                                wait_ready(page, ['Event Log (JSON)'])
                                page.keyboard.press('Enter')
                                shot(page, f'resources-{width}', ['MCP resource', 'application/json', 'status'])
                                c.goto_surface(page, 'go code', 'MASC Workspace / Code')
                                if width == 80:
                                    wait_ready(page, ['README.md'])
                                    page.keyboard.press('Home')
                                    page.keyboard.press('Enter')
                                    wait_ready(page, ['a.ml'])
                                    page.keyboard.press('j')
                                    page.keyboard.press('Enter')
                                shot(page, f'code-{width}', ['let x = 1', 'a.ml'])
                                c.goto_surface(page, 'go fusion', 'MASC Fusion')
                                wait_ready(page, ['pane-audit'])
                                page.keyboard.press('Enter')
                                page.keyboard.press('Home')
                                shot(page, f'fusion-{width}', ['Original question:', 'question-proof-501'])
                                page.keyboard.press('End')
                                shot(page, f'fusion-evidence-{width}', ['EVIDENCE RECORDED', 'Pane audit synthesis'])
                                continue
                            for name, query, title, ready in ([surfaces[4]] if args.board_only else surfaces):
                                if name == 'board':
                                    board_list(page)
                                elif not c.goto_surface(page, query, title):
                                    raise RuntimeError((query, c.screen_text(page)))
                                if name == 'usage' and args.workspace_currency:
                                    for _ in range(3):
                                        if 'Candle · workspace supply' in page.evaluate(SCREEN_JS):
                                            break
                                        expected = ('Candle · workspace supply'
                                                    if 'Quota scope trend' in page.evaluate(SCREEN_JS)
                                                    else 'Quota scope trend')
                                        page.keyboard.press('v')
                                        wait_ready(page, [expected])
                                    ready = ['Candle · workspace supply', 'Candle circulating: 90.000']
                                shot(page, f'{name}-{width}', ready)
                                if name == 'keepers':
                                    page.keyboard.press('Home')
                                    page.keyboard.press('Enter')
                                    shot(page, f'keeper-info-{width}', ['Name:', 'alpha'])
                                    page.keyboard.press('Escape')
                                    wait_ready(page, ['MASC Keepers'])
                                    page.keyboard.press('c')
                                    shot(page, f'keeper-chat-{width}', ['Keepers ▸ alpha ▸ chat', 'Context'])
                                    page.keyboard.press('Escape')
                                    wait_ready(page, ['MASC Keepers'])
                            board_list(page)
                            page.keyboard.press('Enter')
                            shot(page, f'board-detail-{width}', ['Comments', '긴 댓글 본문은'])
                finally:
                    browser.close()
    require_unchanged(inputs, hashes)
    manifest['complete'] = True
    write_manifest(out, manifest)


if __name__ == '__main__':
    main()
