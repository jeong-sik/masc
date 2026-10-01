"""Creation recovers authored inputs and hands the first request to its Keeper."""
import base64
import json
import os
from pathlib import Path
import shlex
import sys
import tempfile
import time

import test_tui_keyboard_input as h
import test_tui_home_journey_pty as home

SOURCE_MODULES = (
    "bin/masc_tui.ml", "bin/masc_tui_types.ml", "bin/masc_tui_editor.ml",
    "bin/masc_tui_http.ml", "bin/masc_cli_keeper_create.ml",
)
CREATE_PATH = "/api/v1/keepers/gamma/up"
MALFORMED = '{"name": "gamma",'
DECLARATION = json.dumps({
    "name": "gamma", "runtime_id": "retained-runtime",
    "sandbox_profile": "docker", "instructions": "Retain this authored purpose.",
}) + "\n"


def creation_journey(executable, *, wrong_receipt, from_home=False, reconfigured=False, collision=False, workspace_changed=False):
    requests = []
    authored = []
    workspace = {}
    fixtures = h.overview_event_http_fixtures()

    def prepare(base):
        workspace["base"] = base
        home.seed_goals(base)
        if collision:
            Path(base, ".masc", "keepers", "gamma.json").write_text(
                json.dumps(h.keeper_metadata("gamma")), encoding="utf-8")
            return
        for path in (Path(base) / ".masc" / "keepers").glob("*.json"):
            path.unlink()

    def expected_declaration():
        return dict(json.loads(DECLARATION), create_only=True,
                    expected_workspace={"base_path": workspace["base"],
                                        "masc_root": str(Path(workspace["base"], ".masc"))})

    def create(body):
        authored.append(body)
        assert json.loads(body) == expected_declaration()
        if workspace_changed:
            # The probe still describes A; the receiving server now owns B.
            # The real lifecycle precondition is covered in dashboard_http_core.
            return 409, {"error": "workspace changed since identity probe; Keeper was not created"}
        if reconfigured:
            return 200, {"ok": True, "action": "up", "name": "gamma", "detail": {"name": "gamma"}}
        if not wrong_receipt and len(authored) == 1:
            return 400, {"error": "fixture declaration refused"}
        if wrong_receipt:
            return 200, {"ok": True, "action": "up", "name": "another-keeper"}
        # This fixture stands for the server's durable metadata publication;
        # it does not create an actual Keeper process or invoke a provider.
        path = Path(workspace["base"], ".masc", "keepers", "gamma.json")
        path.write_text(json.dumps(h.keeper_metadata("gamma")), encoding="utf-8")
        return 200, {"ok": True, "action": "up", "name": "gamma", "detail": {"name": "gamma", "sandbox_profile": "docker", "network_mode": "none"}}

    fixtures[CREATE_PATH] = h.RequestHttpResponse(create)
    fixtures["/api/v1/keepers/gamma/chat/history"] = (200, [])
    fixtures["/api/v1/keepers/chat/stream"] = h.RequestHttpResponse(
        h.keeper_chat_succeeded_response
    )

    with tempfile.TemporaryDirectory(prefix="masc-create-editor-") as directory:
        editor_root = Path(directory)
        editor = editor_root / "editor.py"
        editor.write_text(
            "from pathlib import Path\nimport sys\n"
            f"root = Path({directory!r})\n"
            "form = Path(sys.argv[1])\n"
            "count = root / 'count'\n"
            "step = int(count.read_text()) + 1 if count.exists() else 1\n"
            "(root / f'input-{step}.json').write_text(form.read_text())\n"
            "count.write_text(str(step))\n"
            f"form.write_text({DECLARATION!r} if {wrong_receipt or reconfigured or collision or workspace_changed!r} or step > 1 else {MALFORMED!r})\n",
            encoding="utf-8",
        )

        def interact(process, fd, _slave, output, _base):
            h.wait_for_output(process, fd, output, b"Health: ", start=0, timeout=10)
            if from_home:
                h.wait_for_output(process, fd, output, b"Create a Keeper", start=0, timeout=10)
                home.select_destination(process, fd, output, b"Create a Keeper")
            else:
                if not collision:
                    h.wait_for_output(process, fd, output, b"Create a Keeper", start=0, timeout=10)
                h.palette_go(process, fd, output, b"go keepers", b"MASC Keepers")
                if collision:
                    h.wait_for_output(process, fd, output, b"gamma", start=0, timeout=10)
            if workspace_changed:
                h.send_and_wait(process, fd, output, b"\r" if from_home else b"a", b"workspace changed since identity probe")
                assert len(authored) == 1, authored
                assert not Path(workspace["base"], ".masc", "keepers", "gamma.json").exists()
                assert not [body for path, body in requests if path == "/api/v1/keepers/chat/stream"]
                os.write(fd, b"a")
                deadline = time.monotonic() + 5
                while len(authored) < 2:
                    h.read_available(fd, output)
                    assert process.poll() is None
                    assert time.monotonic() < deadline, "workspace refusal did not retain retry"
                    time.sleep(0.01)
                assert (editor_root / "input-2.json").read_text() == DECLARATION
                os.write(fd, b"q")
                return
            if reconfigured or collision:
                message = b"Keeper already exists" if collision else b"server reconfigured an existing Keeper"
                h.send_and_wait(process, fd, output, b"\r" if from_home else b"a", message)
                assert len(authored) == (0 if collision else 1), authored
                assert not [body for path, body in requests if path == "/api/v1/keepers/chat/stream"]
                # The second refusal can leave identical screen bytes. Wait
                # for the second authored input and actual POST admission,
                # rather than accepting a delayed repaint of the first error.
                os.write(fd, b"a")
                deadline = time.monotonic() + 5
                second_input = editor_root / "input-2.json"
                while not second_input.exists() or (not collision and len(authored) < 2):
                    h.read_available(fd, output)
                    assert process.poll() is None, "creation retry exited the TUI"
                    assert time.monotonic() < deadline, "creation retry never reopened its authored input"
                    time.sleep(0.01)
                h.drain_until_quiet(process, fd, output)
                assert second_input.read_text() == DECLARATION
                assert len(authored) == (0 if collision else 2), authored
                assert b"Keepers \xe2\x96\xb8 gamma \xe2\x96\xb8 chat" not in h.screen_text(bytes(output))
                os.write(fd, b"q")
                return
            if wrong_receipt:
                h.send_and_wait(process, fd, output, b"a", b"Creation response did not confirm")
                assert process.poll() is None
                assert len(authored) == 1, authored
                assert not [body for path, body in requests if path == "/api/v1/keepers/chat/stream"]
                assert b"Keepers \xe2\x96\xb8 gamma \xe2\x96\xb8 chat" not in h.screen_text(bytes(output))
                os.write(fd, b"q")
                return
            h.send_and_wait(process, fd, output, b"\r" if from_home else b"a", b"Keeper declaration is not JSON")
            assert process.poll() is None
            assert authored == [], authored
            h.send_and_wait(process, fd, output, b"a", b"fixture declaration refused")
            assert (editor_root / "input-2.json").read_text() == MALFORMED
            assert [json.loads(body) for body in authored] == [expected_declaration()], authored
            h.send_and_wait(process, fd, output, b"a", b"declaration accepted")
            assert (editor_root / "input-3.json").read_text() == DECLARATION
            assert [json.loads(body) for body in authored] == [expected_declaration()] * 2, authored
            frame = h.resize_and_wait(
                process, fd, output, rows=24, columns=80,
                needle="Keepers ▸ gamma ▸ chat".encode(),
                controls=(h.FULL_REDRAW,), final_cursor=b"\x1b[?25h",
            )
            print("HOME_JOURNEY_FRAME " + json.dumps({
                "name": "created-keeper-first-request", "rows": 24, "columns": 80,
                "encoding": "base64", "pty": base64.b64encode(frame).decode(),
            }))
            assert not [body for path, body in requests if path == "/api/v1/keepers/chat/stream"]
            h.send_and_wait(process, fd, output, b"first-assignment\r", b"reply-first-assignment")
            sent = [json.loads(body) for path, body in requests if path == "/api/v1/keepers/chat/stream"]
            assert len(sent) == 1, sent
            assert (sent[0]["name"], sent[0]["message"]) == ("gamma", "first-assignment"), sent
            h.send_and_wait(process, fd, output, b"\x1b", b"Continue with gamma" if from_home else b"MASC Keepers")
            os.write(fd, b"q")

        h.run_terminal_scenario(
            executable, description=f"Keeper creation recovery wrong_receipt={wrong_receipt}",
            interact=interact, http_fixtures=fixtures, http_requests=requests,
            prepare_workspace=prepare,
            extra_env={"EDITOR": f"{shlex.quote(sys.executable)} {shlex.quote(str(editor))}"},
        )


def creation_preserves_retained_queue(executable):
    fixture = h.AtomicChatFixture()
    workspace = {}

    def prepare(base):
        workspace["base"] = base

    def create(_body):
        path = Path(workspace["base"], ".masc", "keepers", "gamma.json")
        path.write_text(json.dumps(h.keeper_metadata("gamma")), encoding="utf-8")
        return 200, {"ok": True, "action": "up", "name": "gamma", "detail": {"name": "gamma", "sandbox_profile": "docker", "network_mode": "none"}}

    fixture.fixtures[CREATE_PATH] = h.RequestHttpResponse(create)
    fixture.fixtures["/api/v1/keepers/gamma/chat/history"] = (200, [])
    with tempfile.TemporaryDirectory(prefix="masc-create-queued-editor-") as directory:
        editor = Path(directory, "editor.py")
        editor.write_text(
            "from pathlib import Path\nimport sys\n"
            f"Path(sys.argv[1]).write_text({DECLARATION!r})\n",
            encoding="utf-8",
        )

        def interact(process, fd, _slave, output, _base):
            try:
                h.open_atomic_chat(process, fd, output)
                os.write(fd, b"\x1b")
                assert h.wait_for_fixture_event(process, fd, output, fixture.interrupted, timeout=5)
                h.send_and_wait(process, fd, output, b"keep-this-local", h.composer_showing(b"keep-this-local"))
                h.send_and_wait(process, fd, output, b"\r", "내 메시지 1건 대기".encode())
                h.send_and_wait(process, fd, output, b"\x1b", "중단 뒤 보관 중".encode())
                fixture.release_interrupt.set()
                h.wait_for_output(process, fd, output, b"Interrupt received", start=0, timeout=10)
                h.escape_to_keeper_detail(process, fd, output, name=b"alpha")
                h.send_and_wait(process, fd, output, b"\x1b", b"MASC Keepers")
                h.send_and_wait(process, fd, output, b"a", b"declaration accepted")
                assert fixture.received == [], fixture.received
                # Reading the queue after handoff proves the old request is
                # still retained, rather than merely absent from POST logs.
                # Queues belong to a Keeper: gamma's empty queue cannot
                # attest to the retained request for alpha.
                h.send_and_wait(process, fd, output, b"\x1b", b"MASC Keepers")
                h.select_keeper_row(process, fd, output, b"alpha")
                h.send_and_wait(process, fd, output, b"c", b"Esc:list")
                h.send_and_wait(process, fd, output, b"/queue", h.composer_showing(b"/queue"))
                queued = h.send_and_wait(process, fd, output, b"\r", b"Local unsent messages: 1")
                assert b"keep-this-local" in h.screen_text(queued), queued
                assert fixture.received == [], fixture.received
                h.send_and_wait(process, fd, output, b"\x1b", b"MASC Keepers")
                os.write(fd, b"q")
            finally:
                fixture.release_interrupt.set()
                fixture.release.set()

        h.run_terminal_scenario(
            executable, description="Keeper creation preserves retained queue",
            interact=interact, http_fixtures=fixture.fixtures,
            prepare_workspace=prepare,
            extra_env={"EDITOR": f"{shlex.quote(sys.executable)} {shlex.quote(str(editor))}"},
        )


if __name__ == "__main__":
    executable = os.path.abspath(sys.argv[1])
    creation_journey(executable, wrong_receipt=False)
    creation_journey(executable, wrong_receipt=False, from_home=True)
    creation_journey(executable, wrong_receipt=True)
    creation_journey(executable, wrong_receipt=False, from_home=True, reconfigured=True)
    creation_journey(executable, wrong_receipt=False, collision=True)
    creation_preserves_retained_queue(executable)
    creation_journey(executable, wrong_receipt=False, from_home=True, workspace_changed=True)
    print("Keeper create journey PTY: PASS (7 scenarios)")
