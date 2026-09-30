from __future__ import annotations

import json
import os
import subprocess
import tempfile
from collections.abc import Iterator
from contextlib import contextmanager

from tui_keyboard_harness import (
    CSI_RE,
    FRAME_END,
    FULL_REDRAW,
    HttpRequests,
    Interaction,
    frame_containing,
    keeper_runtime_http_fixtures,
    palette_go,
    resize_and_wait,
    run_terminal_scenario,
    send_and_wait,
    tab_until,
    wait_for_http_request,
    wait_for_output,
)
from tui_keyboard_workspace import (
    code_lane_fixtures,
)

REPOSITORIES_PATH = "/api/v1/repositories"


def repositories_fixture() -> tuple[int, dict[str, object]]:
    return (
        200,
        {
            "repositories": [
                {"id": "masc", "name": "masc",
                 "codebase": "github.com_jeong-sik_masc",
                 "url": "git@github.com:jeong-sik/masc.git",
                 "local_path": "workspace/masc",
                 "resolved_local_path": "/srv/masc/workspace/masc",
                 "default_branch": "main",
                 "status": "ready", "keepers": ["alpha"], "auto_sync": True},
            ],
            "total": 1,
        },
    )


@contextmanager
def repository_declaration_editor_script() -> Iterator[str]:
    """An $EDITOR that fills the repository declaration form and exits 0."""
    fd, path = tempfile.mkstemp(prefix="masc-tui-repo-editor-", suffix=".sh")
    try:
        os.write(
            fd,
            b'#!/bin/sh\nprintf %s \'{"name": "kirin", '
            b'"url": "git@github.com:jeong-sik/kirin.git", '
            b'"default_branch": "main", "auto_sync": false, '
            b'"sync_interval": 300}\' > "$1"\n',
        )
        os.close(fd)
        os.chmod(path, 0o755)
        yield path
    finally:
        os.unlink(path)


def repository_add_interaction(requests: HttpRequests) -> Interaction:
    """Pressing a on Repositories registers a repository, and the surface the
    key was pressed on says what happened.

    Every outcome of this action -- the registration, a refused declaration,
    an editor that never started -- went only to the session log, which
    another surface draws. So the operator who pressed the key stood on a
    surface that could not answer them, and a repository that was registered
    looked exactly like nothing at all."""

    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        tab_until(process, master_fd, output, b"MASC Workspace")
        wait_for_output(
            process, master_fd, output, b"ready", start=0, timeout=3.0
        )
        os.write(master_fd, b"a")
        body = wait_for_http_request(
            process, master_fd, output, requests, path=REPOSITORIES_PATH
        )
        payload = json.loads(body)
        if payload.get("name") != "kirin":
            raise AssertionError(f"repository POST body: {payload!r}")
        # The footer, not the event log: this is the surface the key was
        # pressed on, and it is the one that has to answer.
        wait_for_output(
            process,
            master_fd,
            output,
            b"kirin: repository added",
            start=0,
            timeout=5.0,
        )
        os.write(master_fd, b"q")

    return interact


def repositories_path_interaction(
    process: subprocess.Popen[bytes],
    master_fd: int,
    _slave_fd: int,
    output: bytearray,
    _base_path: str,
) -> None:
    """Show paths, inspect Git changes, then enter the repository."""
    tab_until(process, master_fd, output, b"MASC Workspace")
    narrow = resize_and_wait(
        process,
        master_fd,
        output,
        rows=18,
        columns=80,
        needle=b"/srv/masc/workspace/masc",
        controls=(FULL_REDRAW,),
        final_cursor=b"\x1b[?25l",
    )
    wide = resize_and_wait(
        process,
        master_fd,
        output,
        rows=30,
        columns=140,
        needle=b"/srv/masc/workspace/masc",
        controls=(FULL_REDRAW,),
        final_cursor=b"\x1b[?25l",
    )
    for width, frame in ((80, narrow), (140, wide)):
        plain = CSI_RE.sub(b"", frame).decode("utf-8")
        for needle in ("Path", "Stored as: workspace/masc", "Keepers: alpha"):
            if needle not in plain:
                raise AssertionError(
                    f"{width}-column Repositories omitted {needle!r}: {plain!r}"
                )
    changes_wide = send_and_wait(
        process, master_fd, output, b"d", b"lib/changed file.ml"
    )
    changes_narrow = resize_and_wait(
        process,
        master_fd,
        output,
        rows=18,
        columns=80,
        needle=b"lib/changed file.ml",
        controls=(FULL_REDRAW,),
        final_cursor=b"\x1b[?25l",
    )
    for width, frame in ((80, changes_narrow), (140, changes_wide)):
        changes_plain = CSI_RE.sub(b"", frame).decode("utf-8")
        for needle in (
            "MASC Git Changes",
            "staged+worktree",
            "lib/changed file.ml",
            "untracked",
            "새 파일.txt",
        ):
            if needle not in changes_plain:
                raise AssertionError(
                    f"{width}-column Repository Git changes omitted "
                    f"{needle!r}: {changes_plain!r}"
                )
    resize_and_wait(
        process,
        master_fd,
        output,
        rows=30,
        columns=140,
        needle=b"lib/changed file.ml",
        controls=(FULL_REDRAW,),
        final_cursor=b"\x1b[?25l",
    )
    send_and_wait(process, master_fd, output, b"\x1b", b"MASC Workspace")
    code = send_and_wait(process, master_fd, output, b"\r", b"src")
    code_plain = CSI_RE.sub(b"", code).decode("utf-8")
    if "masc ▸ /" not in code_plain:
        raise AssertionError(
            f"the Code header does not name the repository: {code_plain!r}"
        )
    os.write(master_fd, b"q")


def project_changes_interaction(
    process: subprocess.Popen[bytes],
    master_fd: int,
    _slave_fd: int,
    output: bytearray,
    _base_path: str,
) -> None:
    """List an unregistered project's Git changes from Code, return to the
    tree, leave for Workspace with Esc at the root and walk back in, then
    reopen the list and enter the selected file."""
    palette_go(process, master_fd, output, b"go code", b"README.md")
    changes_wide = send_and_wait(process, master_fd, output, b"d", b"lib/a.ml")
    changes_narrow = resize_and_wait(
        process,
        master_fd,
        output,
        rows=18,
        columns=80,
        needle=b"lib/a.ml",
        controls=(FULL_REDRAW,),
        final_cursor=b"\x1b[?25l",
    )
    for width, frame in ((80, changes_narrow), (140, changes_wide)):
        plain = CSI_RE.sub(b"", frame).decode("utf-8")
        for needle in (
            "MASC Git Changes",
            "Project workspace",
            "worktree",
            "lib/a.ml",
            "untracked",
            "새 파일.txt",
        ):
            if needle not in plain:
                raise AssertionError(
                    f"{width}-column project Git changes omitted "
                    f"{needle!r}: {plain!r}"
                )
    tree = send_and_wait(process, master_fd, output, b"\x1b", b"README.md")
    if "MASC Git Changes" in CSI_RE.sub(b"", tree).decode("utf-8"):
        raise AssertionError("Esc did not return from project changes to Code")
    # With nothing open and the project root under foot, Esc leaves for
    # Workspace, the ring parent; the palette walks back in for the rest.
    send_and_wait(process, master_fd, output, b"\x1b", b"MASC Workspace")
    palette_go(process, master_fd, output, b"go code", b"README.md")
    send_and_wait(process, master_fd, output, b"d", b"lib/a.ml")
    # The diff view's header now reads "MASC Git Diff lib/a.ml vs HEAD
    # [connected]" -- no "[j/k]" scroll hint survives in this frame (that
    # was the Git Changes list's own footer hint, from before this Enter).
    # "MASC Git Diff" and " lib/a.ml" sit either side of an SGR reset
    # (bold-off after the title), so the needle must stay inside the one
    # plain run that follows it. The header paints instantly but the diff
    # body ("(reading the tree)" -> the actual lines) loads afterward, so
    # send_and_wait's single returned frame is the loading placeholder --
    # wait for the body separately and grab the frame that contains it.
    diff_start = len(output)
    os.write(master_fd, b"\r")
    wait_for_output(
        process, master_fd, output, b"lib/a.ml  vs HEAD", start=diff_start, timeout=3.0
    )
    wait_for_output(
        process, master_fd, output, b"let x = 1", start=diff_start, timeout=5.0
    )
    loaded_end = output.find(b"let x = 1", diff_start) + len(b"let x = 1")
    wait_for_output(
        process, master_fd, output, FRAME_END, start=loaded_end, timeout=3.0
    )
    frame_end = output.find(FRAME_END, loaded_end) + len(FRAME_END)
    opened = frame_containing(bytes(output[diff_start:frame_end]), b"let x = 1")
    opened_plain = CSI_RE.sub(b"", opened).decode("utf-8")
    if "let x = 1" not in opened_plain:
        raise AssertionError(
            f"Enter opened the file without its highlighted content: {opened_plain!r}"
        )
    if "Project workspace" in opened_plain:
        raise AssertionError(
            "Enter left the project changes overlay open instead of opening code"
        )
    os.write(master_fd, b"q")


def repositories_enter_interaction() -> Interaction:
    """Enter on a Repositories row opens that repository's own tree on the
    Code surface, through the ?repo_id= axis; the header names whose tree
    it is. Then m lists the memos the file carries as comments, read off
    the lexed rows rather than fetched."""

    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        tab_until(process, master_fd, output, b"MASC Workspace")
        wait_for_output(
            process, master_fd, output, b"ready", start=0, timeout=3.0
        )
        code = send_and_wait(process, master_fd, output, b"\r", b"src")
        code_plain = CSI_RE.sub(b"", code).decode("utf-8")
        if "masc ▸ /" not in code_plain:
            raise AssertionError(
                f"the Code header does not name the repository: {code_plain!r}"
            )
        # Open a file in the repository scope, then m: the memo is the
        # comment on line 1, in the file's own syntax, so the list needs no
        # request and names the line, the author, the kind and the text.
        send_and_wait(process, master_fd, output, b"j\r", b"let")
        notes = send_and_wait(
            process, master_fd, output, b"m", b"keep n at three"
        )
        notes_plain = CSI_RE.sub(b"", notes).decode("utf-8")
        for needle in ("notes: note.ml", "L1", "alpha", "(decision)"):
            if needle not in notes_plain:
                raise AssertionError(
                    f"the notes view missed {needle!r}: {notes_plain!r}"
                )
        back = send_and_wait(process, master_fd, output, b"\x1b", b"let")
        # The memo decorates the gutter: line 1 carries the anchor mark.
        if "●".encode() not in back:
            raise AssertionError(
                f"the memo mark is missing from the gutter: {back!r}"
            )
        # H over the repo-scoped file: the commits that touched it,
        # newest first.
        history = send_and_wait(process, master_fd, output, b"H", b"abc1234")
        history_plain = CSI_RE.sub(b"", history).decode("utf-8")
        for needle in ("history: note.ml", "seed the file"):
            if needle not in history_plain:
                raise AssertionError(
                    f"the history missed {needle!r}: {history_plain!r}"
                )
        # Enter on the top row (the newest commit): its subject's (#N) plus
        # the registered remote become the PR link.
        send_and_wait(
            process, master_fd, output, b"\r",
            b"github.com/jeong-sik/masc/pull/1256",
        )
        os.write(master_fd, b"q")

    return interact


def run_repositories_regression(executable: str) -> None:
    fixtures = keeper_runtime_http_fixtures()
    fixtures[REPOSITORIES_PATH] = repositories_fixture()
    fixtures["/api/v1/repositories/masc/changes"] = (
        200,
        {
            "scope": {"kind": "repository", "repository_id": "masc"},
            "changes": [
                {"path": "lib/changed file.ml", "staged": True,
                 "unstaged": True, "untracked": False, "conflicted": False},
                {"path": "새 파일.txt", "staged": False,
                 "unstaged": False, "untracked": True, "conflicted": False},
            ],
            "total": 2,
        },
    )
    fixtures["/api/v1/workspace/children?path=&limit=2000&repo_id=masc"] = (
        200,
        [
            {"path": "src", "label": "src", "depth": 0, "parent": "",
             "hasChildren": True, "diff": None, "keeperId": None,
             "hueIndex": None},
        ],
    )
    run_terminal_scenario(
        executable,
        description="Repositories show paths, Git changes, and the Code tree",
        interact=repositories_path_interaction,
        http_fixtures=fixtures,
    )
    # The two scenarios below opened a repository's own tree and declared a
    # new repository from the default group, where a failure earlier in the
    # run kept them from running at all. They are repository scenarios, so
    # they run under the repositories alias with the one above.
    repositories_fixtures = keeper_runtime_http_fixtures()
    repositories_fixtures[REPOSITORIES_PATH] = repositories_fixture()
    repositories_fixtures["/api/v1/workspace/children?path=&limit=2000&repo_id=masc"] = (
        200,
        [
            {"path": "src", "label": "src", "depth": 0, "parent": "",
             "hasChildren": True, "diff": None, "keeperId": None,
             "hueIndex": None},
            {"path": "note.ml", "label": "note.ml", "depth": 0, "parent": "",
             "hasChildren": False, "diff": None, "keeperId": None,
             "hueIndex": None},
        ],
    )
    repo_file = (
        200,
        {
            "ok": True,
            "content": (
                "(* masc(alpha) decision: keep n at three until the probe lands *)\n"
                "let n = 3\n"
            ),
        },
    )
    for file_path in (
        "/api/v1/workspace/file?path=note.ml&repo_id=masc",
    ):
        repositories_fixtures[file_path] = repo_file
    repositories_fixtures[
        "/api/v1/git/log?path=note.ml&limit=50&repo_id=masc"
    ] = (
        200,
        {"ok": True, "commits": [
            {"hash": "abc1234", "timestamp_ms": 1787650000000,
             "author": "keeper", "subject": "docs: seed the file (#1256)"},
        ]},
    )
    run_terminal_scenario(
        executable,
        description="Repositories Enter opens the Code tree",
        interact=repositories_enter_interaction(),
        http_fixtures=repositories_fixtures,
    )
    add_requests: HttpRequests = []
    with repository_declaration_editor_script() as repo_editor:
        run_terminal_scenario(
            executable,
            description="Repositories add says what it did",
            interact=repository_add_interaction(add_requests),
            http_fixtures=repositories_fixtures,
            http_requests=add_requests,
            extra_env={"EDITOR": repo_editor},
        )


def run_project_changes_regression(executable: str) -> None:
    fixtures = code_lane_fixtures()
    fixtures["/api/v1/git/status"] = (
        200,
        {
            "scope": {"kind": "project"},
            "changes": [
                {"path": "lib/a.ml", "staged": False,
                 "unstaged": True, "untracked": False,
                 "conflicted": False},
                {"path": "새 파일.txt", "staged": False,
                 "unstaged": False, "untracked": True,
                 "conflicted": False},
            ],
            "total": 2,
        },
    )
    run_terminal_scenario(
        executable,
        description="Code lists current project Git changes and opens a file",
        interact=project_changes_interaction,
        http_fixtures=fixtures,
    )
