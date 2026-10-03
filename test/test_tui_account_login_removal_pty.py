"""/login removes an account: D previews, Enter removes, a moved file is shown again.

D on the second account asks the server what removing it changes. The first
Enter meets a server that answers 409 -- runtime.toml moved since the preview
-- so the pane reads the preview again and shows why; nothing is removed
until the operator presses Enter over what the file says now. The second
Enter carries that new revision, the list is read again without the account,
and the notice names the login store left on disk.
"""
from __future__ import annotations

import json
import os
import sys

import test_tui_keyboard_input as h
from test_tui_account_login_pty import leave_login_and_arm_quit



PREVIEW = "/api/v1/setup/accounts/removal"
REMOVE = "/api/v1/setup/accounts/remove"
MOVED = "runtime.toml changed since the removal was shown; show it again before removing."


def run(binary: str) -> None:
    requests: list[tuple[str, bytes]] = []
    previews: list[dict] = []
    removals: list[dict] = []
    fixtures = h.keeper_runtime_http_fixtures()
    fixtures["/api/v1/keepers/alpha/chat/history"] = (200, [])

    def inventory():
        integrations = [{"id": "codex", "display_name": "codex", "protocol": "codex-app-server",
                         "origin": "masc_integration"}]
        if len(removals) < 2:
            integrations.append({"id": "codex_two", "display_name": "codex_two", "protocol": "codex-app-server",
                                 "origin": "runtime_config"})
        return 200, {"setup_revision": "fixture-revision", "default_runtime_selection": [],
                     "runtimes": [], "account_emails": [], "integrations": integrations}

    fixtures["/api/v1/setup/inventory"] = inventory

    def preview(body: bytes):
        previews.append(json.loads(body))
        # The second read is the file after someone else wrote to it.
        revision = "rev-%d" % len(previews)
        changes = [{"kind": "table", "path": "providers.codex_two"},
                   {"kind": "assignment", "keeper": "sangsu", "runtime": "codex_two.gpt-5.6"}]
        if len(previews) > 1:
            changes.append({"kind": "assignment", "keeper": "later", "runtime": "codex_two.gpt-5.6"})
        return 200, {"integration_id": "codex_two", "revision": revision, "state": "removable",
                     "changes": changes, "login_store": "/tmp/codex-two"}

    def remove(body: bytes):
        removals.append(json.loads(body))
        if len(removals) == 1:
            return 409, {"error": MOVED}
        return 200, {"ok": True, "state": "committed"}

    fixtures[PREVIEW] = h.RequestHttpResponse(preview)
    fixtures[REMOVE] = h.RequestHttpResponse(remove)

    def interact(process, fd, _slave, output, _base_path):
        h.send_and_wait(process, fd, output, b"3", b"MASC Keepers")
        h.select_keeper_row(process, fd, output, b"alpha")
        h.send_and_wait(process, fd, output, b"c", "Keepers ▸ alpha ▸ chat".encode())
        h.send_and_wait(process, fd, output, b"/login\r", b"MASC Account Login")
        h.wait_for_output(process, fd, output, "> Codex · 계정 1".encode(), start=0, timeout=3.0)

        # Codex's accounts: the new-account row, then the account, then what
        # removing it changes.
        h.send_and_wait(process, fd, output, b"\r", "> + 새 계정".encode())
        h.send_and_wait(process, fd, output, b"j", b"> codex_two")
        h.send_and_wait(process, fd, output, b"D", b"keeper sangsu")
        if previews != [{"integration_id": "codex_two"}]:
            raise AssertionError(f"the preview asked about another account: {previews!r}")

        # The file moved: shown again with why, and nothing removed yet.
        h.send_and_wait(process, fd, output, b"\r", b"keeper later")
        if b"runtime.toml changed since the removal was shown" not in h.screen_text(bytes(output)):
            raise AssertionError("the refusal was not shown over the new preview")
        if removals != [{"integration_id": "codex_two", "revision": "rev-1"}]:
            raise AssertionError(f"the first removal carried the wrong body: {removals!r}")

        # Enter over what the file says now removes it.
        h.send_and_wait(process, fd, output, b"\r", "codex_two 계정을 지웠습니다".encode())
        if removals[1:] != [{"integration_id": "codex_two", "revision": "rev-2"}]:
            raise AssertionError(f"the second removal did not carry the new revision: {removals!r}")
        screen = h.screen_text(bytes(output))
        if b"/tmp/codex-two" not in screen:
            raise AssertionError(f"the login store left on disk is not named: {screen!r}")
        if b"> codex_two" in screen:
            raise AssertionError(f"the removed account is still listed: {screen!r}")
        # The list is on Codex's accounts; Esc goes back to the clients first.
        h.send_and_wait(process, fd, output, b"\x1b", "Enter:계정 보기".encode())
        leave_login_and_arm_quit(process, fd, output)

    h.run_terminal_scenario(
        binary,
        description="/login removes an account only over the preview the file still matches",
        interact=interact,
        http_fixtures=fixtures,
        http_requests=requests,
    )


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("login account removal: PASS")
