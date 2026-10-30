#!/usr/bin/env python3
"""Explicit selected check: actual viewer WASM -> Chrome -> unavailable boundary.

Builds only the viewer's dev WASM artifact. No MASC/OCaml executable, native
viewer, provider or deployed service is built or used. Run this exact script
locally or select test/test_viewer_trpg_unavailable in the manual Test workflow.
"""
from contextlib import contextmanager
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import argparse
import hashlib
import html
import json
import os
import re
import shutil
import subprocess
import tempfile
import threading
import tomllib

ROOT = Path(__file__).resolve().parents[1]
VIEWER = ROOT / "viewer"


def run(argv, **kwargs):
    print("VIEWER_CHECK_COMMAND " + json.dumps([str(x) for x in argv]), flush=True)
    return subprocess.run([str(x) for x in argv], check=True, **kwargs)


@contextmanager
def serve(directory):
    class Handler(SimpleHTTPRequestHandler):
        def __init__(self, *args, **kwargs):
            super().__init__(*args, directory=directory, **kwargs)

        def log_message(self, *_):
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{server.server_port}"
    finally:
        server.shutdown()
        server.server_close()
        thread.join()


# The probe runs before the actual compiled module. It does not implement mode
# policy: it observes the Rust-published state, loading completion and I/O.
PROBE = r'''
<script>
const fixtureCase = new URL(location.href).searchParams.get('fixture');
if (fixtureCase === 'storage') localStorage.setItem('masc.viewer.last_mode', 'trpg');
const requested = [];
const actualFetch = window.fetch.bind(window);
window.fetch = (input, init) => {
  requested.push(String(typeof input === 'string' || input instanceof URL ? input : input.url));
  return actualFetch(input, init);
};
const actualEventSource = window.EventSource;
window.EventSource = class extends actualEventSource {
  constructor(url, options) { requested.push(String(url)); super(url, options); }
};
window.__viewerProbe = { requested };
let rejected = null;
function inspect() {
  const code = document.body.dataset.modeUnavailable;
  const loading = document.querySelector('#loading-screen');
  const runtimeReady = loading && loading.style.pointerEvents === 'none' && document.body.dataset.viewerBoot === 'ok';
  if (code && runtimeReady && !rejected) {
    const card = document.querySelector('[data-mode="trpg"]');
    const notice = document.querySelector('#mode-unavailable');
    rejected = {
      fixture: fixtureCase,
      code, runtimeReady, bodyClass: document.body.className,
      disabled: card?.disabled === true,
      noticeVisible: notice?.hidden === false,
      notice: notice?.textContent,
      storage: localStorage.getItem('masc.viewer.last_mode'),
      modeQuery: new URL(location.href).searchParams.get('mode'),
      requested: [...requested],
    };
    document.querySelector('[data-mode="monitor"]').click();
  }
  if (rejected && document.body.className === 'mode-monitor' && document.querySelector('#monitor-panel')?.classList.contains('active')) {
    const result = {...rejected,
      recoveredMode: document.body.className,
      recoveredPanelActive: document.querySelector('#monitor-panel').classList.contains('active'),
      unavailableCleared: !document.body.hasAttribute('data-mode-unavailable'),
      noticeHiddenAfterRecovery: document.querySelector('#mode-unavailable').hidden,
      requestedAfterRecovery: [...requested],
    };
    const output = document.createElement('pre');
    output.id = 'viewer-check-result'; output.textContent = JSON.stringify(result);
    document.body.append(output);
    return;
  }
  requestAnimationFrame(inspect);
}
requestAnimationFrame(inspect);
</script>
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--chrome", help="Actual Chrome/Chromium executable")
    args = parser.parse_args()
    chrome = args.chrome or next((shutil.which(name) for name in
                                  ("google-chrome", "chromium", "chromium-browser")
                                  if shutil.which(name)), None)
    if not chrome:
        raise RuntimeError("Chrome/Chromium is required; no fixture-only success is allowed")
    run(["rustc", "--version"])
    run(["rustup", "target", "add", "wasm32-unknown-unknown"])
    packages = tomllib.loads((VIEWER / "Cargo.lock").read_text())["package"]
    bindgen_version = next(p["version"] for p in packages if p["name"] == "wasm-bindgen")
    with tempfile.TemporaryDirectory(prefix="masc-viewer-wasm-") as directory:
        work = Path(directory)
        target = work / "target"
        env = dict(os.environ, CARGO_TARGET_DIR=str(target), CARGO_PROFILE_DEV_DEBUG="0")
        run(["cargo", "build", "--locked", "--manifest-path", VIEWER / "Cargo.toml",
             "--target", "wasm32-unknown-unknown"], env=env)
        tools = work / "tools"
        run(["cargo", "install", "wasm-bindgen-cli", "--version", bindgen_version,
             "--locked", "--root", tools])
        web = work / "web"
        web.mkdir()
        wasm = target / "wasm32-unknown-unknown" / "debug" / "masc-viewer.wasm"
        run([tools / "bin" / "wasm-bindgen", wasm, "--target", "web",
             "--no-typescript", "--out-dir", web, "--out-name", "viewer"])
        source = (VIEWER / "index.html").read_text()
        # Preserve the actual DOM and its boot handlers. Replace only Trunk's
        # build-time stylesheet attributes and add the equivalent module loader.
        source = source.replace('data-trunk rel="css"', 'rel="stylesheet"')
        source = source.replace('<body class="mode-home">', '<body class="mode-home">' + PROBE)
        source = source.replace('</body>', '''<script type="module">
import init from './viewer.js';
await init();
window.dispatchEvent(new Event('TrunkApplicationStarted'));
</script></body>''')
        (web / "index.html").write_text(source)
        shutil.copyfile(VIEWER / "style.css", web / "style.css")
        receipts = []
        with serve(str(web)) as origin:
            for case, query in (("query", "?fixture=query&mode=trpg"),
                                ("storage", "?fixture=storage")):
                command = [chrome, "--headless", "--disable-gpu", "--no-sandbox",
                           "--disable-dev-shm-usage", "--no-first-run",
                           f"--user-data-dir={work / ('profile-' + case)}",
                           "--virtual-time-budget=20000", "--dump-dom", origin + "/" + query]
                result = run(command, capture_output=True, text=True)
                match = re.search(r'<pre id="viewer-check-result">(.*?)</pre>', result.stdout, re.S)
                if not match:
                    print(result.stdout[-10000:])
                    print(result.stderr[-10000:])
                    raise AssertionError(f"{case}: actual WASM did not publish an unavailable result")
                observed = json.loads(html.unescape(match.group(1)))
                assert observed["code"] == "trpg_producer_absent", observed
                assert observed["runtimeReady"] and observed["disabled"] and observed["noticeVisible"], observed
                assert observed["bodyClass"] == "mode-home", observed
                assert observed["modeQuery"] == ("trpg" if case == "query" else None), observed
                assert observed["storage"] == ("trpg" if case == "storage" else None), observed
                assert not any("/api/v1/trpg/" in url for url in observed["requested"]), observed
                assert observed["recoveredMode"] == "mode-monitor" and observed["recoveredPanelActive"], observed
                assert observed["unavailableCleared"] and observed["noticeHiddenAfterRecovery"], observed
                assert not any("/api/v1/trpg/" in url for url in observed["requestedAfterRecovery"]), observed
                receipts.append(observed)
                print("VIEWER_WASM_OBSERVED " + json.dumps(observed, ensure_ascii=False), flush=True)
        print("VIEWER_WASM_PASS " + json.dumps({
            "cases": len(receipts), "profile": "dev debug=0", "target": "wasm32-unknown-unknown",
            "wasm_sha256": hashlib.sha256(wasm.read_bytes()).hexdigest(),
            "bindgen_version": bindgen_version,
        }), flush=True)


if __name__ == "__main__":
    main()
