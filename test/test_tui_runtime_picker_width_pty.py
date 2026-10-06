"""Long runtime/model identities remain distinguishable in a narrow picker."""
import json
import os
import sys
import unicodedata

import test_tui_keyboard_input as h


IDS = ["provider." + "shared-runtime-prefix-" * 4 + f"R{index:02d}" for index in range(32)]


def run(executable):
    requests = []
    served = h.keeper_runtime_http_fixtures()
    _, resolved = h.runtime_resolved_response()
    models = [h.runtime_resolved_runtime(runtime_id, "한글 공급자 " * 6,
                                         "긴 모델 이름 " * 10 + f"M{index:02d}")
              for index, runtime_id in enumerate(IDS)]
    for model in models:
        model["quota_exhausted"] = True
    served[h.RUNTIME_RESOLVED_PATH] = (200, {
        **resolved, "default_route": IDS[0], "default_runtime": models[0], "runtimes": models,
        "lanes": [], "assignments": [],
    })
    served["/api/v1/keepers/alpha/config"] = (200, {
        "config_revision": {"manifest": {"state": "missing"},
                            "runtime_assignment": {"state": "runtime_config_missing"}},
    })
    served["/api/v1/runtime/config/assignment"] = (200, {"ok": True})

    def selected(output, runtime, model, columns):
        rows = h.screen_rows(bytes(output))
        found = [row for row in rows.values() if b"> [MODEL]" in row]
        if len(found) != 1:
            raise AssertionError(f"picker selection is not visible: {rows!r}")
        row = found[0]
        cells = sum(0 if unicodedata.combining(character)
                    else 2 if unicodedata.east_asian_width(character) in ("W", "F") else 1
                    for character in row.decode("utf-8"))
        if cells > columns:
            raise AssertionError(f"selected row exceeds {columns} columns ({cells} cells): {row!r}")
        for part in (runtime, model, b"quota"):
            if part not in row:
                raise AssertionError(f"selected row lost {part!r}: {row!r}")

    def interact(process, fd, _slave, output, _base):
        h.send_and_wait(process, fd, output, b"3", b"MASC Keepers")
        h.select_keeper_row(process, fd, output, b"alpha")
        h.send_and_wait(process, fd, output, b"U", "32 of 32".encode())
        h.drain_until_quiet(process, fd, output)
        for rows, columns in ((24, 40), (20, 60), (30, 80)):
            h.resize_and_wait(process, fd, output, rows=rows, columns=columns,
                              needle=b"runtime", controls=(h.FULL_REDRAW,))
            h.write_all(fd, output, b"\x1b[F")
            h.drain_until_quiet(process, fd, output)
            selected(output, b"R31", b"M31", columns)
            h.write_all(fd, output, b"\x1b[H")
            h.drain_until_quiet(process, fd, output)
            selected(output, b"R00", b"M00", columns)
            h.write_all(fd, output, b"\x1b[F")
            h.drain_until_quiet(process, fd, output)
            selected(output, b"R31", b"M31", columns)
        # The compact frame hides the picker. Neither assignment nor default
        # reset is allowed until the selected row is back on screen.
        h.resize_and_wait(process, fd, output, rows=10, columns=80,
                          needle=b"terminal too small", controls=(h.FULL_REDRAW,))
        h.write_all(fd, output, b"\x1b[B\rd")
        h.drain_until_quiet(process, fd, output)
        if any(path == "/api/v1/runtime/config/assignment" for path, _ in requests):
            raise AssertionError("a hidden picker accepted an assignment/default reset")
        h.resize_and_wait(process, fd, output, rows=24, columns=40,
                          needle=b"R31", controls=(h.FULL_REDRAW,))
        selected(output, b"R31", b"M31", 40)
        os.write(fd, b"\r")
        body = json.loads(h.wait_for_http_request(process, fd, output, requests,
                                                 path="/api/v1/runtime/config/assignment"))
        if body.get("keeper_name") != "alpha" or body.get("runtime_id") != IDS[-1]:
            raise AssertionError(f"Enter assigned a different runtime: {body!r}")
        h.drain_until_quiet(process, fd, output)
        os.write(fd, b"q")

    h.run_terminal_scenario(executable, description="Runtime picker fits long names in narrow frames",
                           interact=interact, http_fixtures=served, http_requests=requests)


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("Keeper runtime picker narrow layout: PASS")
