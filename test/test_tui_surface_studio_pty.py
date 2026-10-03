"""Work, Workspace and System responsive panels from the CI fixture PTY."""
import base64
import copy
import hashlib
import json
import os
import re
import sys
import test_tui_keyboard_input as h



def run(executable, no_color=False):
    fixtures = h.planning_selection_http_fixtures()
    planning_response = fixtures[h.PLANNING_PATH]
    assert isinstance(planning_response, tuple)
    planning = planning_response[1]
    assert isinstance(planning, dict)
    planning["task_backlog"] = {"todo": 11, "claimed": 12, "in_progress": 13,
        "awaiting_verification": 14, "done": 15, "cancelled": 16}
    _, repositories = h.repositories_fixture()
    repository_rows = repositories["repositories"]
    assert isinstance(repository_rows, list)
    repository_rows[0]["status"] = "wire\n\x1b[9D"
    repository_rows.append({**repository_rows[0],
        "id":"next-repo", "name":"next-repo", "local_path":"workspace/next-repo",
        "resolved_local_path":"/srv/masc/workspace/next-repo"})
    repository_rows.append({**repository_rows[0],
        "id":"failed-repo", "name":"failed-repo", "status":"error",
        "error_message":"checkout unavailable: refresh credentials",
        "local_path":"workspace/failed-repo",
        "resolved_local_path":"/srv/masc/" + "long-identity-segment/" * 16 + "failed-repo"})
    repositories["total"] = 3
    page_names = [f"page-{index:02d}" for index in range(25)]
    for name in page_names:
        repository_rows.append({**repository_rows[0],
            "id": name, "name": name, "local_path": "workspace/" + name,
            "resolved_local_path": "/srv/masc/workspace/" + name})
    repositories["total"] = len(repository_rows)
    refresh_failed = False
    refresh_error = ("Workspace repository refresh unavailable while reading the registered checkout "
        "and its remote identity; the previous repositories remain available for selection. "
        "Recover using surface-refresh-recovery-token")
    def read_repositories():
        return (503, {"error": refresh_error}) if refresh_failed else (200, repositories)
    fixtures[h.REPOSITORIES_PATH] = read_repositories
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
            return h.send_and_wait(process, fd, output, value, needle)
        def capture(name, rows, columns, needle, selected_name=None, *, raw=False):
            h.resize_and_wait(process, fd, output, rows=rows, columns=columns+1,
                needle=needle, controls=(h.FULL_REDRAW,), final_cursor=b"\x1b[?25l")
            frame = h.resize_and_wait(process, fd, output, rows=rows, columns=columns,
                needle=needle, controls=(h.FULL_REDRAW,), final_cursor=b"\x1b[?25l")
            if b"wire\n" in frame or b"\x1b[9D" in frame:
                raise AssertionError("repository status injected a newline or terminal cursor control")
            if selected_name is not None and not h.keeper_row_selected(selected_name).search(frame):
                raise AssertionError(f"selected repository {selected_name!r} vanished from its table")
            print("STUDIO_CAPTURE="+json.dumps({"suite":"test_tui_surface_studio_pty", "name":name+("-no-color" if no_color else ""),
                "rows":rows,"columns":columns,"provenance":"CI fixture PTY",
                "frame_b64":base64.b64encode(frame).decode(),
                "screen":b"\n".join(h.screen_rows(frame).get(row, b"") for row in range(1, rows + 1)).decode(errors="replace")}),flush=True)
            return frame if raw else h.screen_text(frame)
        h.wait_for_output(process,fd,output,b"Health: ",start=0,timeout=10)
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
        joined = h.unwrapped(narrow)
        snapshot_time = planning["generated_at"]
        assert isinstance(snapshot_time, str)
        for label in (b"Baseline snapshot: ", b"Current snapshot: "):
            if label + snapshot_time.encode() not in joined:
                raise AssertionError(f"Work source time missing: {label!r}")
        if b"this TUI's first reading" in joined:
            raise AssertionError("server snapshot time was labeled as process age")
        for needle in (b"Goals done +0", b"Tasks done +0", b"Goal reviews pending +0"):
            if needle not in joined:
                raise AssertionError(f"Narrow Work omitted baseline change {needle!r}")
        key(b"j", b"plan-beta-29424")
        selected = h.screen_text(bytes(output))
        if b"goal-b-29424" not in selected:
            raise AssertionError("wrapped summaries obscured selected goal details")
        key(b"k", b"plan-alpha-29424")
        narrower = capture("work-narrow-60", 24, 60, b"goal-a-29424")
        for needle in (b"todo=11", b"claimed=12", b"in_progress=13",
                       b"awaiting_verification=14", b"done=15", b"cancelled=16"):
            if needle not in h.unwrapped(narrower):
                raise AssertionError(f"60-column Work omitted {needle!r}")
        capture("work-short", 16, 80, b"goal-a-29424")
        key(b"j", b"goal-b-29424")
        key(b"k", b"goal-a-29424")
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
                screen = h.screen_text(bytes(output))
                joined = re.sub(rb"\s+", b"", screen.replace("│".encode(), b""))
                seen.update(value for value in expected if value in joined)
                position = re.search(rb"\b(\d+)-(\d+)/(\d+)\b", screen)
                if position is None:
                    raise AssertionError("System omitted selected document position")
                first, last, total = map(int, position.groups())
                if last >= total:
                    break
                h.press_and_settle(process, fd, output, b"\x1b[6~")
                next_position = re.search(rb"\b(\d+)-(\d+)/(\d+)\b",
                    h.screen_text(bytes(output)))
                if next_position is None or int(next_position.group(1)) <= first:
                    raise AssertionError("System selected document stopped before its end")
            if seen != set(expected):
                raise AssertionError(f"System omitted selected content {set(expected) - seen!r}")
            h.write_all(fd, output, b"\x1b[H")
            h.drain_until_quiet(process, fd, output)

        read_selected((b"Currenttrue", b"Defaultfalse", b"Enabletheobservedfeature", b"override"))
        capture("system-short",16,80,b"studio.enabled")
        read_selected((b"Currenttrue", b"Defaultfalse", b"Enabletheobservedfeature", b"override"))
        key(b"\r",b"editing studio.enabled")
        key(b"\x1b",b"studio.enabled")
        key(b"j",b"studio.mode")
        capture("system-long-comparison",30,80,b"studio.mode")
        parameter_response = fixtures["/api/v1/runtime/params"]
        assert isinstance(parameter_response, tuple)
        parameter_payload = parameter_response[1]
        assert isinstance(parameter_payload, dict)
        parameters = parameter_payload["parameters"]
        assert isinstance(parameters, list) and isinstance(parameters[1], dict)
        current = parameters[1]["current"]
        read_selected((b"Current" + json.dumps(current).encode(),
                       b'Default"mention_or_thread"', b"override"))
        key(b":go Dashboard\r",b"MASC Dashboard")
        os.write(fd,b"q")
    h.run_terminal_scenario(executable,description="surface studio"+(" no color" if no_color else ""),
        interact=interact,http_fixtures=fixtures,workspace="Surface fixture",
        extra_env={"NO_COLOR":"1"} if no_color else None)


def baseline_refresh(executable):
    fixtures = h.planning_selection_http_fixtures()
    response = fixtures[h.PLANNING_PATH]
    assert isinstance(response, tuple) and isinstance(response[1], dict)
    initial = copy.deepcopy(response[1])
    initial["generated_at"] = "2026-08-22T00:00:00Z"
    initial["task_backlog"]["done"] = 31
    updated = copy.deepcopy(initial)
    updated["generated_at"] = "2026-08-23T01:02:03Z"
    updated["task_backlog"]["done"] = 34
    updated["rollup"]["done_count"] += 2
    updated["rollup"]["verifying_count"] += 1
    refreshed = False
    def planning_response():
        return 200, updated if refreshed else initial
    fixtures[h.PLANNING_PATH] = planning_response
    def interact(process, fd, _slave, output, _base):
        nonlocal refreshed
        h.wait_for_output(process, fd, output, b"MASC Dashboard", start=0, timeout=10)
        h.palette_go(process, fd, output, b"go Work", b"MASC Work")
        h.wait_for_output(process, fd, output, b"Baseline snapshot:", start=0, timeout=5)
        refreshed = True
        h.send_and_wait(process, fd, output, b"r", b"2026-08-23T01:02:03Z")
        h.drain_until_quiet(process, fd, output)
        h.resize_and_wait(process, fd, output, rows=30, columns=121,
                         needle=b"2026-08-23T01:02:03Z", controls=(h.FULL_REDRAW,), final_cursor=b"\x1b[?25l")
        frame = h.resize_and_wait(process, fd, output, rows=30, columns=120,
                                 needle=b"2026-08-23T01:02:03Z", controls=(h.FULL_REDRAW,), final_cursor=b"\x1b[?25l")
        plain = h.unwrapped(h.screen_text(frame))
        for text in (b"Baseline snapshot: 2026-08-22T00:00:00Z",
                     b"Current snapshot: 2026-08-23T01:02:03Z",
                     b"Goals done +2", b"Tasks done +3", b"Goal reviews pending +1"):
            assert text in plain, f"baseline refresh lost evidence: {text!r}"
        assert b"this TUI's first reading" not in plain
        print("STUDIO_CAPTURE=" + json.dumps({"name": "work-baseline-refresh", "rows": 30, "columns": 120,
              "provenance": "local candidate fixture PTY", "frame_b64": base64.b64encode(frame).decode(),
              "screen": b"\n".join(h.screen_rows(frame).get(row, b"") for row in range(1, 31)).decode(errors="replace")}), flush=True)
        os.write(fd, b"q")
    h.run_terminal_scenario(executable, description="Work baseline persists while current snapshot advances",
                            interact=interact, http_fixtures=fixtures)

if __name__ == "__main__":
    executable=os.path.abspath(sys.argv[1])
    with open(executable,"rb") as binary:
        print("STUDIO_BINARY_SHA256="+hashlib.sha256(binary.read()).hexdigest(),flush=True)
    run(executable)
    run(executable,True)
    baseline_refresh(executable)
    print("tui surface studio PTY: PASS",flush=True)
