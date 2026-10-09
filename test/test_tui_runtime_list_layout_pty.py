"""Runtime candidate identity and route/probe survive narrow listings."""
import os
import re
import sys
import unicodedata
import tui_keyboard_harness as _keyboard_harness
import tui_keyboard_runtime as _keyboard_runtime


RUNTIME_ID = "fixture-runtime-한글-very-long-identity-tailZ"
LANE_ID = "fixture-lane-아주긴이름-primary-tailL"
# Short enough to stay whole in the RUNTIME column, so its row is found by name.
EXHAUSTED_ID = "exhausted"
SGR_RE = re.compile(rb"\x1b\[[0-9;]*m")


def styling(row):
    """The colours and attributes a captured row is drawn with.

    A captured row can end with cursor or mode sequences from the frame
    around it, which say nothing about how the row itself looks.
    """
    return b"".join(SGR_RE.findall(row))


def look(row):
    """What a reader sees of a captured row: its text and its styling."""
    return _keyboard_harness.CSI_RE.sub(b"", row), styling(row)


def screen(output):
    raw = bytes(output)
    end = raw.rfind(_keyboard_harness.FRAME_END)
    assert end >= 0, "no completed terminal frame"
    return _keyboard_harness.screen_text(raw[:end + len(_keyboard_harness.FRAME_END)]).decode("utf-8", errors="strict")


def status_header_visible(columns, all_runtimes):
    """Whether the ROUTE / PROBE header fits at this width.

    Mirrors the product's width formula in bin/masc_tui_render.ml
    runtime_table_cells (~line 9395): inner width is columns - 4
    (masc_tui_frame.ml border 2 + padding 2) minus 2, cell_gap is 1
    (masc_tui_table.ml), and lane/candidate/status widths come from
    runtime_column_widths. The Runtime_lanes arm (#41143) reserves
    lane+candidate first, so a narrow terminal folds the status column and keeps
    the full status in detail; the Runtime_all arm reserves only the candidate
    heading, so its status stays visible.
    """
    if columns >= 140:
        lane, candidate, status = 18, 30, 22
    elif columns >= 120:
        lane, candidate, status = 14, 24, 22
    else:
        lane, candidate, status = 10, 20, 22
    inner = max(1, (columns - 4) - 2)
    if all_runtimes:
        status_width = min(status, max(1, inner - len("RUNTIME") - 1))
    else:
        remaining = inner - lane - 2 * 1
        candidate_floor = min(candidate, max(1, remaining - 1))
        status_width = min(status, max(1, remaining - candidate_floor))
    return status_width >= len("ROUTE / PROBE")


def run(executable, no_color):
    fixtures = _keyboard_harness.keeper_runtime_http_fixtures()
    _, resolved = _keyboard_runtime.runtime_resolved_response()
    assert isinstance(resolved, dict)
    runtime = _keyboard_runtime.runtime_resolved_runtime(RUNTIME_ID, "fixture-provider", "fixture-model")
    resolved["runtimes"] = [runtime]
    resolved["default_runtime"] = runtime
    resolved["default_route"] = LANE_ID
    resolved["lanes"] = [{"id": LANE_ID, "runtime_ids": [RUNTIME_ID], "declared": True}]
    resolved["assignments"] = []
    _, probe = _keyboard_runtime.runtime_probe_response(fresh=True)
    probe["probe"]["providers"] = [_keyboard_runtime.runtime_probe_provider(RUNTIME_ID, status="reachable")]
    probe["probe"]["summary"].update({"runtimes": 1, "probed": 1,
        "reachable": 1, "failed": 0, "skipped": 0, "default_runtime_id": RUNTIME_ID})
    fixtures[_keyboard_harness.RUNTIME_RESOLVED_PATH] = (200, resolved)
    fixtures[_keyboard_runtime.RUNTIME_PROBE_PATH] = (200, probe)
    fixtures[_keyboard_runtime.RUNTIME_PROBE_FORCE_PATH] = (200, probe)

    def interact(process, fd, _slave, output, _base):
        _keyboard_harness.tab_until(process, fd, output, b"MASC System")
        _keyboard_harness.send_and_wait(process, fd, output, b"9", b"MASC System / Runtime")
        _keyboard_harness.wait_for_output(process, fd, output, b"tailZ", start=0, timeout=10)
        _keyboard_harness.wait_for_output(process, fd, output, b"reachable", start=0, timeout=10)
        for all_runtimes in (False, True):
            if all_runtimes:
                # The lane sweep already ended at120x32; an unchanged size
                # produces no redraw. Check geometry, then wait for mode change.
                size = os.get_terminal_size(fd)
                assert (size.columns, size.lines) == (120, 32), size
                _keyboard_harness.send_and_wait(process, fd, output, b"p", b"All runtimes")
            for columns in (30, 40, 60, 80, 120):
                resize_start = len(output)
                _keyboard_harness.resize_and_wait(process, fd, output, rows=32, columns=columns,
                                  needle=b"MASC System / Runtime", controls=(_keyboard_harness.FULL_REDRAW,))
                clear = output.rfind(_keyboard_harness.FULL_REDRAW, resize_start)
                assert clear >= resize_start
                _keyboard_harness.wait_for_output(process, fd, output, _keyboard_harness.FRAME_END,
                    start=_keyboard_harness.end_of_needle(output, b"MASC System / Runtime", clear), timeout=3)
                visible = screen(output)
                status_visible = status_header_visible(columns, all_runtimes)
                if not all_runtimes:
                    default_block = visible.split("[runtime].default", 1)[1].split("ROUTE / PROBE", 1)[0]
                    route_block, marker, _ = default_block.partition("media_")
                    assert marker, (columns, default_block)
                    readable = "".join(route_block.split())
                    assert LANE_ID in readable and RUNTIME_ID in readable, (columns, route_block)
                    assert "…" not in route_block, (columns, route_block)
                if status_visible:
                    suffix = RUNTIME_ID[-4:] if columns == 30 else "tailZ"
                    # The fixture has no account usage scope, so the folded row
                    # reports usage unknown; reachability remains in detail.
                    candidate_rows = [row for row in visible.splitlines()
                                      if suffix in row and "usage unknown" in row]
                    assert len(candidate_rows) == 1, (columns, all_runtimes, visible)
                    cells = sum(0 if unicodedata.combining(char) else
                                2 if unicodedata.east_asian_width(char) in ("W", "F") else 1
                                for char in candidate_rows[0])
                    assert cells <= columns, (columns, cells, candidate_rows)
                    assert "\\x1B" not in candidate_rows[0], candidate_rows
                    if columns in (30, 40):
                        assert "…" in candidate_rows[0], candidate_rows
                else:
                    # #41143 folds the status column at this width: the lane and
                    # candidate stay visible, and the full status is read in
                    # detail below (asserted after the detail opens).
                    lane_heading = "USED BY" if all_runtimes else "LANE"
                    candidate_heading = "RUNTIME" if all_runtimes else "CANDIDATE"
                    header = next(row for row in visible.splitlines()
                                  if lane_heading in row and candidate_heading in row)
                    assert "ROUTE / PROBE" not in header, (columns, header)
                # The full identity is read through the same selected row.
                _keyboard_harness.send_and_wait(process, fd, output, b"\r", b"Runtime ID:")
                detail = screen(output)
                field = detail.split("Runtime ID:", 1)[1].split("Provider:", 1)[0]
                recovered = "".join(field.split())
                assert RUNTIME_ID in recovered, (columns, recovered, detail)
                probe_detail = detail
                if "Probe status:" not in probe_detail:
                    _keyboard_harness.press_and_settle(process, fd, output, b"\x1b[F")
                    probe_detail = screen(output)
                    if "Probe status:" not in probe_detail:
                        _keyboard_harness.send_and_wait(process, fd, output, b"\x1b[5~", b"Probe status:")
                        probe_detail = screen(output)
                probe_field = probe_detail.split("Probe status:", 1)[1].split("Probe transport:", 1)[0]
                assert "reachable" in "".join(probe_field.split()), (columns, probe_detail)
                if not status_visible:
                    # #41143 folds the table's status column at this width; the
                    # same facts are read in the detail as Probe status and
                    # Account usage (the table's "usage unknown" value is the
                    # folded column, not a detail label).
                    assert "Probe status:" in probe_detail, (columns, probe_detail)
                    assert "Account usage:" in probe_detail, (columns, probe_detail)
                _keyboard_harness.send_and_wait(process, fd, output, b"\x1b",
                    b"ROUTE / PROBE" if status_visible else b"MASC System / Runtime")
        os.write(fd, b"q")

    _keyboard_harness.run_terminal_scenario(executable,
        description=f"Runtime listing responsive identity and status NO_COLOR={no_color}",
        interact=interact, http_fixtures=fixtures,
        extra_env={"NO_COLOR": "1"} if no_color else {})


def run_dimming(executable):
    """`h` dims and restores a quota-exhausted row without moving or redrawing the others.

    Its own fixture and its own TUI: a second runtime with a long status
    changes the column widths the responsive sweep in `run` measures.
    """
    fixtures = _keyboard_harness.keeper_runtime_http_fixtures()
    _, resolved = _keyboard_runtime.runtime_resolved_response()
    assert isinstance(resolved, dict)
    normal = _keyboard_runtime.runtime_resolved_runtime(RUNTIME_ID, "fixture-provider", "fixture-model")
    exhausted = _keyboard_runtime.runtime_resolved_runtime(EXHAUSTED_ID, "fixture-provider", "fixture-model")
    exhausted["quota_exhausted"] = True
    resolved["runtimes"] = [normal, exhausted]
    resolved["default_runtime"] = normal
    resolved["default_route"] = LANE_ID
    resolved["lanes"] = [{"id": LANE_ID, "runtime_ids": [RUNTIME_ID, EXHAUSTED_ID], "declared": True}]
    resolved["assignments"] = []
    _, probe = _keyboard_runtime.runtime_probe_response(fresh=True)
    probe["probe"]["providers"] = [
        _keyboard_runtime.runtime_probe_provider(RUNTIME_ID, status="reachable"),
        _keyboard_runtime.runtime_probe_provider(EXHAUSTED_ID, status="reachable"),
    ]
    probe["probe"]["summary"].update({"runtimes": 2, "probed": 2,
        "reachable": 2, "failed": 0, "skipped": 0, "default_runtime_id": RUNTIME_ID})
    fixtures[_keyboard_harness.RUNTIME_RESOLVED_PATH] = (200, resolved)
    fixtures[_keyboard_runtime.RUNTIME_PROBE_PATH] = (200, probe)
    fixtures[_keyboard_runtime.RUNTIME_PROBE_FORCE_PATH] = (200, probe)

    def runtime_rows(rows):
        """The exhausted row and the normal row of the All runtimes table."""
        exhausted_rows = [(row_id, row) for row_id, row in rows.items()
                          if EXHAUSTED_ID.encode() in row]
        assert len(exhausted_rows) == 1, f"exhausted runtime row missing: {rows!r}"
        # The table clips the long ID in the middle and keeps its tail.
        normal_rows = [(row_id, row) for row_id, row in rows.items()
                       if RUNTIME_ID[-4:].encode() in row
                       and b"usage unknown" in _keyboard_harness.CSI_RE.sub(b"", row)]
        assert len(normal_rows) == 1, f"normal runtime row missing: {rows!r}"
        return exhausted_rows[0], normal_rows[0]

    def interact(process, fd, _slave, output, _base):
        _keyboard_harness.tab_until(process, fd, output, b"MASC System")
        _keyboard_harness.send_and_wait(process, fd, output, b"9", b"MASC System / Runtime")
        _keyboard_harness.wait_for_output(process, fd, output, b"tailZ", start=0, timeout=10)
        _keyboard_harness.wait_for_output(process, fd, output, b"reachable", start=0, timeout=10)
        # The cursor starts on the first (normal) row, so the exhausted row is
        # drawn unselected and its dimming is visible.
        _keyboard_harness.send_and_wait(process, fd, output, b"p", b"All runtimes")
        _keyboard_harness.drain_until_quiet(process, fd, output)

        def toggle():
            start = len(output)
            os.write(fd, b"h")
            _keyboard_harness.wait_for_output(process, fd, output, EXHAUSTED_ID.encode(), start=start, timeout=3)
            _keyboard_harness.wait_for_output(process, fd, output, _keyboard_harness.FRAME_END, start=start, timeout=3)
            _keyboard_harness.drain_until_quiet(process, fd, output)
            return runtime_rows(_keyboard_harness.screen_rows(bytes(output), preserve_styles=True))

        (dim_index, dim_row), (normal_index, normal_row) = runtime_rows(
            _keyboard_harness.screen_rows(bytes(output), preserve_styles=True))
        assert normal_index < dim_index, (normal_index, dim_index)
        text = _keyboard_harness.CSI_RE.sub(b"", dim_row)

        (off_index, off_row), (off_normal_index, off_normal_row) = toggle()
        assert (off_index, off_normal_index) == (dim_index, normal_index), "h moved a row"
        assert _keyboard_harness.CSI_RE.sub(b"", off_row) == text, off_row
        assert styling(off_row) != styling(dim_row), (dim_row, off_row)
        assert look(off_normal_row) == look(normal_row), (normal_row, off_normal_row)

        (on_index, on_row), (on_normal_index, on_normal_row) = toggle()
        assert (on_index, on_normal_index) == (dim_index, normal_index), "h moved a row"
        assert look(on_row) == look(dim_row), (dim_row, on_row)
        assert look(on_normal_row) == look(normal_row), (normal_row, on_normal_row)
        os.write(fd, b"q")

    _keyboard_harness.run_terminal_scenario(executable,
        description="Runtime listing dims and restores an exhausted row",
        interact=interact, http_fixtures=fixtures)


if __name__ == "__main__":
    for no_color in (False, True):
        run(os.path.abspath(sys.argv[1]), no_color)
    run_dimming(os.path.abspath(sys.argv[1]))
    print("Runtime list responsive identity/status and full detail: PASS")
