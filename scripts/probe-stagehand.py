#!/usr/bin/env python3
"""Run the compiled Stagehand lane probe against a real Chromium and a local fixture.

The extension comes from connectors/browser/install-stagehand-extension.sh; the
probe drives an installed native browser Add-on, public tool hooks and the
shared Exact Output runner with a scripted loopback provider. Browser input,
process ownership, in-flight detach and fresh reattachment use production paths.
"""
import argparse
import http.server
import json
import pathlib
import re
import subprocess
import sys
import threading

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--chrome", type=pathlib.Path, required=True, help="Chromium-family executable")
parser.add_argument("--probe", type=pathlib.Path, required=True, help="built stagehand_browser_probe.exe")
parser.add_argument("--launcher", type=pathlib.Path, required=True, help="built masc_native_addon_launcher.exe")
parser.add_argument("--guardian", type=pathlib.Path, required=True, help="built masc_browser_process_owner.exe")
parser.add_argument("--worker", type=pathlib.Path, required=True, help="built masc_browser_addon_worker.exe")
parser.add_argument("--base-path", type=pathlib.Path, required=True, help="workspace to install the extension into")
parser.add_argument("--out", type=pathlib.Path, required=True)
args = parser.parse_args()

repo = pathlib.Path(__file__).resolve().parents[1]
out = args.out.resolve()
out.mkdir(parents=True, exist_ok=True)
# A failed rerun must not leave a previous screenshot or proof looking like new evidence.
for name in ("stagehand.png", "stagehand-proof.json", "pointer-feedback.json", "scroll-observed.json"):
    (out / name).unlink(missing_ok=True)

args.base_path.mkdir(parents=True, exist_ok=True)
installed = subprocess.run(
    ["bash", str(repo / "connectors/browser/install-stagehand-extension.sh"), "--base-path", str(args.base_path)],
    check=True, capture_output=True, text=True,
).stdout
(out / "install.txt").write_text(installed)
match = re.search(r'^extension = "(.+)"$', installed, re.MULTILINE)
if match is None:
    sys.exit("the installer printed no extension path")
extension = match.group(1)

# Each native action changes the title only after the page observes its input.
FIXTURE = b"""<!doctype html><html><head><meta charset="utf-8"><title>Stagehand fixture</title></head><body>
<h1>Order form</h1><p>Plan price: 42 USD</p>
<label for="email">Email</label><input id="email" type="email"
  oninput="document.title=this.value==='probe@example.test'?'filled':'unexpected fill'">
<button id="submit" style="position:fixed;left:20vw;top:20vh;width:100px;height:40px;box-sizing:border-box"
  onclick="document.body.dataset.clicked='yes';document.title='clicked'">Submit order</button>
<div id="drag-source"
  style="position:fixed;left:20vw;top:55vh;width:70px;height:40px;background:#789;touch-action:none"
>Pointer drag source</div>
<div id="drop-target"
  style="position:fixed;left:45vw;top:55vh;width:100px;height:60px;background:#9b8"
>Pointer drop target</div>
<div id="html5-source" draggable="true"
  style="position:fixed;left:20vw;top:70vh;width:70px;height:40px;background:#987"
  ondragstart="event.dataTransfer.setData('text/plain','stagehand-probe')"
>HTML5 drag source</div>
<div id="html5-target"
  style="position:fixed;left:45vw;top:70vh;width:100px;height:60px;background:#8b9"
  ondragover="event.preventDefault()"
  ondrop="event.preventDefault();if(event.isTrusted && event.dataTransfer.getData('text/plain')==='stagehand-probe'){document.title='html5-dragged';document.getElementById('html5-result').textContent='HTML5 drag completed'}"
>HTML5 drop target</div>
<style>#hover-message{position:fixed;left:70vw;top:20vh;width:250px;height:70px;background:#ddd}
#menu-trigger{opacity:0}#hover-message:hover #menu-trigger{opacity:1}
#trusted-menu{position:fixed;left:70vw;top:35vh}</style>
<div id="hover-message">Observed message <button id="menu-trigger">Open trusted menu</button></div>
<div id="trusted-menu" hidden><button id="menu-pick">Select trusted item</button></div>
<p id="trusted-result">Menu waiting</p>
<p id="scroll-result">Scroll not observed</p><p id="drag-result">Pointer drag not observed</p>
<p id="html5-result">HTML5 drag not observed</p>
<div style="height:220vh" aria-hidden="true"></div>
<script>
let pointerDrag = null;
const pointerSource = document.querySelector('#drag-source');
pointerSource.onpointerdown = event => {
  if (!event.isTrusted) return;
  pointerDrag = {id:event.pointerId,x:event.clientX,y:event.clientY,moved:false};
  pointerSource.setPointerCapture(event.pointerId);
};
pointerSource.onpointermove = event => {
  if (pointerDrag && event.isTrusted && event.pointerId === pointerDrag.id
      && (event.clientX !== pointerDrag.x || event.clientY !== pointerDrag.y))
    pointerDrag.moved = true;
};
pointerSource.onpointerup = event => {
  const started = pointerDrag; pointerDrag = null;
  if (!started || !event.isTrusted || event.pointerId !== started.id || !started.moved) return;
  const target = document.querySelector('#drop-target').getBoundingClientRect();
  if (event.clientX >= target.left && event.clientX < target.right
      && event.clientY >= target.top && event.clientY < target.bottom) {
    document.title = 'pointer-dragged';
    document.querySelector('#drag-result').textContent = 'Pointer drag completed';
  }
};
pointerSource.onpointercancel = () => { pointerDrag = null; };
let trustedDown = false;
document.querySelector('#menu-trigger').onpointerdown = event => { trustedDown = event.isTrusted; };
document.querySelector('#menu-trigger').onmousedown = event => {
  if (trustedDown && event.isTrusted) document.querySelector('#trusted-menu').hidden = false;
};
document.querySelector('#menu-pick').onclick = event => {
  if (event.isTrusted) { document.title='trusted-menu-picked'; document.querySelector('#trusted-result').textContent='Trusted menu selected'; }
};
// Registered before input: the probe observes this promise without producing
// a wheel event or changing scroll position. Resolve only after the page saw it.
window.stagehandProbeScrollObserved = new Promise(resolve => {
  addEventListener('scroll', () => {
    if (scrollY > 30) {
      document.title = 'scrolled';
      document.getElementById('scroll-result').textContent = 'Scroll confirmed';
      resolve(true);
    }
  });
});
// Observations belong to this fixture. The probe does not install a second
// browser executor or expose arbitrary evaluation through the Add-on.
let pendingObservation = Promise.resolve();
function publishObservation(name, value) {
  pendingObservation = pendingObservation.then(() => fetch('/observations/' + name, {
    method:'POST', headers:{'Content-Type':'application/json'},
    body:JSON.stringify({...value,url:location.href})
  }));
}
window.stagehandProbeScrollObserved.then(() => publishObservation('scroll-observed', {observed:true}));
let previousFeedback = '';
function observeFeedback() {
  const state = window[Symbol.for('masc.browser.pointer.feedback.v1')];
  const host = document.querySelector('[data-masc-browser-overlay]');
  if (state?.phase === 'finished') {
    const value = {actor:state.actor,phase:state.phase,action:state.action,requestId:state.requestId,
      observedPointer:!!state.pointer && Number.isFinite(state.pointer.x) && Number.isFinite(state.pointer.y),
      inert:host?.inert === true,hidden:host?.getAttribute('aria-hidden') === 'true',
      ignoresPointer:!!host && getComputedStyle(host).pointerEvents === 'none'};
    const encoded = JSON.stringify(value);
    if (encoded !== previousFeedback) {
      previousFeedback = encoded;
      publishObservation('pointer-feedback', value);
    }
  }
  requestAnimationFrame(observeFeedback);
}
requestAnimationFrame(observeFeedback);
</script>
</body></html>"""


class Fixture(http.server.BaseHTTPRequestHandler):
    def do_POST(self) -> None:
        name = {"/observations/pointer-feedback": "pointer-feedback.json",
                "/observations/scroll-observed": "scroll-observed.json"}.get(self.path)
        if name is None:
            self.send_error(404)
            return
        try:
            value = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))))
            if not isinstance(value, dict):
                raise ValueError("expected fixture observation")
        except (ValueError, json.JSONDecodeError):
            self.send_error(400)
            return
        target = out / name
        temporary = target.with_suffix(".tmp")
        temporary.write_text(json.dumps(value))
        temporary.replace(target)
        self.send_response(204)
        self.end_headers()

    def do_GET(self) -> None:
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(FIXTURE)))
        self.end_headers()
        self.wfile.write(FIXTURE)

    def log_message(self, format: str, *args: object) -> None:  # noqa: A002 - the base class names it
        del format, args


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Fixture)
threading.Thread(target=server.serve_forever, daemon=True).start()
fixture_url = f"http://127.0.0.1:{server.server_port}/"

# Fixture hang guard for attach, browser actions, in-flight detach and reattach.
PROBE_TIMEOUT_S = 600
with open(out / "probe.log", "w") as log:
    try:
        returncode = subprocess.run(
            [str(args.probe), "--chrome", str(args.chrome), "--extension", extension,
             "--fixture-url", fixture_url, "--out", str(out),
             "--launcher", str(args.launcher.resolve()), "--guardian", str(args.guardian.resolve()),
             "--worker", str(args.worker.resolve()), "--manifest", str(repo / "addons/browser/lane.toml")],
            stdout=log, stderr=subprocess.STDOUT, timeout=PROBE_TIMEOUT_S,
        ).returncode
    except subprocess.TimeoutExpired:
        # The log so far says which step never finished.
        returncode = None
server.shutdown()
sys.stdout.write((out / "probe.log").read_text())
if returncode is None:
    sys.exit(f"the probe did not finish within {PROBE_TIMEOUT_S} s; the log above ends at the step that hung")
sys.exit(returncode)
