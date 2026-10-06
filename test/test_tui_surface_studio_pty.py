"""Work, Workspace and System responsive panels from the CI fixture PTY."""
import base64
import hashlib
import json
import os
import re
import sys
import tui_keyboard_harness as _keyboard_harness
import tui_keyboard_repositories as _keyboard_repositories



def run(executable, no_color=False):
    fixtures = _keyboard_harness.planning_selection_http_fixtures()
    planning = _keyboard_harness.json_payload_fixture(
        fixtures, _keyboard_harness.PLANNING_PATH)
    planning["task_backlog"] = {"todo": 11, "claimed": 12, "in_progress": 13,
        "awaiting_verification": 14, "done": 15, "cancelled": 16}
    _, repositories = _keyboard_repositories.repositories_fixture()
    repo_rows = repositories["repositories"]
    assert isinstance(repo_rows, list) and isinstance(repo_rows[0], dict)
    repositories["repositories"] = repo_rows
    repo_rows[0]["status"] = "wire\n\x1b[9D"
    repo_rows.append({**repositories["repositories"][0],
        "id":"next-repo", "name":"next-repo", "local_path":"workspace/next-repo",
        "resolved_local_path":"/srv/masc/workspace/next-repo"})
    repo_rows.append({**repositories["repositories"][0],
        "id":"failed-repo", "name":"failed-repo", "status":"error",
        "error_message":"checkout unavailable: refresh credentials",
        "local_path":"workspace/failed-repo",
        "resolved_local_path":"/srv/masc/" + "long-identity-segment/" * 16 + "failed-repo"})
    repositories["total"] = 3
    page_names = [f"page-{index:02d}" for index in range(25)]
    for name in page_names:
        repo_rows.append({**repositories["repositories"][0],
            "id": name, "name": name, "local_path": "workspace/" + name,
            "resolved_local_path": "/srv/masc/workspace/" + name})
    repositories["total"] = len(repo_rows)
    refresh_failed = False
    refresh_error = ("Workspace repository refresh unavailable while reading the registered checkout "
        "and its remote identity; the previous repositories remain available for selection. "
        "Recover using surface-refresh-recovery-token")
    def read_repositories():
        return (503, {"error": refresh_error}) if refresh_failed else (200, repositories)
    fixtures[_keyboard_repositories.REPOSITORIES_PATH] = read_repositories
    fixtures["/api/v1/runtime/params"] = (200, {"parameters": [
        {"key": "studio.enabled", "current": True, "default": False,
         "has_override": True, "meta": {"description": "Enable the observed feature",
         "value_type": "bool"}},
        {"key": "studio.mode", "current": "user_only:" + "fixture-identity-" * 4,
         "default": "mention_or_thread", "has_override": True,
         "meta": {"description": "Presentation mode",
         "value_type": "string"}}], "surfaces": []})
    def interact(process, fd, _slave, output, _base):
        nonlocal refresh_failed
        def key(value, needle):
            return _keyboard_harness.send_and_wait(process, fd, output, value, needle)
        def capture(name, rows, columns, needle, selected_name=None, *, raw=False):
            _keyboard_harness.resize_and_wait(process, fd, output, rows=rows, columns=columns+1,
                needle=needle, controls=(_keyboard_harness.FULL_REDRAW,), final_cursor=b"\x1b[?25l")
            frame = _keyboard_harness.resize_and_wait(process, fd, output, rows=rows, columns=columns,
                needle=needle, controls=(_keyboard_harness.FULL_REDRAW,), final_cursor=b"\x1b[?25l")
            if b"wire\n" in frame or b"\x1b[9D" in frame:
                raise AssertionError("repository status injected a newline or terminal cursor control")
            if selected_name is not None and not _keyboard_harness.keeper_row_selected(selected_name).search(frame):
                raise AssertionError(f"selected repository {selected_name!r} vanished from its table")
            print("STUDIO_CAPTURE="+json.dumps({"suite":"test_tui_surface_studio_pty", "name":name+("-no-color" if no_color else ""),
                "rows":rows,"columns":columns,"provenance":"CI fixture PTY",
                "frame_b64":base64.b64encode(frame).decode(),
                "screen":b"\n".join(_keyboard_harness.screen_rows(frame).get(row, b"") for row in range(1, rows + 1)).decode(errors="replace")}),flush=True)
            return frame if raw else _keyboard_harness.screen_text(frame)
        _keyboard_harness.wait_for_output(process,fd,output,b"Health: ",start=0,timeout=10)
        key(b":go Work\r",b"plan-alpha-29424")
        wide=capture("work-wide",36,160,b"Goals")
        for needle in ("Goals · measured outcomes".encode(),"Tasks · Backlog:".encode(),
                b"done=15", b"cancelled=16"):
            if needle not in wide:
                raise AssertionError(f"Work omitted {needle!r}")
        medium=capture("work-medium",24,120,b"plan-alpha-29424")
        for needle in (b"Backlog:", b"done=15", b"cancelled=16"):
            if needle not in medium:
                raise AssertionError(f"Work omitted {needle!r} at 120 columns")
        narrow=capture("work-narrow",24,80,b"plan-alpha-29424")
        for needle in (b"Goals:", b"Backlog:", b"done=15", b"cancelled=16"):
            if needle not in narrow:
                raise AssertionError(f"Narrow Work omitted {needle!r}")
        for heading in ("Goals · measured outcomes".encode(), "Tasks · Backlog:".encode()):
            if heading in narrow:
                raise AssertionError("Narrow Work retained wide summary cards")
        key(b":go Workspace\r",b"/srv/masc/workspace/masc")
        for name,rows,cols in (("workspace-wide",32,160),("workspace-narrow",24,80)):
            screen=capture(name,rows,cols,b"Keepers: alpha")
            for needle in (b"Path:",b"Stored as: workspace/masc",b"Keepers: alpha"):
                if needle not in screen:
                    raise AssertionError(f"Workspace omitted {needle!r}")
        key(b"j", b"next-repo")
        selected = capture("workspace-short-selected",16,80,b"/srv/masc/workspace/next-repo", b"next-repo")
        if b"next-repo" not in selected:
            raise AssertionError("selected repository disappeared in short viewport")
        key(b"j", b"checkout unavailable")
        failed = capture("workspace-failed-short",16,80,b"checkout unavailable", b"failed-repo")
        if b"Error: checkout unavailable" not in failed:
            raise AssertionError("long selected context hid the actual failure reason")
        key(b"\x1b[H", b"/srv/masc/workspace/masc")
        before=capture("workspace-page-start",24,80,b"/srv/masc/workspace/masc",b"masc")
        names=[b"masc",b"next-repo",b"failed-repo"]+[name.encode() for name in page_names]
        visible=sum(name in before for name in names)
        key(b"\x1b[6~",b"page-")
        paged=capture("workspace-page-next",24,80,b"page-",raw=True)
        selected=[index for index,name in enumerate(names)
            if re.search(rb"\x1b\[7m *"+re.escape(name)+rb"(?= )",paged)]
        if len(selected)!=1 or not 0<selected[0]<=visible:
            raise AssertionError(f"Workspace page skipped undisplayed repositories: {selected}, visible={visible}")
        # A failed surface refresh retains the table. Its diagnostic belongs
        # to that table's interior, even in the wide split layout.
        key(b"\x1b[H", b"/srv/masc/workspace/masc")
        capture("workspace-before-failed-refresh",32,160,b"Keepers: alpha",b"masc")
        refresh_failed = True
        key(b"r", b"surface-refresh-recovery-token")
        failed_refresh = capture("workspace-surface-error-wide",32,160,
            b"surface-refresh-recovery-token",b"masc")
        if b"surface-refresh-recovery-token" not in failed_refresh:
            raise AssertionError("Workspace clipped the surface refresh recovery suffix")
        visible = sum(name in failed_refresh for name in names)
        key(b"\x1b[6~",b"page-")
        paged_error = capture("workspace-surface-error-page",32,160,
            b"surface-refresh-recovery-token",raw=True)
        selected = [index for index,name in enumerate(names)
            if re.search(rb"\x1b\[7m *"+re.escape(name)+rb"(?= )",paged_error)]
        if len(selected)!=1 or not 0<selected[0]<=visible:
            raise AssertionError("Workspace error rows made PageDown skip undisplayed repositories")
        key(b":settings\r",b"studio.enabled")
        wide=capture("system-wide",32,160,b"Selected setting")
        for needle in (b"Current", b"true", b"Default", b"false"):
            if needle not in wide:
                raise AssertionError(f"System omitted {needle!r}")

        def read_selected(expected):
            # The same selected document becomes pageable in a short terminal.
            # Check reachability through its advertised extent, then restore it.
            seen = set()
            while True:
                screen = _keyboard_harness.screen_text(bytes(output))
                joined = re.sub(rb"\s+", b"", screen.replace("│".encode(), b""))
                seen.update(value for value in expected if value in joined)
                position = re.search(rb"\b(\d+)-(\d+)/(\d+)\b", screen)
                if position is None:
                    raise AssertionError("System omitted selected document position")
                first, last, total = map(int, position.groups())
                if last >= total:
                    break
                _keyboard_harness.press_and_settle(process, fd, output, b"\x1b[6~")
                next_position = re.search(rb"\b(\d+)-(\d+)/(\d+)\b",
                    _keyboard_harness.screen_text(bytes(output)))
                if next_position is None or int(next_position.group(1)) <= first:
                    raise AssertionError("System selected document stopped before its end")
            if seen != set(expected):
                raise AssertionError(f"System omitted selected content {set(expected) - seen!r}")
            _keyboard_harness.write_all(fd, output, b"\x1b[H")
            _keyboard_harness.drain_until_quiet(process, fd, output)

        read_selected((b"Currenttrue", b"Defaultfalse", b"Enabletheobservedfeature", b"override"))
        capture("system-short",16,80,b"studio.enabled")
        read_selected((b"Currenttrue", b"Defaultfalse", b"Enabletheobservedfeature", b"override"))
        key(b"\r",b"editing studio.enabled")
        key(b"\x1b",b"studio.enabled")
        key(b"j",b"studio.mode")
        capture("system-long-comparison",30,80,b"studio.mode")
        params = _keyboard_harness.json_payload_fixture(
            fixtures, "/api/v1/runtime/params")["parameters"]
        assert isinstance(params, list) and isinstance(params[1], dict)
        current = params[1]["current"]
        read_selected((b"Current" + json.dumps(current).encode(),
                       b'Default"mention_or_thread"', b"override"))
        key(b":go Dashboard\r",b"MASC Dashboard")
        os.write(fd,b"q")
    _keyboard_harness.run_terminal_scenario(executable,description="surface studio"+(" no color" if no_color else ""),
        interact=interact,http_fixtures=fixtures,workspace="Surface fixture",
        extra_env={"NO_COLOR":"1"} if no_color else None)

if __name__ == "__main__":
    executable=os.path.abspath(sys.argv[1])
    with open(executable,"rb") as binary:
        print("STUDIO_BINARY_SHA256="+hashlib.sha256(binary.read()).hexdigest(),flush=True)
    run(executable)
    run(executable,True)
    print("tui surface studio PTY: PASS",flush=True)
