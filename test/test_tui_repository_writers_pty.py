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
    unrelated = deepcopy(beta["changes"][0])
    unrelated["location"] = {"kind": "repo", "repo_id": "other", "path": "OTHER_REPO_LEAK.ml"}
    beta["changes"].append(unrelated)
    beta["calls_in_window"] = 2
    reads = []
    def read_alpha(path):
        reads.append(path)
        return 200, alpha
    def read_beta(path):
        reads.append(path)
        return (503, {"error": "beta record store unavailable"}) if failed else (200, beta)
    fixtures[workspace.FILE_CHANGES_ALPHA_PATH] = h.PathHttpResponse(read_alpha)
    fixtures[workspace.FILE_CHANGES_BETA_PATH] = h.PathHttpResponse(read_beta)

    def interact(process, fd, _slave, output, _base):
        h.tab_until(process, fd, output, b"MASC Workspace")
        h.wait_for_output(process, fd, output, b"/srv/masc/workspace/masc", start=0, timeout=10)
        h.resize_and_wait(process, fd, output, rows=30, columns=columns,
            needle=b"masc", controls=(h.FULL_REDRAW,))
        h.send_and_wait(process, fd, output, b"H", b"alpha-change.ml" if failed else b"beta-change.ml")
        screen = visible(output)
        assert b"OTHER_REPO_LEAK" not in screen, screen
        assert (b"1 recorded changes" if failed else b"2 recorded changes") in screen, screen
        if failed:
            assert b"alpha-change.ml" in screen, screen
            # The coverage sentence folds in the narrow table, including
            # when an Activity pane reserves space at 120 columns.
            h.resize_and_wait(process, fd, output, rows=30, columns=180,
                needle=b"1 Keeper reads failed", controls=(h.FULL_REDRAW,))
            assert b"1 Keeper reads failed" in visible(output), visible(output)
            h.resize_and_wait(process, fd, output, rows=30, columns=columns,
                needle=b"alpha-change.ml", controls=(h.FULL_REDRAW,))
        assert reads.count(workspace.FILE_CHANGES_ALPHA_PATH) == 1, reads
        assert reads.count(workspace.FILE_CHANGES_BETA_PATH) == 1, reads
        if not failed:
            assert b"beta-change.ml" in screen, screen
            # Newest beta row is selected; its context names the real writer.
            h.send_and_wait(process, fd, output, b"v", b"Context [1-")
            detail = visible(output)
            assert b"beta" in detail and b"beta-change.ml" in detail, detail
            h.send_and_wait(process, fd, output, b"\x1b", b"FILE")
            # Unselected paths fold at 60 columns. Select alpha to read its
            # full path in the footer, then inspect the owning writer.
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
