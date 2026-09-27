#!/usr/bin/env python3
"""Run the compiled Stagehand lane probe against a real Chromium and a local fixture.

The extension comes from connectors/browser/install-stagehand-extension.sh; the
probe (test/stagehand_browser_probe.ml) drives MASC's own opener, backend and
Keeper tool handlers with a scripted model (RFC-browser-lane-stagehand §6.2).
"""
import argparse
import http.server
import pathlib
import re
import subprocess
import sys
import threading

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--chrome", type=pathlib.Path, required=True, help="Chromium-family executable")
parser.add_argument("--probe", type=pathlib.Path, required=True, help="built stagehand_browser_probe.exe")
parser.add_argument("--base-path", type=pathlib.Path, required=True, help="workspace to install the extension into")
parser.add_argument("--out", type=pathlib.Path, required=True)
args = parser.parse_args()

repo = pathlib.Path(__file__).resolve().parents[1]
out = args.out.resolve()
out.mkdir(parents=True, exist_ok=True)
# A failed rerun must not leave a previous screenshot or proof looking like new evidence.
for name in ("stagehand.png", "stagehand-proof.json"):
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
<div id="drag-source" draggable="true"
  style="position:fixed;left:20vw;top:55vh;width:70px;height:40px;background:#789"
  onpointerdown="document.body.dataset.dragStarted='yes'"
  ondragstart="event.dataTransfer.setData('text/plain','stagehand-probe')">Drag source</div>
<div id="drop-target"
  style="position:fixed;left:45vw;top:55vh;width:100px;height:60px;background:#9b8"
  ondragover="event.preventDefault()"
  ondrop="event.preventDefault();if(event.dataTransfer.getData('text/plain')==='stagehand-probe'){document.title='dragged';document.getElementById('drag-result').textContent='Drag completed'}"
  onpointerup="if(document.body.dataset.dragStarted==='yes'){document.title='dragged';document.getElementById('drag-result').textContent='Drag completed'}">Drop target</div>
<p id="scroll-result">Scroll not observed</p><p id="drag-result">Drag not observed</p>
<div style="height:220vh" aria-hidden="true"></div>
<script>
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
</script>
</body></html>"""


class Fixture(http.server.BaseHTTPRequestHandler):
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

# The probe opens, reads and closes one browser; ten minutes covers a cold
# first launch several times over.
PROBE_TIMEOUT_S = 600
with open(out / "probe.log", "w") as log:
    try:
        returncode = subprocess.run(
            [str(args.probe), "--chrome", str(args.chrome), "--extension", extension,
             "--fixture-url", fixture_url, "--out", str(out)],
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
