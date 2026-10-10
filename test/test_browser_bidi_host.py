#!/usr/bin/env python3
"""Owned Firefox integration for the CI-built native BiDi host.

Usage: python3 test_browser_bidi_host.py HOST FIREFOX
No WebExtension, profile reuse, or production MASC. The HTTP peer is the
native poll/result contract; actual commands execute in Firefox.
"""
import argparse
import hashlib
import traceback
import base64
import http.server
import json
import os
from pathlib import Path
import queue
import socket
import subprocess
import sys
import tempfile
import threading
import time
import uuid


def run(host, firefox, out=None):
    evidence = Path(out) if out else Path(tempfile.mkdtemp(prefix="masc-bidi-proof-"))
    evidence.mkdir(parents=True, exist_ok=True)
    receipts = []
    outcome = {"passed": False, "cleanup": [], "cleanup_errors": []}

    def retained(value):
        if isinstance(value, list):
            return [retained(item) for item in value]
        if isinstance(value, dict):
            if value.get("mimeType") == "image/png" and isinstance(value.get("data"), str):
                png = base64.b64decode(value["data"], validate=True)
                digest = hashlib.sha256(png).hexdigest()
                (evidence / (digest + ".png")).write_bytes(png)
                return {**value, "data": {"sha256": digest, "bytes": len(png), "path": digest + ".png"}}
            return {key: retained(item) for key, item in value.items()}
        return value

    with tempfile.TemporaryDirectory(prefix="masc-bidi-native-") as directory:
        root = Path(directory)
        token = "owned-bidi-test-lane-token"
        (root / "token").write_text(token)
        commands, results = queue.Queue(), queue.Queue()
        ready = threading.Event()
        stopped = threading.Event()
        metadata = []

        class Peer(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_args):
                pass

            def do_GET(self):
                data = {"/oversized": oversized, "/huge-control": huge_control}.get(self.path, fixture).read_bytes()
                self.send_response(200)
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def do_POST(self):
                if self.headers.get("Transfer-Encoding", "").lower() == "chunked":
                    chunks = []
                    while True:
                        size = int(self.rfile.readline().split(b";", 1)[0], 16)
                        if not size:
                            self.rfile.readline()
                            break
                        chunks.append(self.rfile.read(size))
                        self.rfile.read(2)
                    body = json.loads(b"".join(chunks))
                else:
                    body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                assert self.headers["x-lane-token"] == token
                metadata.append((self.headers["x-browser-client-id"], self.headers["x-browser-version"],
                                 self.headers["x-browser-transport"]))
                if self.path.endswith("/poll"):
                    ready.set()
                    try:
                        reply = commands.get(timeout=1)
                    except queue.Empty:
                        reply = {"ok": True, "empty": True}
                elif self.path.endswith("/result"):
                    results.put(body)
                    reply = {"ok": True}
                elif self.path.endswith("/disconnect"):
                    stopped.set()
                    reply = {"ok": True}
                else:
                    raise AssertionError(self.path)
                receipts.append({"path": self.path, "request": retained(body), "response": retained(reply),
                    "clientId": self.headers["x-browser-client-id"],
                    "browserVersion": self.headers["x-browser-version"]})
                data = json.dumps(reply).encode()
                self.send_response(200)
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Peer)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        # Two identical URL tabs are opened by the owned Firefox command line.
        fixture = root / "fixture.html"
        fixture.write_text('''<!doctype html><meta charset="utf-8"><title>BiDi native fixture</title>
<style>body{margin:0;min-height:2000px}#pad{width:500px;height:300px;background:lightblue}
#hover-result{display:none;position:fixed;top:0;right:0}#pad:hover+#hover-result{display:block}
#message{position:fixed;left:600px;top:100px;width:300px;height:60px;background:#eee}
#react{display:none;position:absolute;left:10px;top:10px;width:140px;height:30px}
#message:hover #react{display:block}#reactions{position:fixed;left:600px;top:200px}
#long{position:fixed;left:0;top:400px;width:500px;height:20px;overflow:hidden;white-space:nowrap}</style>
<a href="#followed">Observed destination</a><div id="pad">untouched</div><span id="hover-result"></span>
<div id="message"><button id="react" type="button">Add reaction</button></div><span id="reactions"></span>
<button id="long" type="button">''' + "a" * 499 + "\U0001F600tail" + '''</button><script>
document.querySelector('#react').addEventListener('click',e=>{
  document.querySelector('#reactions').textContent+=' reaction:'+e.isTrusted});
const pad=document.querySelector('#pad'); let down=false;
let presses=0;
pad.addEventListener('pointerdown',()=>{presses++});
pad.addEventListener('pointermove',e=>{document.querySelector('#hover-result').textContent='hover:'+e.isTrusted+':'+presses});
pad.onpointerdown=e=>{down=e.isTrusted;pad.setPointerCapture(e.pointerId)};
pad.onpointerup=e=>{pad.textContent='drag:'+down+':'+e.isTrusted+':'+e.clientX};
</script>''', encoding="utf-8")
        fixture_url = f"http://127.0.0.1:{server.server_port}/fixture"
        # A document whose source passes the helper's 1 MiB bound.
        oversized = root / "oversized.html"
        oversized.write_text('<!doctype html><meta charset="utf-8"><title>Oversized fixture</title><p>'
            + "x" * (1100 * 1024), encoding="utf-8")
        oversized_url = f"http://127.0.0.1:{server.server_port}/oversized"
        # A control whose value alone is larger than one BiDi socket message.
        huge_control = root / "huge-control.html"
        huge_control.write_text('<!doctype html><meta charset="utf-8"><title>Huge control</title><p>huge control</p>'
            '<input id="big" value="' + "v" * (9 * 1024 * 1024) + '">', encoding="utf-8")
        huge_control_url = f"http://127.0.0.1:{server.server_port}/huge-control"
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
        (root / "profile").mkdir()
        # The profile is checked only by a BiDi host; given without
        # --bidi-url it is refused, not dropped.
        unattached = subprocess.run([host, "--base-path", str(root), "--token-file", str(root / "token"),
            "--firefox-profile", str(root / "profile")], stdin=subprocess.DEVNULL, capture_output=True, timeout=10)
        said = (unattached.stdout + unattached.stderr).decode(errors="replace")
        assert unattached.returncode == 1 and "--firefox-profile needs --bidi-url" in said, (unattached.returncode, said)
        ff = native = None
        log = (evidence / "firefox.log").open("wb")
        native_log = (evidence / "native.log").open("wb")
        try:
            ff = subprocess.Popen([firefox, "--headless", "--no-remote", "--profile", str(root / "profile"),
                "--remote-debugging-port", str(port), fixture_url, fixture_url, oversized_url, huge_control_url],
                stdout=log, stderr=log)
            deadline = time.monotonic() + 20
            while True:
                try:
                    with socket.create_connection(("127.0.0.1", port), timeout=.2):
                        break
                except OSError:
                    if time.monotonic() >= deadline:
                        raise AssertionError("owned Firefox did not start")
                    time.sleep(.05)
            attach_argv = [host, "--base-path", str(root), "--token-file", str(root / "token"),
                "--server", f"http://127.0.0.1:{server.server_port}", "--bidi-url", f"ws://127.0.0.1:{port}/session"]
            # As the MASC server starts a host for the Keeper's Firefox.
            host_argv = attach_argv + ["--firefox-profile", str(root / "profile")]
            native = subprocess.Popen(host_argv, stdin=subprocess.DEVNULL, stdout=native_log, stderr=native_log)
            assert ready.wait(20), f"native peer did not register; stderr retained in {evidence / 'native.log'}"

            def call(verb, args):
                ident = str(uuid.uuid4())
                commands.put({"id": ident, "verb": verb, "args": args})
                result = results.get(timeout=25)
                assert result["id"] == ident
                return result

            def capture(tab):
                """A capture of a viewport at rest. A wheel can still be
                committing when a capture compares its before and after; that
                one answer is asked again, within a bound."""
                deadline = time.monotonic() + 5
                while True:
                    shot = call("page.capture", {"tabId": tab})
                    if not shot["ok"] and shot.get("error") == "viewport_changed_during_capture":
                        assert time.monotonic() < deadline, shot
                        continue
                    assert shot["ok"], shot
                    return shot

            tabs = call("tabs.list", {})
            assert tabs["ok"], tabs
            matching = [tab for tab in tabs["data"] if tab["url"] == fixture_url]
            assert len(matching) == 2, matching
            first, second = (tab["id"] for tab in matching)
            before = call("page.read", {"tabId": second})
            shot = call("page.capture", {"tabId": first})
            assert shot["ok"] and base64.b64decode(shot["data"]["data"]).startswith(b"\x89PNG")
            unhovered = call("page.read", {"tabId": first})
            assert "hover:true:0" not in unhovered["data"]["text"], unhovered
            hover = call("page.interact", {"tabId": first, "action": "hover_at",
                "expectedUrl": fixture_url, "viewport": shot["data"]["viewport"],
                "point": {"x": .05, "y": .05}})
            assert hover["ok"], hover
            hovered = call("page.read", {"tabId": first})
            assert "hover:true:0" in hovered["data"]["text"], hovered
            hover_shot = call("page.capture", {"tabId": first})
            assert hover_shot["ok"], hover_shot
            args = {"tabId": first, "action": "drag", "expectedUrl": fixture_url,
                "viewport": shot["data"]["viewport"], "from": {"x": .05, "y": .05}, "to": {"x": .2, "y": .2}}
            stale = {**args, "viewport": {**args["viewport"], "documentId": "stale"}}
            rejected = call("page.interact", stale)
            assert rejected["ok"] is False and rejected["effectPhase"] == "not_started", rejected
            untouched = call("page.read", {"tabId": first})
            assert "untouched" in untouched["data"]["text"]
            moved = call("page.interact", args)
            assert moved["ok"] is True, moved
            after = call("page.read", {"tabId": first})
            assert "drag:true:true:" in after["data"]["text"], after
            other = call("page.read", {"tabId": second})
            assert other["ok"] and other["data"] == before["data"]
            bounded = call("page.read", {"tabId": first, "maxChars": 5})
            assert bounded["ok"] and len(bounded["data"]["text"]) == 5 and bounded["data"]["truncated"]
            source = call("page.read", {"tabId": first, "includeHtml": True})
            assert source["ok"] and source["data"]["tabId"] == first, source
            assert source["data"]["htmlComplete"] is True and source["data"]["htmlUnavailableReason"] is None
            assert "<title>BiDi native fixture</title>" in source["data"]["html"], source
            assert source["data"]["documentId"] == shot["data"]["viewport"]["documentId"], source
            # Past the helper's bound the source is left out with its reason,
            # never cut. A tab still loading says so and is asked again.
            deadline = time.monotonic() + 20
            while True:
                listing = call("tabs.list", {})
                assert listing["ok"], listing
                large = [tab["id"] for tab in listing["data"] if tab["url"] == oversized_url]
                if large:
                    break
                assert time.monotonic() < deadline, listing
            assert len(large) == 1, listing
            while True:
                bounded_out = call("page.read", {"tabId": large[0], "includeHtml": True})
                if bounded_out["ok"]:
                    break
                assert "still loading" in bounded_out.get("error", ""), bounded_out
                assert time.monotonic() < deadline, bounded_out
            assert bounded_out["data"]["html"] is None and bounded_out["data"]["htmlComplete"] is False, bounded_out
            assert bounded_out["data"]["htmlUnavailableReason"] == "document_html_exceeds_1_mib", bounded_out
            assert bounded_out["data"]["documentId"] and bounded_out["data"]["tabId"] == large[0], bounded_out
            # An inventory too large for one socket message is refused in the
            # page with its size. The same connection then answers the next
            # read: nothing over the limit reached the socket.
            while True:
                listing = call("tabs.list", {})
                assert listing["ok"], listing
                huge = [tab["id"] for tab in listing["data"] if tab["url"] == huge_control_url]
                if huge:
                    break
                assert time.monotonic() < deadline, listing
            assert len(huge) == 1, listing
            while True:
                too_large = call("page.elements", {"tabId": huge[0]})
                assert too_large["ok"] is False and too_large.get("effectPhase") == "not_started", too_large
                if "still loading" not in too_large["error"]:
                    break
                assert time.monotonic() < deadline, too_large
            assert too_large["error"].startswith("page_answer_exceeds_bidi_reply_limit: "), too_large
            survived = call("page.read", {"tabId": huge[0]})
            assert survived["ok"] and survived["data"]["text"] == "huge control", survived
            observed = call("page.scene", {"tabId": first, "view": "content", "maxChars": 50000})
            assert observed["ok"], observed
            scene = observed["data"]
            links = [node for node in scene["nodes"] if node.get("href") == fixture_url + "#followed"]
            assert len(links) == 1, scene
            followed = call("page.interact", {"tabId": first, "action": "follow_link",
                "expectedUrl": fixture_url, "documentId": scene["documentId"], "nodeId": links[0]["nodeId"]})
            assert followed["ok"] and followed["data"]["destinationUrl"] == fixture_url + "#followed", followed
            # This fixture uses same-document fragment navigation. It does not
            # assert a full-navigation lifecycle barrier or replay the follow.
            fresh = call("page.read", {"tabId": first})
            assert fresh["ok"] and fresh["data"]["url"] == fixture_url + "#followed", fresh
            fresh_shot = call("page.capture", {"tabId": first})
            assert fresh_shot["ok"], fresh_shot
            wheel = call("page.interact", {"tabId": first, "action": "scroll_at",
                "expectedUrl": fresh["data"]["url"], "viewport": fresh_shot["data"]["viewport"],
                "point": {"x": .5, "y": .5}, "x": 0, "y": 120})
            assert wheel["ok"], wheel
            deadline = time.monotonic() + 5
            while True:
                scrolled = call("page.capture", {"tabId": first})
                # A wheel can still be committing when the first capture
                # compares its before/after viewport. Keep capture's
                # fail-closed result, but re-observe this one readiness state
                # inside the existing bounded scroll proof; other failures
                # remain immediate test failures.
                if (not scrolled["ok"]
                        and scrolled.get("error") == "viewport_changed_during_capture"):
                    assert time.monotonic() < deadline, scrolled
                    continue
                assert scrolled["ok"], scrolled
                if scrolled["data"]["viewport"]["scrollY"] > 0:
                    break
                assert time.monotonic() < deadline, "wheel effect absent; input not replayed"
            other = call("page.read", {"tabId": second})
            assert other["ok"] and other["data"] == before["data"]
            # A control that exists only while the pointer is over its row, the
            # shape of a chat message's reaction button. One BiDi connection
            # finds it, reveals it, sees it and presses it.
            def inventory():
                listed = call("page.elements", {"tabId": first})
                assert listed["ok"] and listed["data"]["tabId"] == first, listed
                return listed["data"]["elements"]

            def named(elements, text):
                return [element for element in elements if element["text"] == text]

            hidden = inventory()
            assert named(hidden, "Observed destination") and not named(hidden, "Add reaction"), hidden
            # A control's text is cut at 500 characters. The cut falls inside
            # an emoji's two UTF-16 units here; the inventory still arrives,
            # with the whole emoji as its last character.
            long_text = [element["text"] for element in hidden if element["text"].startswith("aaaa")]
            assert len(long_text) == 1 and len(long_text[0]) == 500, long_text
            assert long_text[0].endswith("\U0001F600"), long_text
            # The wheel above may still be settling, and the pointer guard
            # compares every viewport value: hover from a capture taken now.
            settled = capture(first)
            here, frame = settled["data"]["url"], settled["data"]["viewport"]
            assert frame["width"] >= 900 and frame["height"] >= 220, frame
            reveal = call("page.interact", {"tabId": first, "action": "hover_at", "expectedUrl": here,
                "viewport": frame, "point": {"x": 880 / frame["width"], "y": 150 / frame["height"]}})
            assert reveal["ok"], reveal
            revealed = named(inventory(), "Add reaction")
            assert len(revealed) == 1 and revealed[0]["tag"] == "button", revealed
            seen = call("page.scene", {"tabId": first, "view": "content", "maxChars": 50000})
            assert seen["ok"], seen
            buttons = [node for node in seen["data"]["nodes"] if node.get("text") == "Add reaction"]
            assert len(buttons) == 1 and buttons[0]["rects"], seen
            box = buttons[0]["rects"][0]
            frame = capture(first)["data"]["viewport"]
            pressed = call("page.interact", {"tabId": first, "action": "click_at", "expectedUrl": here,
                "viewport": frame, "point": {"x": (box["x"] + box["width"] / 2) / frame["width"],
                                             "y": (box["y"] + box["height"] / 2) / frame["height"]}})
            assert pressed["ok"], pressed
            reacted = call("page.read", {"tabId": first})
            assert reacted["data"]["text"].count("reaction:true") == 1, reacted
            # The inventory's selector is the one the DOM actions take.
            scripted = call("page.interact", {"tabId": first, "action": "click", "expectedUrl": here,
                "selector": revealed[0]["selector"]})
            assert scripted["ok"], scripted
            both = call("page.read", {"tabId": first})
            assert "reaction:true reaction:false" in both["data"]["text"], both
            other = call("page.read", {"tabId": second})
            assert other["ok"] and other["data"] == before["data"]
            assert len({row[0] for row in metadata}) == 1 and all(row[1] for row in metadata)
            assert all(row[2] == "webdriver_bidi" for row in metadata), metadata
            # A workspace has one BiDi host. A second one for it is refused
            # by the first one's record, before it asks Firefox for anything.
            def refused(name, argv):
                with (evidence / name).open("wb") as rival_log:
                    rival = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=rival_log, stderr=rival_log)
                    try:
                        rival_exit = rival.wait(timeout=30)
                    except subprocess.TimeoutExpired:
                        rival.kill()
                        rival.wait(timeout=5)
                        raise AssertionError(f"a second host was not refused; see {evidence / name}")
                said = (evidence / name).read_text(errors="replace")
                assert rival_exit == 1, said
                return said

            same_workspace = refused("rival-same-workspace.log", host_argv)
            assert f"another BiDi host (pid {native.pid}) is running for this workspace" in same_workspace, same_workspace
            # Firefox takes one session. A host of another workspace that
            # reaches this Firefox is refused by Firefox, leaves no session
            # of its own to end, and takes nothing from the first.
            other_root = evidence / "other-workspace"
            other_root.mkdir()
            (other_root / "token").write_bytes((root / "token").read_bytes())
            other_workspace = refused("rival-other-workspace.log", [
                host, "--base-path", str(other_root), "--token-file", str(other_root / "token"),
                "--server", f"http://127.0.0.1:{server.server_port}", "--bidi-url", f"ws://127.0.0.1:{port}/session"])
            assert "BiDi command rejected: session not created" in other_workspace, other_workspace
            assert "was not ended" not in other_workspace, other_workspace
            assert call("tabs.list", {})["ok"], "the attached host lost its session to a refused one"
            # Each host left its own record: the attached one is still
            # running, the refused one says why it ended.
            attached = json.loads((root / ".masc/browser-lane/bidi-host.json").read_text())
            assert attached["pid"] == native.pid and attached["ended"] is None, attached
            turned_away = json.loads((other_root / ".masc/browser-lane/bidi-host.json").read_text())
            assert turned_away["ended"]["reason"] == "BiDi command rejected: session not created", turned_away
            assert turned_away["ended"]["session_in_firefox"] == "refused", turned_away
            # A host that is stopped ends the BiDi session it created, so
            # this same Firefox, not restarted, takes the next host. Its tabs
            # are the ones the first host saw.
            first_host = metadata[0][0]
            seen = sorted(tab["url"] for tab in call("tabs.list", {})["data"])
            native.terminate()
            assert native.wait(timeout=10) == 0, f"stopped host exit; see {evidence / 'native.log'}"
            assert stopped.wait(5), "the stopped host did not tell the server"
            left = json.loads((root / ".masc/browser-lane/bidi-host.json").read_text())["ended"]
            assert left["session_in_firefox"] == "none" and left["reason"].startswith("stopped by"), left
            assert ff.poll() is None, "Firefox ended with the host's session"
            # A host given another profile keeps no session with this
            # Firefox: it ends the one it was given and says why.
            another_profile = refused("rival-another-profile.log",
                attach_argv + ["--firefox-profile", str(evidence / "another-profile")])
            assert "runs the profile" in another_profile, another_profile
            assert "was not ended" not in another_profile, another_profile
            elsewhere = json.loads((root / ".masc/browser-lane/bidi-host.json").read_text())["ended"]
            assert "runs the profile" in elsewhere["reason"] and elsewhere["session_in_firefox"] == "none", elsewhere
            assert elsewhere["because"]["kind"] == "profile_not_kept", elsewhere
            assert elsewhere["because"]["expected"] == str(evidence / "another-profile"), elsewhere
            assert elsewhere["because"]["found"], elsewhere
            # Firefox reports the profile path as it was given; a link to
            # the same directory is the same profile.
            (root / "profile-link").symlink_to(root / "profile")
            ready.clear()
            native = subprocess.Popen(attach_argv + ["--firefox-profile", str(root / "profile-link")],
                stdin=subprocess.DEVNULL, stdout=native_log, stderr=native_log)
            assert ready.wait(20), f"a second host did not attach; see {evidence / 'native.log'}"
            again = call("tabs.list", {})
            assert again["ok"] and sorted(tab["url"] for tab in again["data"]) == seen, again
            assert metadata[-1][0] != first_host, "the second host is a new client"
            outcome.update(passed=True, tabs=matching, version=metadata[0][1])
        except BaseException:
            outcome["error"] = traceback.format_exc()
            print(f"Native BiDi failure diagnostics: {evidence / 'native.log'}", file=sys.stderr)
            raise
        finally:
            original_error = sys.exc_info()[1]

            def clean(stage, action):
                try:
                    action()
                except BaseException as error:
                    outcome["cleanup_errors"].append({"stage": stage, "error": repr(error)})

            for name, process in (("native", native), ("firefox", ff)):
                if process is None:
                    continue

                def stop_process():
                    if process.poll() is None:
                        process.terminate()
                        try:
                            process.wait(timeout=10)
                        except subprocess.TimeoutExpired:
                            process.kill()
                            process.wait(timeout=5)
                            outcome["cleanup_errors"].append({"stage": name, "error": "required SIGKILL"})
                    outcome["cleanup"].append({"name": name, "pid": process.pid, "exit": process.returncode})

                clean(name, stop_process)
            clean("firefox-log", log.close)
            clean("native-log", native_log.close)
            clean("http-shutdown", server.shutdown)
            clean("http-close", server.server_close)
            clean("http-thread", lambda: thread.join(timeout=5))
            if thread.is_alive():
                outcome["cleanup_errors"].append({"stage": "http-thread", "error": "still alive"})
            if outcome["cleanup_errors"]:
                outcome["passed"] = False
            (evidence / "receipts.json").write_text(json.dumps(receipts, indent=2))
            (evidence / "outcome.json").write_text(json.dumps(outcome, indent=2))
            print(json.dumps({"out": str(evidence), **outcome}))
            if outcome["cleanup_errors"] and original_error is None:
                raise AssertionError("owned process cleanup failed; see outcome.json")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("host")
    parser.add_argument("firefox")
    parser.add_argument("--out", type=Path)
    args = parser.parse_args()
    run(args.host, args.firefox, args.out)
