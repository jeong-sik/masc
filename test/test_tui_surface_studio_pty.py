"""Work, Workspace and System responsive panels from the CI fixture PTY."""
import base64
import hashlib
import json
import os
import sys
import test_tui_keyboard_input as h

SOURCE_MODULES = ("bin/masc_tui_render.ml", "bin/masc_tui.ml")

def run(executable, no_color=False):
    fixtures = h.planning_selection_http_fixtures()
    _, repositories = h.repositories_fixture()
    repositories["repositories"].append({**repositories["repositories"][0],
        "id":"next-repo", "name":"next-repo", "local_path":"workspace/next-repo",
        "resolved_local_path":"/srv/masc/workspace/next-repo"})
    repositories["total"] = 2
    fixtures[h.REPOSITORIES_PATH] = (200, repositories)
    fixtures["/api/v1/runtime/params"] = (200, {"parameters": [
        {"key": "studio.enabled", "current": True, "default": False,
         "has_override": True, "meta": {"description": "Enable the observed feature",
         "value_type": "bool"}},
        {"key": "studio.mode", "current": "quiet", "default": "quiet",
         "has_override": False, "meta": {"description": "Presentation mode",
         "value_type": "string"}}], "surfaces": []})
    def interact(process, fd, _slave, output, _base):
        def key(value, needle):
            return h.send_and_wait(process, fd, output, value, needle)
        def capture(name, rows, columns, needle):
            h.resize_and_wait(process, fd, output, rows=rows, columns=columns+1,
                needle=needle, controls=(h.FULL_REDRAW,), final_cursor=b"\x1b[?25l")
            frame = h.resize_and_wait(process, fd, output, rows=rows, columns=columns,
                needle=needle, controls=(h.FULL_REDRAW,), final_cursor=b"\x1b[?25l")
            print("STUDIO_CAPTURE="+json.dumps({"name":name+("-no-color" if no_color else ""),
                "rows":rows,"columns":columns,"provenance":"CI fixture PTY",
                "frame_b64":base64.b64encode(frame).decode(),
                "screen":h.screen_text(frame).decode(errors="replace")}),flush=True)
            return h.screen_text(frame)
        h.wait_for_output(process,fd,output,b"Health: ",start=0,timeout=10)
        key(b":go Work\r",b"plan-alpha-29424")
        wide=capture("work-wide",36,160,b"Goals")
        for needle in ("Goals · measured outcomes".encode(),"Tasks · current backlog".encode()):
            if needle not in wide: raise AssertionError(f"Work omitted {needle!r}")
        capture("work-narrow",24,80,b"plan-alpha-29424")
        key(b":go Workspace\r",b"/srv/masc/workspace/masc")
        for name,rows,cols in (("workspace-wide",32,160),("workspace-narrow",24,80)):
            screen=capture(name,rows,cols,b"Keepers: alpha")
            for needle in (b"Path:",b"Stored as: workspace/masc",b"Keepers: alpha"):
                if needle not in screen: raise AssertionError(f"Workspace omitted {needle!r}")
        key(b"j", b"next-repo")
        selected = capture("workspace-short-selected",16,80,b"/srv/masc/workspace/next-repo")
        if b"next-repo" not in selected:
            raise AssertionError("selected repository disappeared in short viewport")
        key(b":settings\r",b"studio.enabled")
        wide=capture("system-wide",32,160,b"Selected setting")
        for needle in (b"Current on",b"Default off",b"override",b"Enable the observed feature"):
            if needle not in wide: raise AssertionError(f"System omitted {needle!r}")
        capture("system-short",16,80,b"studio.enabled")
        key(b"\r",b"editing studio.enabled")
        key(b"\x1b",b"studio.enabled")
        key(b":go Dashboard\r",b"MASC Dashboard")
        os.write(fd,b"q")
    h.run_terminal_scenario(executable,description="surface studio"+(" no color" if no_color else ""),
        interact=interact,http_fixtures=fixtures,workspace="Surface fixture",
        extra_env={"NO_COLOR":"1"} if no_color else None)

if __name__ == "__main__":
    executable=os.path.abspath(sys.argv[1])
    with open(executable,"rb") as binary:
        print("STUDIO_BINARY_SHA256="+hashlib.sha256(binary.read()).hexdigest(),flush=True)
    run(executable)
    run(executable,True)
    print("tui surface studio PTY: PASS",flush=True)
