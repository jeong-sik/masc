"""Edit runtime.toml, fail preview, then recover across a concurrent file edit.

The actual TUI opens a scripted $EDITOR twice. The second opening must contain
the rejected draft byte for byte. A current-file read must not silently adopt
its revision: the next POST conflicts, comparison displays the current text,
and explicit adoption permits a guarded retry of the retained draft.
"""
import hashlib
import json
import os
from pathlib import Path
import shlex
import sys
import tempfile
import threading

import tui_keyboard_harness as h
import tui_keyboard_runtime as runtime
from test_tui_runtime_account_form_pty import commit_receipt

RAW = runtime.RUNTIME_CONFIG_RAW_PATH
PREVIEW = RAW + "/preview"
SOURCE = 'value = 1\n# original file\n'
DRAFT = 'value = 2\n# retained operator draft\n'
CURRENT = 'value = 3\n# concurrent operator change\n'
PATH = "/workspace/config/runtime.toml"


def revision(text):
    return hashlib.sha256(b"runtime_config_source\x00" + text.encode()).hexdigest()


class Server:
    def __init__(self):
        self.text = SOURCE
        self.previews = 0
        self.saves = []
        self.lock = threading.Lock()

    def preview(self, _body):
        with self.lock:
            self.previews += 1
            if self.previews == 1:
                return 400, {"error": "fixture preview unavailable"}
        return 200, {"ok": True, "can_save": True,
                     "validation": {"valid": True, "issues": []}}

    def raw(self, body):
        with self.lock:
            if not body:
                return 200, {**runtime.runtime_config_read_metadata(),
                             "path": PATH, "source_text": self.text,
                             "source_revision": revision(self.text)}
            request = json.loads(body)
            self.saves.append(request)
            if request.get("expected_source_revision") != revision(self.text):
                return 409, {"error": "file changed", "code": "revision_conflict",
                             "current": {"source_path": PATH, "source_text": self.text,
                                         "source_revision": revision(self.text)}}
            self.text = request["source_text"]
            return 200, commit_receipt(self.text)


def run(binary):
    server = Server()
    fixtures = h.overview_event_http_fixtures()
    fixtures[RAW] = h.RequestHttpResponse(server.raw)
    fixtures[PREVIEW] = h.RequestHttpResponse(server.preview)
    with tempfile.TemporaryDirectory(prefix="tui-config-draft-") as folder:
        captured = Path(folder, "reopened.txt")
        opened = Path(folder, "opened")
        editor = Path(folder, "editor.py")
        editor.write_text(
            "import sys\nfrom pathlib import Path\n"
            f"opened=Path({str(opened)!r})\n"
            "source=Path(sys.argv[1])\n"
            "if opened.exists():\n"
            f"    Path({str(captured)!r}).write_bytes(source.read_bytes())\n"
            "else:\n"
            f"    source.write_text({DRAFT!r})\n"
            "    opened.touch()\n")

        def interact(process, fd, _slave, output, _base):
            h.tab_until(process, fd, output, b"MASC System")
            h.wait_for_output(process, fd, output, b"original file", start=0, timeout=5.0)
            h.send_and_wait(process, fd, output, b"e", b"fixture preview unavailable")
            screen = h.screen_text(bytes(output))
            assert b"retained operator draft" in screen, screen
            assert not server.saves, "preview failure reached the write endpoint"
            with server.lock:
                server.text = CURRENT
            h.send_and_wait(process, fd, output, b"r", b"Current file differs")
            h.send_and_wait(process, fd, output, b"e", b"Compare the current file")
            assert captured.read_text() == DRAFT, "reopened editor lost the rejected draft"
            with server.lock:
                assert server.text == CURRENT, "conflict overwrote the concurrent file"
                assert server.saves == [{"source_text": DRAFT,
                                         "expected_source_revision": revision(SOURCE)}]
            h.send_and_wait(process, fd, output, b"C", b"concurrent operator change")
            h.send_and_wait(process, fd, output, b"u", b"draft text retained")
            assert b"retained operator draft" in h.screen_text(bytes(output))
            h.send_and_wait(process, fd, output, b"S", b"File saved")
            with server.lock:
                assert server.text == DRAFT
                assert server.saves[-1] == {"source_text": DRAFT,
                                            "expected_source_revision": revision(CURRENT)}
            os.write(fd, b"q")

        h.run_terminal_scenario(binary,
            description="runtime.toml retains rejected draft and explicitly rebases after conflict",
            interact=interact, http_fixtures=fixtures, terminal_cols=120,
            extra_env={"EDITOR": shlex.join([sys.executable, str(editor)])})
    print("runtime.toml draft recovery: PASS")


if __name__ == "__main__":
    run(sys.argv[1])
