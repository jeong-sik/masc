from __future__ import annotations

import base64
import fcntl
import hashlib
import json
import os
import re
import select
import signal
import struct
import subprocess
import termios
import threading
import time
import urllib.parse
from collections.abc import Callable
from typing import Any

from tui_keyboard_chat import (
    GRAPHICS_SUPPORTED_REPLY,
)
from tui_keyboard_harness import (
    CSI_RE,
    GatedHttpResponse,
    HttpRequests,
    HttpResponse,
    PathHttpResponse,
    RequestHttpResponse,
    read_available,
    run_terminal_scenario,
    send_and_wait,
    wait_for_fixture_event,
    wait_for_output,
)

# What the MSX screen draws when it opens. RFC-0439 3.7 has it open the load
# menu first, so this is the title an arrival is proved by; the spectator's own
# "no machine loaded" line belongs to the screen behind the menu.
MSX_MENU_TITLE = "MSX \u2014 pick a game".encode()

# The machine's frame, as the server sends it (server_routes_http_routes_msx:
# 256x192x3 raw RGB, base64 in the JSON).
MSX_FRAME_WIDTH = 256
MSX_FRAME_HEIGHT = 192
MSX_HALF_BLOCK = "\u2580".encode()
MSX_LEFT_HALF = b"38;2;255;0;0"
MSX_RIGHT_HALF = b"38;2;0;0;255"
# What fit_grid picks for this frame in the harness's 30-row, 100-column
# window: the height binds (2*(30-2) = 56 rows), so the width follows the
# frame's ratio at 56*256/192 = 74. Filling the window instead would draw 100,
# which is the frame a third wider than itself.
MSX_EXPECTED_CELLS = 74


def msx_loaded_frame_fixture() -> HttpResponse:
    """A frame split down the middle: red left, blue right.

    Two flat halves rather than a picture, because what the drawn rows have to
    say is geometric -- how many cells the picture is wide, and that the halves
    stayed halves. A photograph would say it too and could not be checked by
    reading the bytes.
    """
    row = (
        bytes([255, 0, 0]) * (MSX_FRAME_WIDTH // 2)
        + bytes([0, 0, 255]) * (MSX_FRAME_WIDTH - MSX_FRAME_WIDTH // 2)
    )
    return (
        200,
        {
            "loaded": True,
            "number": 1,
            "width": MSX_FRAME_WIDTH,
            "height": MSX_FRAME_HEIGHT,
            "mode": "SCREEN2",
            "cartridge": "split.rom",
            "rgb_base64": base64.b64encode(row * MSX_FRAME_HEIGHT).decode("ascii"),
        },
    )


MACHINE_LIVE_PATH = "/api/v1/lane-addons/live"


LiveMark = tuple[int, str]
LIVE_INCARNATION = "fixture-incarnation"


def machine_live_query(path: str) -> tuple[str, LiveMark | None]:
    """The machine a live read names and the mark (change count and
    incarnation) of the picture it already drew. #38733 takes the two
    together or not at all, and so does this fixture."""
    query = urllib.parse.parse_qs(urllib.parse.urlsplit(path).query, strict_parsing=True)
    if set(query) - {"source_kind", "since", "incarnation"} or len(query["source_kind"]) != 1:
        raise AssertionError(f"unexpected live query: {path}")
    since, incarnation = query.get("since"), query.get("incarnation")
    if (since is None) != (incarnation is None):
        raise AssertionError(f"since and incarnation must come together: {path}")
    mark = None if since is None or incarnation is None else (int(since[0]), incarnation[0])
    return query["source_kind"][0], mark


def with_live_activity(kind: str, answer: dict[str, object]) -> dict[str, object]:
    """The live route adds the DOS activity feed to every DOS answer, the
    no_machine one included (lib/server/server_routes_http_routes_lane_addons.ml
    [with_activity]); MSX answers carry none. Since #39286 the TUI refuses a
    DOS answer without the array, so a fixture that leaves it out never draws
    the DOS row."""
    if kind == "dos_capture":
        return dict(answer, activity=[])
    return answer


def machine_live_answer(
    kind: str, body: dict[str, object] | None, since: LiveMark | None, *,
    count: int, frame_number: int | None,
) -> HttpResponse:
    """What #38733's live route answers for one machine, from its current
    picture ([None]: no machine). [count] is the machine's change count, so a
    machine that did not move answers "unchanged"."""
    if body is None:
        return 200, with_live_activity(kind, {"source_kind": kind, "state": "no_machine"})
    marked = {"source_kind": kind, "change_count": count, "incarnation": LIVE_INCARNATION}
    if since == (count, LIVE_INCARNATION):
        return 200, with_live_activity(kind, dict(marked, state="unchanged"))
    answer: dict[str, object] = dict(marked, state="changed", screen={
        "format": "rgb8", "width": body["width"], "height": body["height"],
        "rgb_base64": body["rgb_base64"],
    })
    if frame_number is not None:
        answer["frame_number"] = frame_number
    return 200, with_live_activity(kind, answer)


def msx_live_fixture(frame: Callable[[], HttpResponse]) -> PathHttpResponse:
    """The live route over an MSX frame fixture; no DOS machine is loaded."""

    def resolve(path: str) -> HttpResponse:
        kind, since = machine_live_query(path)
        if kind == "dos_capture":
            return 200, with_live_activity(kind, {"source_kind": kind, "state": "no_machine"})
        if kind != "msx_capture":
            raise AssertionError(f"unexpected source kind: {kind}")
        status, body = frame()
        assert status == 200 and isinstance(body, dict), body
        number = int(body["number"])
        return machine_live_answer(kind, body, since, count=number, frame_number=number)

    return PathHttpResponse(resolve)


def msx_spectator_interaction(
    process: subprocess.Popen[bytes],
    master_fd: int,
    _slave_fd: int,
    output: bytearray,
    _base_path: str,
) -> None:
    """Watch a loaded machine, and read the shape of what was drawn.

    The screen paints the whole terminal itself, outside the frame presenter,
    so there is no frame-end marker to wait on -- the raw output carries the
    title, as the palette scenario already relies on.
    """
    read_available(master_fd, output)
    start = len(output)
    os.write(master_fd, b":go msx\r")
    # A loaded machine puts a watch row at the top of the menu (RFC-0439 3.7).
    wait_for_output(process, master_fd, output, b"watch MSX machine", start=start,
                    timeout=5.0)
    # Entering the spectator paints past the frame presenter too, so the wait
    # is on raw output; send_and_wait would starve on a frame-end marker that
    # this screen never writes.
    watched_from = len(output)
    os.write(master_fd, b"\r")
    # The footer is the last line the screen writes, so waiting on it is
    # waiting for every mosaic row to have been written. Waiting on the title
    # instead read rows that were still going out, and a half-written row is
    # narrower than the picture.
    wait_for_output(process, master_fd, output, b"Esc: back",
                    start=watched_from, timeout=5.0)
    watching = bytes(output)[watched_from:]
    if b"spectating the server" not in watching:
        raise AssertionError(f"the spectator title is missing: {watching[:200]!r}")

    drawn = [
        line
        for line in CSI_RE.sub(b"", watching).split(b"\n")
        if MSX_HALF_BLOCK in line
    ]
    if not drawn:
        raise AssertionError(f"the spectator drew no picture: {watching!r}")

    odd = [line for line in drawn if line.count(MSX_HALF_BLOCK) != MSX_EXPECTED_CELLS]
    if odd:
        raise AssertionError(
            "the picture is not the frame's shape: this frame asks for "
            f"{MSX_EXPECTED_CELLS} cells a row and "
            f"{[(line.count(MSX_HALF_BLOCK), line[:60]) for line in odd[:3]]!r}"
        )
    # Pillarboxed, not stretched: the leftover columns stay blank, and the
    # picture sits between them.
    if not all(line.startswith(b" ") for line in drawn):
        raise AssertionError(f"the picture was not centred: {drawn[0]!r}")

    # The halves stayed halves. Both colours are on every row, and the row's
    # own bytes say which came first.
    if MSX_LEFT_HALF not in watching or MSX_RIGHT_HALF not in watching:
        raise AssertionError(
            "a flat red half and a flat blue half did not both reach the "
            f"terminal: {watching[:400]!r}"
        )
    if watching.find(MSX_LEFT_HALF) > watching.find(MSX_RIGHT_HALF):
        raise AssertionError("the halves were drawn in the wrong order")

    send_and_wait(process, master_fd, output, b"\x1b", b"MASC Dashboard")
    os.write(master_fd, b"q")


def msx_size_interaction(
    process: subprocess.Popen[bytes],
    master_fd: int,
    _slave_fd: int,
    output: bytearray,
    _base_path: str,
) -> None:
    """The size keys step how much of the screen the picture takes.

    The footer carries the current size, so each key press is verified by the
    number that lands after it -- the fraction steps in eighths, so the marks
    are 100, 87, 75.
    """
    read_available(master_fd, output)
    start = len(output)
    os.write(master_fd, b":go msx\r")
    wait_for_output(process, master_fd, output, b"watch MSX machine", start=start,
                    timeout=5.0)
    watched_from = len(output)
    os.write(master_fd, b"\r")
    wait_for_output(process, master_fd, output, b"+/-: 100%", start=watched_from,
                    timeout=5.0)

    down_from = len(output)
    os.write(master_fd, b"-")
    wait_for_output(process, master_fd, output, b"+/-: 87%", start=down_from,
                    timeout=5.0)

    down_again = len(output)
    os.write(master_fd, b"-")
    wait_for_output(process, master_fd, output, b"+/-: 75%", start=down_again,
                    timeout=5.0)

    up_from = len(output)
    os.write(master_fd, b"+")
    wait_for_output(process, master_fd, output, b"+/-: 87%", start=up_from,
                    timeout=5.0)

    send_and_wait(process, master_fd, output, b"\x1b", b"MASC Dashboard")
    os.write(master_fd, b"q")


def run_msx_retained_regression(executable: str, *, retained_tick: bool = False) -> None:
    """Exercise retained Kitty pixels through the real TUI and private HTTP."""
    number = [1]
    changed = threading.Event()
    original = msx_loaded_frame_fixture()[1]
    pixel_responses: list[dict[str, object]] = []
    live_reads: list[LiveMark | None] = []

    live_fixture = msx_live_fixture(lambda: (200, original))

    def live(path: str) -> HttpResponse:
        kind, since = machine_live_query(path)
        if kind == "msx_capture":
            live_reads.append(since)
        return live_fixture.resolve(path)

    def tick(request_body: bytes = b""):
        number[0] += 1
        body = dict(original, number=number[0], change_count=number[0],
                    incarnation=LIVE_INCARNATION)
        if changed.is_set():
            body["rgb_base64"] = base64.b64encode(
                bytes([0, 255, 0]) * MSX_FRAME_WIDTH * MSX_FRAME_HEIGHT
            ).decode("ascii")
        if retained_tick:
            request = json.loads(request_body)
            assert request.get("pixel_response") == "retained", request
            encoded = body.pop("rgb_base64")
            reference = {
                "revision": hashlib.sha256(base64.b64decode(encoded)).hexdigest(),
                "width": body["width"], "height": body["height"],
            }
            retained = request.get("known_pixels") == reference
            body["pixels"] = dict(reference, kind="retained" if retained else "inline")
            if not retained:
                body["pixels"]["rgb_base64"] = encoded
            pixel_responses.append({
                "number": number[0], "kind": body["pixels"]["kind"],
                "revision": reference["revision"], "bytes": len(json.dumps(body)),
            })
        return 200, body

    def interact(process, master, _slave, output, _base):
        def footer_after(marker, start):
            wait_for_output(process, master, output, marker, start=start, timeout=5.0)
            marker_end = output.index(marker, start) + len(marker)
            footer = b"F8: disk"
            wait_for_output(process, master, output, footer,
                            start=marker_end, timeout=5.0)
            return output.index(footer, marker_end) + len(footer)

        def key(value, needle):
            start = len(output)
            os.write(master, value)
            wait_for_output(process, master, output, needle, start=start, timeout=5.0)
            return bytes(output[start:])

        key(b":go msx\r", b"watch MSX machine")
        first = key(b"\r", b"F6: save quick")
        assert b"f=24" in first, "Kitty path was not negotiated"
        start = len(output)
        target = number[0] + 3
        end = footer_after(f"frame {target} ".encode(), start)
        steady = bytes(output[start:end])
        assert b"f=24" not in steady, "unchanged pixels were retransmitted"
        assert b"\x1b[2J" not in steady, "unchanged pixels erased the display"
        assert b"a=d" not in steady, "unchanged pixels deleted the image"
        if retained_tick:
            assert pixel_responses[0]["kind"] == "inline", pixel_responses
            assert sum(row["kind"] == "retained" for row in pixel_responses) >= 2, pixel_responses
            assert all(row["bytes"] < pixel_responses[0]["bytes"]
                       for row in pixel_responses if row["kind"] == "retained")
        before_change = len(pixel_responses)
        start = len(output)
        changed.set()
        end = footer_after(b"i=32,p=1,C=1", start)
        replacement = bytes(output[start:end])
        assert b"f=24" in replacement, "changed pixels were not transmitted"
        if retained_tick:
            replacements = pixel_responses[before_change:]
            assert any(row["kind"] == "inline"
                       and row["revision"] != pixel_responses[0]["revision"]
                       for row in replacements), replacements
        assert b"\x1b[2J" not in replacement, "replacement erased the display"
        start = len(output)
        os.write(master, b"-")
        end = footer_after(b"+/-: 87%", start)
        resized = bytes(output[start:end])
        assert b"d=I,i=32" in resized, "resize retained the old placement"
        assert b"f=24" in resized, "resize did not place pixels again"
        exited = key(b"\x1b", b"MASC Dashboard")
        assert b"d=I,i=32" in exited, "exit left the image behind"
        # Ticks named the cartridge, and a live read of the same machine keeps
        # that name, so the reopened menu's watch row says it.
        key(b":go msx\r", b"watch split.rom")
        reopened = key(b"\r", b"F6: save quick")
        assert b"f=24" in reopened, "reopening reused a deleted image"
        # The next explicit read starts at the mark of the tick picture, and
        # keeps its title metadata while the live route returns pixels only.
        before_key = len(live_reads)
        after_key = key(b"z", b"F6: save quick")
        assert any(mark is not None for mark in live_reads[before_key:]), live_reads
        assert b"SCREEN2" in after_key and b"split.rom" in after_key, after_key[:250]
        print(f"MSX PTY wire: first={len(first)} steady_three_polls={len(steady)} "
              f"replacement={len(replacement)} bytes", flush=True)
        key(b"\x1b", b"MASC Dashboard")
        os.write(master, b"q")

    run_terminal_scenario(
        executable,
        description=("MSX tick sends a reference for pixels the TUI already holds" if retained_tick
                     else "MSX retains Kitty pixels between live polls"),
        interact=interact, preload_input=GRAPHICS_SUPPORTED_REPLY,
        http_fixtures={MACHINE_LIVE_PATH: PathHttpResponse(live),
                       "/api/v1/msx/tick": RequestHttpResponse(tick) if retained_tick else tick},
    )
    if retained_tick:
        print(json.dumps({"msx_tick_pixels": pixel_responses}), flush=True)


def run_msx_background_poll_regression(executable: str) -> None:
    """A pending mutation must not own the terminal's input loop."""
    original = msx_loaded_frame_fixture()[1]
    late = dict(original, number=999, change_count=999,
                incarnation=LIVE_INCARNATION, rgb_base64=base64.b64encode(
        bytes([0, 255, 0]) * MSX_FRAME_WIDTH * MSX_FRAME_HEIGHT).decode("ascii"))
    pending = GatedHttpResponse((200, late), hold_seconds=20.0)
    failed = GatedHttpResponse((503, {"error": "tick unavailable"}), hold_seconds=20.0)
    calls = []
    get_frames = []

    def frame():
        get_frames.append(len(get_frames) + 1)
        return 200, dict(original, number=100 + len(get_frames))

    def tick(body):
        calls.append(json.loads(body))
        if len(calls) == 1:
            return pending()
        if len(calls) == 2:
            return failed()
        return 503, {"error": "unexpected automatic mutation retry"}

    def kitty_rgb_transfers(wire):
        transfers = []
        chunks = None
        geometry = None
        for match in re.finditer(rb"\x1b_G([^;]*);([^\x1b]*)\x1b\\", wire):
            fields = dict(field.split(b"=", 1) for field in match[1].split(b",") if b"=" in field)
            if fields.get(b"f") == b"24":
                assert chunks is None, "new image interrupted a pending transfer"
                chunks = []
                geometry = (int(fields[b"s"]), int(fields[b"v"]))
            if chunks is not None:
                chunks.append(match[2])
                if fields.get(b"m", b"0") == b"0":
                    rgb = base64.b64decode(b"".join(chunks), validate=True)
                    assert len(rgb) == geometry[0] * geometry[1] * 3
                    transfers.append((geometry, rgb))
                    chunks = None
        assert chunks is None, "incomplete Kitty RGB transfer"
        return transfers

    def interact(process, master, slave, output, _base):
        def await_marker(marker, start):
            wait_for_output(process, master, output, marker, start=start, timeout=2.0)

        def key(keys, marker):
            start = len(output)
            os.write(master, keys)
            await_marker(marker, start)
            return start

        def observe_for(seconds):
            deadline = time.monotonic() + seconds
            while time.monotonic() < deadline:
                read_available(master, output)
                assert process.poll() is None, "TUI exited during observation"
                select.select([master], [], [], min(0.05, max(0, deadline - time.monotonic())))
            read_available(master, output)

        try:
            key(b":go msx\r", b"watch MSX machine")
            key(b"\r", b"F8: disk")
            assert wait_for_fixture_event(process, master, output, pending.requested, timeout=5.0)
            assert not pending.completed.is_set(), "fixture did not hold the tick"
            # Scaling is a keyboard resize, and SIGWINCH is a physical resize.
            start = key(b"-", b"+/-: 87%")
            await_marker(b"F8: disk", start)
            assert not pending.completed.is_set(), "resize waited for the HTTP response"
            start = len(output)
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 32, 110, 0, 0))
            os.kill(process.pid, signal.SIGWINCH)
            await_marker(b"F8: disk", start)
            assert not pending.completed.is_set(), "terminal resize waited for the HTTP response"
            key(b"\x1b", b"MASC Dashboard")
            assert not pending.completed.is_set(), "Esc waited for the HTTP response"
            observe_for(0.8)  # More than two 0.3-second spectator poll intervals.
            assert len(calls) == 1, f"pending/closed view issued more ticks: {len(calls)}"
            before_get = len(get_frames)
            key(b":go msx\r", b"watch MSX machine")
            assert len(get_frames) > before_get, "reopening skipped fresh observation"
            start = key(b"\r", b"F8: disk")
            assert b"f=24" in bytes(output[start:]), "fresh reopen did not restore image"
            expected_frame = 100 + len(get_frames)
            assert f"frame {expected_frame} ".encode() in bytes(output[start:])
            observe_for(0.8)
            assert not pending.completed.is_set(), "old tick finished before reopened-view test"
            assert len(calls) == 1, "reopening issued another mutation while one was pending"
            # The view is open again: msx_open alone cannot suppress this old
            # reply. Only the request's captured view identity distinguishes it.
            start = len(output)
            pending.release.set()
            assert wait_for_fixture_event(process, master, output, pending.completed, timeout=3.0)
            assert wait_for_fixture_event(process, master, output, failed.requested, timeout=5.0)
            # The next tick entering its gate proves the old completion was
            # consumed, while preventing another response from hiding damage.
            read_available(master, output)
            stale = bytes(output[start:])
            assert b"frame 999 " not in stale, "late metadata replaced the reopened snapshot"
            expected_pixels = ((original["width"], original["height"]),
                               base64.b64decode(original["rgb_base64"]))
            assert all(pixels == expected_pixels for pixels in kitty_rgb_transfers(stale)), "late green pixels replaced the reopened snapshot"
            assert len(calls) == 2, "settlement did not release exactly one pending slot"
            start = len(output)
            failed.release.set()
            await_marker(b"Refresh outcome unknown; reopen", start)
            observe_for(0.8)
            failure_output = bytes(output[start:])
            assert len(calls) == 2, f"failed mutation retried automatically: {len(calls)}"
            # The notice adds a header row, legitimately relocating/repainting
            # the image. Verify its contents and frame, not absence of commands.
            repaints = kitty_rgb_transfers(failure_output)
            assert repaints, "notice relayout did not repaint the cached image"
            expected_pixels = ((original["width"], original["height"]),
                               base64.b64decode(original["rgb_base64"]))
            assert all(pixels == expected_pixels for pixels in repaints), "failure repaint changed cached RGB"
            assert f"frame {expected_frame} ".encode() in failure_output, "failure lost cached frame identity"
            assert b"frame 999 " not in failure_output, "failure resurrected stale response"
            key(b"\x1b", b"MASC Dashboard")
            before_get = len(get_frames)
            key(b":go msx\r", b"watch MSX machine")
            assert len(get_frames) > before_get, "failure recovery skipped fresh GET"
            assert len(calls) == 2, "menu entry advanced the machine"
            key(b"\x1b", b"F8: disk")
            key(b"\x1b", b"MASC Dashboard")
            os.write(master, b"q")
            print(json.dumps({"result": "PASS", "tick_calls": len(calls),
                "fresh_gets": len(get_frames), "pending_resize_and_escape": True,
                "late_frame_discarded": True, "failure_retry_suppressed": True}), flush=True)
        finally:
            pending.release.set()
            failed.release.set()

    run_terminal_scenario(executable, description="MSX asynchronous poll preserves terminal input",
        interact=interact, preload_input=GRAPHICS_SUPPORTED_REPLY,
        http_fixtures={MACHINE_LIVE_PATH: msx_live_fixture(frame),
                       "/api/v1/msx/tick": RequestHttpResponse(tick)})


def run_msx_size_regression(executable: str) -> None:
    run_terminal_scenario(
        executable,
        description="the size keys step the spectator's picture",
        interact=msx_size_interaction,
        http_fixtures={MACHINE_LIVE_PATH: msx_live_fixture(msx_loaded_frame_fixture)},
    )


def run_msx_spectator_regression(executable: str) -> None:
    run_terminal_scenario(
        executable,
        description="the spectator draws the machine's frame in its own shape",
        interact=msx_spectator_interaction,
        http_fixtures={MACHINE_LIVE_PATH: msx_live_fixture(msx_loaded_frame_fixture)},
    )


DOS_FRAME_WIDTH = 640
DOS_FRAME_HEIGHT = 480
DOS_RED = b"38;2;255;0;0"
DOS_BLUE = b"38;2;0;0;255"


def dos_flat_frame(rgb: bytes) -> dict[str, object]:
    return {
        "width": DOS_FRAME_WIDTH,
        "height": DOS_FRAME_HEIGHT,
        "rgb_base64": base64.b64encode(rgb * DOS_FRAME_WIDTH * DOS_FRAME_HEIGHT).decode("ascii"),
    }


def assert_dos_spectator_posts_are_setup(posts: HttpRequests) -> None:
    """Observer setup is allowed; every other POST violates spectating."""
    for path, body in posts:
        if path == "/mcp":
            try:
                message = json.loads(body)
            except (json.JSONDecodeError, UnicodeDecodeError) as error:
                raise AssertionError("DOS spectator emitted malformed MCP JSON") from error
            if (
                isinstance(message, dict)
                and message.get("jsonrpc") == "2.0"
                and message.get("method") in ("initialize", "notifications/initialized")
            ):
                continue
        raise AssertionError(f"DOS spectator emitted a non-setup POST: {path!r} {body!r}")


def run_dos_live_regression(executable: str) -> None:
    """Watch the DOS machine through the live route (RFC machine-spectating
    stage 3). The menu offers it, the picture is drawn in its own shape, an
    unchanged machine redraws nothing unless activity changes, a key reaches
    no machine, and a changed machine is drawn at its new counter."""
    picture: dict[str, Any] = {"frame": dos_flat_frame(bytes([255, 0, 0])), "steps": 100}
    activity: list[dict[str, object]] = []
    dos_reads: list[LiveMark | None] = []
    posts: HttpRequests = []
    held: dict[str, Any] = {"armed": False, "entered": threading.Event(),
                            "release": threading.Event()}
    fail_reads = threading.Event()
    first_read = GatedHttpResponse(
        machine_live_answer("dos_capture", picture["frame"], None,
                            count=999, frame_number=None), hold_seconds=20.0)

    def resolve(path: str) -> HttpResponse:
        kind, since = machine_live_query(path)
        if kind == "msx_capture":
            return 200, {"source_kind": kind, "state": "no_machine"}
        if kind != "dos_capture":
            raise AssertionError(f"unexpected source kind: {kind}")
        dos_reads.append(since)
        if fail_reads.is_set():
            return 503, {"error": "DOS fixture unavailable"}
        if len(dos_reads) == 1:
            return first_read()
        if held["armed"]:
            # Hold this one read until the scenario has pressed a key.
            held["armed"] = False
            held["entered"].set()
            held["release"].wait(timeout=10.0)
        status, answer = machine_live_answer(
            kind, picture["frame"], since,
            count=int(picture["steps"]), frame_number=None)
        answer["activity"] = activity
        return status, answer

    def interact(process, master, _slave, output, _base):
        nonlocal activity
        def key(value, needle):
            start = len(output)
            os.write(master, value)
            wait_for_output(process, master, output, needle, start=start, timeout=5.0)
            return start

        def observe_for(seconds):
            deadline = time.monotonic() + seconds
            while time.monotonic() < deadline:
                read_available(master, output)
                assert process.poll() is None, "TUI exited during observation"
                select.select([master], [], [], min(0.05, max(0, deadline - time.monotonic())))
            read_available(master, output)

        try:
            key(b":go msx\r", MSX_MENU_TITLE)
            assert wait_for_fixture_event(process, master, output,
                                          first_read.requested, timeout=5.0)
            assert not first_read.completed.is_set(), "DOS menu read did not remain pending"
            key(b"j", b"Esc:back")
            assert not first_read.completed.is_set(), "menu key waited for DOS pixels"
            key(b"\x1b", b"MASC Dashboard")
            reopened_from = key(b":go msx\r", MSX_MENU_TITLE)
            wait_for_output(process, master, output, b"watch DOS machine",
                            start=reopened_from, timeout=5.0)
            assert len(dos_reads) == 2, "reopened menu waited for or duplicated the old DOS read"
            assert not first_read.completed.is_set(), "old DOS read completed before the reopen check"
        finally:
            first_read.release.set()
        assert wait_for_fixture_event(process, master, output,
                                      first_read.completed, timeout=5.0)
        observe_for(0.2)
        assert len(dos_reads) == 2, "stale DOS completion started another menu read"
        # The delayed old response says change 999; the fresh reopened view
        # says 100. The spectator assertion below catches an old response
        # that overwrites the fresh view even if no extra HTTP read was made.
        start = key(b"\r", b"Esc: back  +/-: 100%")
        watching = bytes(output[start:])
        if b"DOS \xe2\x80\x94 change 100" not in watching:
            raise AssertionError(f"the DOS title is missing: {watching[:300]!r}")
        if b"F6" in watching:
            raise AssertionError("the DOS footer offers MSX keys")
        drawn = [line for line in CSI_RE.sub(b"", watching).split(b"\n")
                 if MSX_HALF_BLOCK in line]
        # 640x480 has the MSX frame's 4:3 shape, so it scales down to the
        # same 74 cells in this 100x30 window.
        odd = [line.count(MSX_HALF_BLOCK) for line in drawn
               if line.count(MSX_HALF_BLOCK) != MSX_EXPECTED_CELLS]
        if not drawn or odd:
            raise AssertionError(f"the DOS picture is not its own shape: {odd[:3]!r}")
        if DOS_RED not in watching:
            raise AssertionError("the red DOS picture was not drawn")

        # Unchanged: the reads go on, each at the drawn counter, and nothing
        # is drawn again.
        reads_before = len(dos_reads)
        still_from = len(output)
        observe_for(1.2)
        still = dos_reads[reads_before:]
        if len(still) < 2 or any(since != (100, LIVE_INCARNATION) for since in still):
            raise AssertionError(f"an unchanged machine was not read at its counter: {still!r}")
        if bytes(output[still_from:]):
            raise AssertionError(
                f"an unchanged answer redrew the screen: {bytes(output[still_from:])[:200]!r}")

        # A pass changes the sidebar without changing DOS pixels. The live
        # answer remains `unchanged`, but the spectator must show the event.
        activity = [{"at": 1790650000, "who": "guest", "action": "pass -> keeper"}]
        activity_from = len(output)
        wait_for_output(process, master, output, b"guest pass", start=activity_from,
                        timeout=5.0)
        wait_for_output(process, master, output, b"Esc: back", start=activity_from,
                        timeout=5.0)
        activity_drawn = bytes(output[activity_from:])
        if b"change 100" not in activity_drawn:
            raise AssertionError("activity-only repaint lost the current DOS picture")
        still_from = len(output)
        observe_for(0.8)
        if bytes(output[still_from:]):
            raise AssertionError("identical activity redrew an unchanged DOS screen")

        # A key is the spectator's, not a machine's: it repaints and posts nothing.
        key(b"x", b"Esc: back  +/-: 100%")
        pressed = [path for path, _ in posts if path.startswith("/api/v1/msx/")]
        if pressed:
            raise AssertionError(f"a key on the DOS screen reached the MSX machine: {pressed!r}")

        # The machine moved: the next read carries the new picture. That read
        # is held while a key is pressed on the DOS screen. The key must not
        # disown the read in flight: its answer is the one drawn, and no
        # second read starts while it is held (a disowned read is dropped and
        # re-asked, so a steady stream of keys would freeze the picture).
        changed_from = len(output)
        picture["frame"] = dos_flat_frame(bytes([0, 0, 255]))
        picture["steps"] = 200
        reads_before_change = len(dos_reads)
        held["armed"] = True
        try:
            assert wait_for_fixture_event(process, master, output, held["entered"], timeout=5.0)
            key(b"x", b"Esc: back  +/-: 100%")
            observe_for(0.8)  # more than two poll intervals
            # The key repainted the old picture; what follows is the answer.
            changed_from = len(output)
        finally:
            held["release"].set()
        wait_for_output(process, master, output, b"change 200", start=changed_from, timeout=5.0)
        # The held read asked at 100. Once its answer is drawn the next poll
        # asks at 200, and that poll can already be under way by the time
        # "change 200" is on screen, so a read at 200 says nothing about the
        # key. A disowned read is re-asked at the counter still drawn -- 100
        # -- so the reads at 100 are what tell the two apart: exactly one,
        # and it is the first.
        after_change = dos_reads[reads_before_change:]
        at_old = [since for since in after_change if since == (100, LIVE_INCARNATION)]
        rest = [since for since in after_change if since != (100, LIVE_INCARNATION)]
        if (len(at_old) != 1 or after_change[0] != (100, LIVE_INCARNATION)
                or any(since != (200, LIVE_INCARNATION) for since in rest)):
            raise AssertionError(
                f"a key on the DOS screen disowned the read in flight: {after_change!r}")
        wait_for_output(process, master, output, b"Esc: back", start=changed_from, timeout=5.0)
        changed = bytes(output[changed_from:])
        if DOS_BLUE not in changed or DOS_RED in changed:
            raise AssertionError("the changed DOS picture was not the new one")
        observe_for(0.8)
        if any(since != (200, LIVE_INCARNATION) for since in dos_reads[-2:]):
            raise AssertionError(f"reads after the change did not ask at 200: {dos_reads[-4:]!r}")

        key(b"\x1b", b"MASC Dashboard")
        # The palette must reach a fresh live answer, not only draw an empty
        # spectator footer or reuse the picture from the MSX menu path.
        picture["steps"] = 300
        direct_from = key(b":go dos\r", b"DOS \xe2\x80\x94 change 300")
        wait_for_output(process, master, output, b"Esc: back", start=direct_from,
                        timeout=5.0)
        direct = bytes(output[direct_from:])
        if DOS_BLUE not in direct or b"MSX \xe2\x80\x94 pick a game" in direct:
            raise AssertionError("go DOS did not draw its fresh live picture directly")
        # Ordinary game input, Enter, and MSX save/restore/media keys must
        # remain spectator input on this new entry path as well.
        for spectator_key in (b"x", b"\r", b"\x1b[17~", b"\x1b[18~", b"\x1b[19~"):
            key(spectator_key, b"Esc: back")
        key(b"\x1b", b"MASC Dashboard")
        # A failed re-entry read is not an empty activity feed. Keep the
        # previously observed pass beside the explicit read failure.
        fail_reads.set()
        failed_from = key(b":go dos\r", b"could not read the machine")
        failure_title = output.rfind(b"could not read the machine", failed_from)
        wait_for_output(process, master, output, b"Esc: back", start=failure_title,
                        timeout=5.0)
        if b"guest pass" not in bytes(output[failure_title:]):
            raise AssertionError("failed DOS re-entry discarded previously observed activity")
        key(b"\x1b", b"MASC Dashboard")
        os.write(master, b"q")
        print(json.dumps({"dos_reads": len(dos_reads),
                          "unchanged_reads": len(still)}), flush=True)

    run_terminal_scenario(
        executable,
        description="the DOS machine is watched through the live route",
        interact=interact,
        http_fixtures={MACHINE_LIVE_PATH: PathHttpResponse(resolve)},
        http_requests=posts,
    )
    # Check after fixture shutdown as well, so a completed POST cannot race
    # the final terminal assertion. Startup may initialize the MCP observer,
    # but neither tool calls nor machine input/control/invite POSTs are allowed.
    assert_dos_spectator_posts_are_setup(posts)


def run_msx_palette_regression(executable: str) -> None:
    """The command palette opens the MSX screen by name.

    [&] opens the MSX spectator, but a key is found only by someone who
    already knows it; the palette is where an operator looks for a screen by
    name. This drives the typed path end to end: `:` then `go msx` must take
    the terminal over with the MSX screen, and Esc must hand it back.

    The harness serves no machine and no cartridges, so the screen opens on
    the load menu's own title (RFC-0439 3.7: the screen opens the menu
    first). That line is the proof the palette reached the screen at all; the
    Overview header afterwards is the proof Esc left it.
    """

    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        # The MSX screen paints the whole terminal itself, outside the frame
        # presenter, so no frame-end marker follows it. Wait on the raw
        # output for its title line, the way the Browser screenshot
        # regression waits for its overlay.
        read_available(master_fd, output)
        start = len(output)
        os.write(master_fd, b":go msx\r")
        wait_for_output(
            process,
            master_fd,
            output,
            MSX_MENU_TITLE,
            start=start,
            timeout=3.0,
        )
        # Esc hands the terminal back to the presenter, whose frame ends the
        # normal way, so the plain helper serves from here on.
        send_and_wait(process, master_fd, output, b"\x1b", b"MASC Dashboard")
        send_and_wait(
            process, master_fd, output, b"q", b"q: press again to quit"
        )

    run_terminal_scenario(
        executable,
        description="the palette opens the MSX screen by name",
        interact=interact,
    )
