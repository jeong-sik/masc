from __future__ import annotations

from tui_keyboard_harness import FRAME_END
from tui_keyboard_harness import LINES_WINDOW_RE
import re
from tui_keyboard_harness import read_available
from tui_keyboard_harness import screen_rows
from tui_keyboard_harness import wait_for_output

import os
import subprocess

from tui_keyboard_harness import (
    CSI_RE,
    DroppedHttpResponse,
    Interaction,
    composer_showing,
    context_inspector_fixtures,
    drain_until_quiet,
    escape_to_keeper_detail,
    resize_and_wait,
    run_terminal_scenario,
    screen_text,
    select_keeper_row,
    send_and_wait,
)


def run_context_inspector_transport_error_regression(executable: str) -> None:
    fixtures = context_inspector_fixtures()
    fixtures["/api/v1/keepers/alpha/turn-records?limit=50"] = DroppedHttpResponse()

    def interact(process, master_fd, _slave_fd, output, _base_path):
        resize_and_wait(process, master_fd, output, rows=50, columns=160, needle=b"MASC Dashboard")
        send_and_wait(process, master_fd, output, b"3", b"MASC Keepers")
        select_keeper_row(process, master_fd, output, b"alpha")
        send_and_wait(process, master_fd, output, b"\r", b"Keepers \xe2\x96\xb8 \x1b[1malpha")
        send_and_wait(process, master_fd, output, b"m", b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat")
        send_and_wait(process, master_fd, output, b"/context", composer_showing(b"/context"))
        frame = send_and_wait(
            process, master_fd, output, b"\r",
            b"Composition unavailable: turn-records: GET failed:",
        )
        plain = CSI_RE.sub(b"", frame)
        if b"request failed: GET failed" in plain:
            raise AssertionError(f"Transport failure received two verdicts: {frame!r}")
        if b"NEXT REQUEST" not in plain:
            raise AssertionError(f"Independent forecast was lost after turn read failure: {frame!r}")
        # The chat view is message mode, where q is a composer key rather
        # than the quit key, so leaving runs through the keeper detail like
        # the sibling inspector scenario. Esc closes the inspector itself:
        # the error view opens no exact item, so one press reaches chat.
        send_and_wait(process, master_fd, output, b"\x1b", b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat")
        escape_to_keeper_detail(process, master_fd, output, name=b"alpha")
        os.write(master_fd, b"q")

    run_terminal_scenario(
        executable,
        description="Context Inspector shows transport cause once",
        interact=interact,
        http_fixtures=fixtures,
    )


def context_inspector_interaction() -> Interaction:
    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        resize_and_wait(
            process, master_fd, output, rows=50, columns=140, needle=b"MASC Dashboard"
        )
        send_and_wait(process, master_fd, output, b"3", b"MASC Keepers")
        select_keeper_row(process, master_fd, output, b"alpha")
        send_and_wait(
            process, master_fd, output, b"\r", b"Keepers \xe2\x96\xb8 \x1b[1malpha"
        )
        send_and_wait(
            process,
            master_fd,
            output,
            b"m",
            b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat",
        )
        send_and_wait(
            process, master_fd, output, b"/context", composer_showing(b"/context")
        )
        composition = open_context_and_read_history_pages(
            process, master_fd, output
        )
        composition_plain = CSI_RE.sub(b"", composition)
        for needle in (
            b"claude-opus-5",
            b"50.0k / 200.0k tokens",
            b"Tool schemas",
            b"User messages",
            b"Tool results",
            # The section is headed in plain words now, and the count reads
            # "of" rather than a fraction. Both are pinned: the heading says
            # which section this is, the count says what it carried.
            b"how much of the kept conversation this request carried",
            b"7 of 9 kept atoms",
        ):
            if needle not in composition_plain:
                raise AssertionError(
                    f"Context composition omitted {needle!r}: {composition!r}"
                )

        exact_input = send_and_wait(
            process, master_fd, output, b"2", b"SELECTED INPUT"
        )
        exact_input_plain = CSI_RE.sub(b"", exact_input)
        for needle in (
            b"trace-context#42",
            b"REQUEST ITEMS",
            b"System prompt",
            b"Message \xc2\xb7 system",
            b"Message \xc2\xb7 tool",
            b"Tool schema \xc2\xb7 masc_execute",
            b"Prepared request  anthropic",
            b"RETAINED ITEM",
        ):
            if needle not in exact_input_plain:
                raise AssertionError(
                    f"Exact provider input omitted {needle!r}: {exact_input!r}"
                )

        send_and_wait(
            process,
            master_fd,
            output,
            b"j",
            b"exact dynamic context from the turn",
        )
        exact = send_and_wait(
            process, master_fd, output, b"\r", b"exact dynamic context from the turn"
        )
        if b"SELECTED INPUT" in CSI_RE.sub(b"", exact):
            raise AssertionError(
                f"Exact item view retained the list disclosure: {exact!r}"
            )

        send_and_wait(
            process, master_fd, output, b"\x1b", b"SELECTED INPUT"
        )
        input_map = send_and_wait(
            process, master_fd, output, b"3", b"Provider request map"
        )
        input_map_plain = CSI_RE.sub(b"", input_map)
        for needle in (
            b"CONTEXT STACK",
            b"SELECTED BLOCK",
            b"EXACT TURN JOIN",
            b"VERIFIED",
            b"SERIALIZED",
        ):
            if needle not in input_map_plain:
                raise AssertionError(
                    f"Provider request map omitted {needle!r}: {input_map!r}"
                )

        narrow_map = resize_and_wait(
            process,
            master_fd,
            output,
            rows=35,
            columns=109,
            needle=b"SELECTED BLOCK",
        )
        # The whole screen, not the frame the resize returned: a frame holds
        # only the rows it wrote, and the resize repaints the map over more
        # than one. The clear it starts with makes the wait matter -- until
        # the later frames land, the evidence rows are blank rather than
        # still holding what they said at the old width.
        drain_until_quiet(process, master_fd, output)
        narrow_map_plain = screen_text(bytes(output))
        for forbidden in (b"reached the provider", b"provider accepted", b"ON WIRE"):
            if forbidden in narrow_map_plain:
                raise AssertionError(
                    f"Narrow provider map overstated pre-dispatch evidence as "
                    f"{forbidden!r}: {narrow_map!r}"
                )
        for needle in (
            b"turn prompt assembly",
            b"digest",
            b"retained text",
            b"Keeper instruction text",
        ):
            if needle not in narrow_map_plain:
                raise AssertionError(
                    f"Narrow provider map omitted selected evidence {needle!r}: "
                    f"{narrow_map!r}"
                )

        serialized_detail = send_and_wait(
            process,
            master_fd,
            output,
            b"j",
            b"pre-dispatch serialization snapshot exists",
        )
        serialized_detail_plain = CSI_RE.sub(b"", serialized_detail)
        for needle in (b"SERIALIZED", b"turn prompt assembly", b"digest"):
            if needle not in serialized_detail_plain:
                raise AssertionError(
                    f"Narrow serialized detail omitted {needle!r}: "
                    f"{serialized_detail!r}"
                )
        send_and_wait(
            process,
            master_fd,
            output,
            b"k",
            b"Keeper instruction text",
        )

        map_exact = send_and_wait(
            process,
            master_fd,
            output,
            b"\r",
            b"Keeper instruction text",
        )
        if b"turn prompt assembly" not in CSI_RE.sub(b"", map_exact):
            raise AssertionError(f"Input map exact view lost provenance: {map_exact!r}")

        send_and_wait(process, master_fd, output, b"\x1b", b"Provider request map")
        send_and_wait(
            process,
            master_fd,
            output,
            b"\x1b",
            b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat",
        )
        # The overlay is headed "MASC Cheat Sheet" now; "Slash commands" was a
        # section title it no longer carries.
        cheat_sheet = CSI_RE.sub(
            b"", send_and_wait(process, master_fd, output, b"?", b"MASC Cheat Sheet")
        )
        # The keys that close and toggle the sheet are the footer's. The title
        # used to spell them as well, so the frame said each of them twice.
        if b"[Esc] close" in cheat_sheet or b"[h] toggle" in cheat_sheet:
            raise AssertionError(f"Cheat sheet title spells footer keys: {cheat_sheet!r}")
        if b"Esc:close" not in cheat_sheet:
            raise AssertionError(f"Cheat sheet footer lost its way out: {cheat_sheet!r}")
        # A usage wider than its panel wrapped rather than being cut. At this
        # terminal's hundred columns the sheet used to end /addons at
        # "detach" with an ellipsis, so three of its six subcommands were off
        # the one screen whose whole job is to say what can be typed. The
        # needle is the tail, because that is the half that went missing.
        for needle in (b"/addons [inspect|attach JSON|observe", b"evidence JSON]"):
            if needle not in cheat_sheet:
                raise AssertionError(
                    f"Cheat sheet cut a slash usage, missing {needle!r}: {cheat_sheet!r}"
                )
        # The /context disclosure this step used to assert is not here any
        # more: the cheat sheet lists keys, and the slash commands announce
        # themselves in the composer's hint line as the word is typed
        # (Masc_tui_command.hint_spans, drawn at masc_tui_render.ml). That
        # surface has no coverage yet and wants its own scenario rather than
        # a tail on this one.
        send_and_wait(process, master_fd, output, b"\x1b", b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat")
        escape_to_keeper_detail(process, master_fd, output, name=b"alpha")
        os.write(master_fd, b"q")

    return interact



def next_request_forecast_fixture(*, with_continuity: bool) -> dict[str, object]:
    origin: dict[str, object] = (
        {"kind": "librarian_snapshot", "end_atom": 2698, "boundary_line": 2215}
        if with_continuity
        else {"kind": "ledger"}
    )
    return {
        "schema": "masc.keeper.next-request-forecast.v5",
        "keeper": "alpha",
        "trace_id": "trace-next-request",
        "checkpoint_messages": 5217,
        "wake_line_bytes": 131,
        "walk": {
            "lane_id": "kimi_coding.kimi-for-coding",
            "declared": ["kimi_coding.kimi-for-coding"],
        },
        "candidates": [
            {
                "runtime_id": "kimi_coding.kimi-for-coding",
                "lane": {"agent_core": True},
                "marks": {"high_water_tokens": 100000, "low_water_tokens": 70000},
                "parts": {"error": "no completed turn on this runtime carried a composition in the newest 200 records"},
                "history_atoms": 2718,
                "carried": {
                    "first_atom": 2698,
                    "kept_atoms": 20,
                    "transmitted_bytes": 237300,
                    "preamble_bytes": None,
                    "origin": origin,
                    "counted_tokens": None if with_continuity else 71000,
                },
                "assembly": None,
                "place": {"walks_at": 0, "declared_at": 0, "rest": {"kind": "serving"}},
            }
        ],
    }



def scroll_context_one_line(process, master_fd, output) -> bytes:
    # A scroll paints one frame. send_and_wait(..., FRAME_END) would consume
    # that marker as its needle and then wait for an unnecessary second frame.
    read_available(master_fd, output)
    start = len(output)
    os.write(master_fd, b"j")
    wait_for_output(process, master_fd, output, FRAME_END, start=start, timeout=3.0)
    frame_end = output.find(FRAME_END, start) + len(FRAME_END)
    return bytes(output[start:frame_end])



def open_context_and_read_history_pages(process, master_fd, output) -> bytes:
    # The loaded context can be taller than the terminal. Walk its actual
    # reported pages, preserving the bytes for the existing content checks.
    drawn = send_and_wait(process, master_fd, output, b"\r", b"WHAT WENT IN")
    while True:
        visible = screen_text(bytes(output))
        bounds = re.search(rb"\[lines (\d+)-(\d+)/(\d+)\]", visible)
        if bounds is None or int(bounds[2]) == int(bounds[3]):
            break
        first = int(bounds[1])
        drawn += scroll_context_one_line(process, master_fd, output)
        advanced = re.search(rb"\[lines (\d+)-(\d+)/(\d+)\]",
                             screen_text(bytes(output)))
        if advanced is None or int(advanced[1]) <= first:
            raise AssertionError("Context j did not advance its reported window")
    if b"HOW FAR BACK" not in CSI_RE.sub(b"", drawn):
        raise AssertionError("Loaded Context pages omitted the history band")
    return drawn



def context_visible_pane(output) -> tuple[bytes, bytes, tuple[int, int, int] | None]:
    """Current completed Context body, joining only its visible row payloads."""
    end = output.rfind(FRAME_END)
    if end < 0:
        raise AssertionError("Context has no completed frame")
    completed = bytes(output[:end + len(FRAME_END)])
    rows = screen_rows(completed)
    title = next((number for number, row in sorted(rows.items())
                  if b"MASC Context" in row), None)
    if title is None:
        raise AssertionError(f"Context title is not visible: {screen_text(completed)!r}")
    window = next(((number, match) for number, row in sorted(rows.items())
                   if (match := LINES_WINDOW_RE.search(row)) is not None), None)
    bounds = None if window is None else tuple(int(value) for value in window[1].groups())
    if bounds is not None and not (1 <= bounds[0] <= bounds[1] <= bounds[2]):
        raise AssertionError(f"Invalid Context window: {bounds!r}")
    border = "│".encode()
    payloads = []
    for number, row in sorted(rows.items()):
        if number <= title or (window is not None and number >= window[0]):
            continue
        plain = row.strip()
        if plain.startswith(border) and plain.endswith(border):
            payload = plain[len(border):-len(border)].strip()
            if payload:
                payloads.append(payload)
    return screen_text(completed), b" ".join(payloads), bounds



def run_next_request_readability_regression(executable: str) -> None:
    for with_continuity in (True, False):
        for cols in (80, 140):
            fixtures = context_inspector_fixtures()
            fixtures["/api/v1/keepers/alpha/next-request"] = (
                200,
                next_request_forecast_fixture(with_continuity=with_continuity),
            )

            def interact(process, master_fd, _slave_fd, output, _base_path):
                resize_and_wait(
                    process, master_fd, output, rows=32, columns=cols,
                    needle=b"MASC Dashboard",
                )
                send_and_wait(process, master_fd, output, b"3", b"MASC Keepers")
                select_keeper_row(process, master_fd, output, b"alpha")
                send_and_wait(
                    process, master_fd, output, b"\r",
                    b"Keepers \xe2\x96\xb8 \x1b[1malpha",
                )
                send_and_wait(
                    process, master_fd, output, b"m",
                    b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat",
                )
                send_and_wait(
                    process, master_fd, output, b"/context",
                    composer_showing(b"/context"),
                )
                send_and_wait(process, master_fd, output, b"\r", b"WHAT WENT IN")
                while True:
                    visible, pane, bounds = context_visible_pane(output)
                    if (
                        b"Config / Runtime:" in pane
                        and b"model limit." in pane
                        and b"History preview:" in pane
                        and (
                            (b"Librarian working state" in pane)
                            if with_continuity
                            else (b"front from this runtime's ledger" in pane)
                        )
                    ):
                        break
                    # At the last reported row j changes nothing, so no new
                    # frame is expected. Fail here with the current viewport.
                    if bounds is None or bounds[1] == bounds[2]:
                        raise AssertionError(
                            f"Next Request meaning not visible at {cols} columns "
                            f"at Context window {bounds!r}: {visible!r}"
                        )
                    first = bounds[0]
                    scroll_context_one_line(process, master_fd, output)
                    _visible, _pane, advanced = context_visible_pane(output)
                    if advanced is None or advanced[0] <= first:
                        raise AssertionError(
                            f"Context j did not advance its reported window: "
                            f"{bounds!r} -> {advanced!r}"
                        )
                if b"100.0k / 70.0k" in visible:
                    raise AssertionError("trim settings still look like a forecast figure")
                print(
                    f"NEXT_REQUEST_CAPTURE {'continuity' if with_continuity else 'ledger'} "
                    f"{cols}x32\n{visible.decode(errors='replace')}"
                )
                send_and_wait(
                    process, master_fd, output, b"\x1b",
                    b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat",
                )
                escape_to_keeper_detail(process, master_fd, output, name=b"alpha")
                os.write(master_fd, b"q")

            run_terminal_scenario(
                executable,
                description=(
                    f"Next Request {'Librarian' if with_continuity else 'ledger'} "
                    f"copy at {cols} columns"
                ),
                interact=interact,
                terminal_cols=cols,
                http_fixtures=fixtures,
            )


def run_context_catalog_read_scope(executable: str) -> None:
    """Current configuration is read on entry/refresh, not per historical turn."""
    import copy
    import threading
    from tui_keyboard_harness import RUNTIME_RESOLVED_PATH, wait_for_fixture_event
    from tui_keyboard_runtime import runtime_resolved_response

    fixtures = context_inspector_fixtures()
    _, turns = fixtures["/api/v1/keepers/alpha/turn-records?limit=50"]
    previous = copy.deepcopy(turns["entries"][0])
    previous["record"].update(absolute_turn=41, turn_ref="trace-context#41", ts=1787599900.0)
    turns["entries"].insert(0, previous)
    catalog = runtime_resolved_response()
    reads = []
    arrived = threading.Event()

    def read_catalog():
        reads.append(True)
        arrived.set()
        return catalog

    fixtures[RUNTIME_RESOLVED_PATH] = read_catalog

    def interact(process, fd, _slave, output, _base):
        resize_and_wait(process, fd, output, rows=50, columns=160, needle=b"MASC Dashboard")
        send_and_wait(process, fd, output, b"3", b"MASC Keepers")
        select_keeper_row(process, fd, output, b"alpha")
        send_and_wait(process, fd, output, b"\r", b"Keepers \xe2\x96\xb8 \x1b[1malpha")
        send_and_wait(process, fd, output, b"m", b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat")
        send_and_wait(process, fd, output, b"/context", composer_showing(b"/context"))
        before_open = len(reads)
        arrived.clear()
        send_and_wait(process, fd, output, b"\r", b"turn #42")
        if not wait_for_fixture_event(process, fd, output, arrived, timeout=3.0):
            raise AssertionError("opening Context did not read its current catalogue")
        drain_until_quiet(process, fd, output)
        if len(reads) != before_open + 1:
            raise AssertionError("opening Context read its catalogue more than once")
        opened = len(reads)
        for key, turn in ((b"[", b"turn #41"), (b"]", b"turn #42")) * 3:
            send_and_wait(process, fd, output, key, turn)
        drain_until_quiet(process, fd, output)
        if len(reads) != opened:
            raise AssertionError("historical turn navigation fetched the current catalogue")
        arrived.clear()
        os.write(fd, b"r")
        if not wait_for_fixture_event(process, fd, output, arrived, timeout=3.0):
            raise AssertionError("explicit Context refresh did not refresh the catalogue")
        drain_until_quiet(process, fd, output)
        if len(reads) != opened + 1:
            raise AssertionError("explicit refresh read its catalogue more than once")
        send_and_wait(process, fd, output, b"\x1b", b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat")
        escape_to_keeper_detail(process, fd, output, name=b"alpha")
        os.write(fd, b"q")

    run_terminal_scenario(executable, description="Context catalogue reads follow entry and explicit refresh",
                          interact=interact, http_fixtures=fixtures)
