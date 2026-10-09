"""Repository activity includes unassigned writers and excludes other addresses."""
import os
import sys
from copy import deepcopy

import tui_keyboard_harness as h
import tui_keyboard_repositories as repositories
import tui_keyboard_workspace as workspace


def visible(output):
    end = output.rfind(h.FRAME_END)
    assert end >= 0, "No completed redraw"
    return h.screen_text(bytes(output[:end + len(h.FRAME_END)]))


def run(executable, columns, failed):
    fixtures = h.keeper_runtime_http_fixtures()
    fixtures[repositories.REPOSITORIES_PATH] = repositories.repositories_fixture()
    _, alpha = workspace.file_changes_alpha_response()
    alpha["changes"] = alpha["changes"][:1]
    alpha["changes"][0]["location"]["path"] = "alpha-change.ml"
    alpha["calls_in_window"] = 1
    beta = deepcopy(alpha)
    beta["keeper"] = "beta"
    beta["changes"][0].update(keeper="beta", at=1787600100)
    beta["changes"][0]["location"]["path"] = "beta-change.ml"
    reads = []
    route = "/api/v1/ide/repository-activity?repo_id=masc&window_hours=24"
    def read_activity(path):
        reads.append(path)
        if failed and len(reads) > 1:
            return 503, {"error": "repository record store unavailable"}
        return 200, {"ok": True, "data": {
            "repo_id": "masc", "window_hours": 24.0,
            "changes": alpha["changes"] + beta["changes"],
            "incomplete": 0, "unattributed": 0}}
    fixtures[route] = h.PathHttpResponse(read_activity)
    # Per-Keeper fanout is no longer an allowed read path for this surface.
    fixtures[workspace.FILE_CHANGES_ALPHA_PATH] = (500, {"error": "unexpected keeper scan"})
    fixtures[workspace.FILE_CHANGES_BETA_PATH] = (500, {"error": "unexpected keeper scan"})

    def interact(process, fd, _slave, output, _base):
        h.tab_until(process, fd, output, b"MASC Workspace")
        h.wait_for_output(process, fd, output, b"/srv/masc/workspace/masc", start=0, timeout=10)
        h.resize_and_wait(process, fd, output, rows=30, columns=columns,
            needle=b"masc", controls=(h.FULL_REDRAW,))
        h.send_and_wait(process, fd, output, b"H", b"beta-change.ml")
        screen = visible(output)
        assert b"2 recorded changes" in screen, screen
        assert reads == [route], reads
        if failed:
            h.send_and_wait(process, fd, output, b"r", b"repository record store unavailable")
            assert b"beta-change.ml" in visible(output), visible(output)
            assert reads == [route, route], reads
        h.send_and_wait(process, fd, output, b"v", b"Context [1-")
        detail = visible(output)
        assert b"beta" in detail and b"beta-change.ml" in detail, detail
        h.send_and_wait(process, fd, output, b"\x1b", b"FILE")
        h.send_and_wait(process, fd, output, b"j", b"alpha-change.ml")
        h.send_and_wait(process, fd, output, b"v", b"Context [1-")
        detail = visible(output)
        assert b"alpha" in detail and b"alpha-change.ml" in detail, detail
        os.write(fd, b"q")

    h.run_terminal_scenario(executable,
        description=f"Repository unassigned writer {columns} failed={failed}",
        interact=interact, http_fixtures=fixtures)


if __name__ == "__main__":
    for width in (60, 120):
        for unreadable in (False, True):
            run(os.path.abspath(sys.argv[1]), width, unreadable)
    print("Repository writer coverage: PASS")
