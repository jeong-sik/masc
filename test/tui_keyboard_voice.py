from __future__ import annotations

import json
import os
import select
import subprocess
import sys
import tempfile
import time
from pathlib import Path

from tui_keyboard_harness import (
    COMPOSER_FOCUSED,
    CSI_RE,
    FRAME_END,
    HttpFixtures,
    HttpRequests,
    Interaction,
    RequestHttpResponse,
    WorkspaceSetup,
    drain_until_quiet,
    escape_to_keeper_detail,
    overview_event_http_fixtures,
    press_and_settle,
    read_available,
    run_terminal_scenario,
    screen_text,
    select_keeper_row,
    send_and_wait,
    tab_until,
    wait_for_http_request,
    wait_for_output,
    write_all,
)

SPOKEN_TRANSCRIPT = "a sentence the fake whisper heard"

# A microphone that says one thing: room noise, a second of a 440 Hz tone at
# real-time rate, then room noise until the capture stops it. The capture
# watches the growing file, so the rate is what lets its trailing-silence wait
# see an end. SIGTERM is how the capture stops sox; the header is filled then.
FAKE_REC = """#!{python}
import math, random, signal, struct, sys, time
args = sys.argv[1:]
out = args[args.index('signed-integer') + 1]
rate = 16000
def header(n):
    return (b'RIFF' + struct.pack('<I', 36 + n) + b'WAVEfmt '
            + struct.pack('<IHHIIHH', 16, 1, 1, rate, rate * 2, 2, 16) + b'data' + struct.pack('<I', n))
def noise(frames):
    return b''.join(struct.pack('<h', random.randint(-40, 40)) for _ in range(frames))
if 'trim' in args:
    seconds = float(args[args.index('trim') + 2])
    data = noise(int(seconds * rate))
    open(out, 'wb').write(header(len(data)) + data)
    sys.exit(0)
tone = b''.join(struct.pack('<h', int(8000 * math.sin(2 * math.pi * 440 * i / rate))) for i in range(rate))
f = open(out, 'wb')
f.write(header(0))
written = 0
def finish(*_):
    f.seek(0); f.write(header(written)); f.close(); sys.exit(0)
signal.signal(signal.SIGTERM, finish)
start = time.monotonic()
for block in (noise(rate // 2), tone):
    for i in range(0, len(block), 3200):
        piece = block[i:i + 3200]
        f.write(piece); f.flush(); written += len(piece)
        time.sleep(max(0, start + written / (rate * 2) - time.monotonic()))
while True:
    piece = noise(rate // 10)
    f.write(piece); f.flush(); written += len(piece)
    time.sleep(max(0, start + written / (rate * 2) - time.monotonic()))
"""


def seed_send_on_stop_workspace(fake_bin: str) -> WorkspaceSetup:
    def seed(base_path: str) -> None:
        config = Path(base_path) / ".masc" / "config"
        config.mkdir(parents=True, exist_ok=True)
        (config / "runtime.toml").write_text(
            "[voice.stt]\n"
            f'default_model = "{fake_bin}/model.bin"\n'
            "send_on_stop = true\n"
            "\n"
            "[[voice.stt.endpoints]]\n"
            'id = "whisper-local"\n'
            'kind = "whisper_cli"\n'
            "enabled = true\n"
            f'command = "{fake_bin}/whisper-cli"\n',
            encoding="utf-8",
        )

    return seed


def wait_for_spoken_send(
    process: subprocess.Popen[bytes],
    master_fd: int,
    output: bytearray,
    requests: HttpRequests,
) -> None:
    # Half a second of room, a second of tone, the two-second trailing wait,
    # then the fake transcriber: well inside the budget.
    deadline = time.monotonic() + 20.0
    while not any(path == "/api/v1/keepers/chat/stream" for path, _ in requests):
        read_available(master_fd, output)
        if process.poll() is not None:
            raise AssertionError("TUI exited before the spoken draft was sent")
        if time.monotonic() > deadline:
            plain = CSI_RE.sub(b"", bytes(output[-4000:]))
            raise AssertionError(f"send_on_stop left the transcript in the draft: {plain!r}")
        select.select([master_fd], [], [], 0.05)
    body = next(body for path, body in requests if path == "/api/v1/keepers/chat/stream")
    message = json.loads(body).get("message")
    if message != SPOKEN_TRANSCRIPT:
        raise AssertionError(f"the keeper was sent {message!r}, not the transcript")


def send_on_stop_from_the_composer_row_interaction(requests: HttpRequests) -> Interaction:
    """The composer row under every other surface sends a capture the same way."""

    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        send_and_wait(process, master_fd, output, b"3", b"MASC Keepers")
        select_keeper_row(process, master_fd, output, b"alpha")
        send_and_wait(process, master_fd, output, b"i", COMPOSER_FOCUSED)
        os.write(master_fd, b"\x19")
        wait_for_spoken_send(process, master_fd, output, requests)
        # A sent message brings the chat pane forward, as Enter on the row does.
        wait_for_output(
            process, master_fd, output, b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat",
            start=0, timeout=3.0,
        )
        escape_to_keeper_detail(process, master_fd, output, name=b"alpha")
        os.write(master_fd, b"q")

    return interact


def send_on_stop_from_the_chat_pane_interaction(requests: HttpRequests) -> Interaction:
    """[voice.stt].send_on_stop sends what a capture heard from the chat pane.

    The chat pane is where an operator types most, and it has its own editor:
    the composer row is never focused there. A transcript that was handed to
    the row's send key from this pane stayed in the draft and nothing was
    sent -- measured 2026-09-13 against a live keeper with send_on_stop on.
    """

    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        send_and_wait(process, master_fd, output, b"3", b"MASC Keepers")
        select_keeper_row(process, master_fd, output, b"alpha")
        send_and_wait(
            process, master_fd, output, b"\r", b"Keepers \xe2\x96\xb8 \x1b[1malpha"
        )
        send_and_wait(
            process, master_fd, output, b"m", b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat"
        )
        os.write(master_fd, b"\x19")
        wait_for_spoken_send(process, master_fd, output, requests)
        escape_to_keeper_detail(process, master_fd, output, name=b"alpha")
        os.write(master_fd, b"q")

    return interact


def run_send_on_stop_regression(executable: str) -> None:
    with tempfile.TemporaryDirectory(prefix="masc-tui-voice-bin-") as fake_bin:
        scripts = {
            "rec": FAKE_REC.format(python=sys.executable),
            "play": "#!/bin/sh\nexit 0\n",
            "whisper-cli": f"#!/bin/sh\necho '{SPOKEN_TRANSCRIPT}'\n",
        }
        for name, body in scripts.items():
            path = Path(fake_bin) / name
            path.write_text(body, encoding="utf-8")
            path.chmod(0o755)
        for description, interaction in (
            ("send_on_stop sends a capture from the chat pane",
             send_on_stop_from_the_chat_pane_interaction),
            ("send_on_stop sends a capture from the composer row",
             send_on_stop_from_the_composer_row_interaction),
        ):
            requests: HttpRequests = []
            run_terminal_scenario(
                executable,
                description=description,
                interact=interaction(requests),
                http_fixtures={
                    "/api/v1/keepers/chat/stream": (
                        503,
                        {"error": "stop after the spoken request capture"},
                    )
                },
                http_requests=requests,
                prepare_workspace=seed_send_on_stop_workspace(fake_bin),
                # Only the stand-ins: a real sox on this machine would open the
                # microphone and the speakers.
                extra_env={"PATH": f"{fake_bin}:/usr/bin:/bin"},
            )


# The voice setup wizard, drawn in a terminal. Its rules live in Voice_wizard
# and its session in Masc_tui_types, both tested where they live, and a
# structural suite asserts the call sites exist. None of those can say the box
# appears, or that the keys reach it through a real terminal -- which is the one
# claim the runbook could not make.
VOICE_SETUP_FIXTURE = {
    "revision": "fixture-voice-revision",
    "tts": {
        "default_model": "eleven_multilingual_v2",
        "default_voice": "fixture-voice-id",
        "agent_voices": {},
        "endpoints": [
            {
                "id": "fixture-elevenlabs",
                "kind": "elevenlabs_direct",
                "enabled": True,
                "api_key_env": "ELEVENLABS_API_KEY",
                "address": "https://api.elevenlabs.io/v1",
            },
            # Both addresses, the way a voice_mcp entry may carry them. The
            # transport calls mcp_url; the server says so in "address".
            {
                "id": "fixture-mcp",
                "kind": "voice_mcp",
                "enabled": True,
                "base_url": "http://127.0.0.1:9100",
                "mcp_url": "http://127.0.0.1:9200/mcp",
                "address": "http://127.0.0.1:9200/mcp",
            },
        ],
    },
    "stt": {
        "default_model": "whisper-1",
        "endpoints": [
            {
                "id": "fixture-whisper",
                "kind": "openai_compat",
                "enabled": True,
                "base_url": "http://127.0.0.1:2022/v1",
                "address": "http://127.0.0.1:2022/v1",
            }
        ],
    },
}

VOICE_CONFIG_FIXTURE = {
    "status": "loaded",
    "tts": {
        "default_model": "eleven_multilingual_v2",
        "default_voice": "fixture-voice-id",
        "active_endpoint": {
            "configured": True,
            "enabled": True,
            "fallback_configured": False,
        },
    },
    "stt": {
        "default_model": "whisper-1",
        "active_endpoint": {
            "configured": True,
            "enabled": True,
            "fallback_configured": True,
        },
    },
}


def voice_wizard_http_fixtures() -> HttpFixtures:
    fixtures = overview_event_http_fixtures()
    fixtures["/api/v1/voice/config"] = (200, VOICE_CONFIG_FIXTURE)
    # One path, two meanings: the pane reads it and the wizard writes to it.
    # The fixture table is keyed by path alone, so the body tells them apart --
    # a read arrives with none.
    fixtures["/api/v1/voice/setup"] = RequestHttpResponse(
        lambda body: (200, {"revision": "fixture-voice-revision-2"})
        if body
        else (200, VOICE_SETUP_FIXTURE)
    )
    return fixtures


def open_the_voice_pane(
    process: "subprocess.Popen[bytes]", master_fd: int, output: bytearray
) -> bytes:
    """Walk the Config pane strip to voice, and answer the frame it landed on.

    [p] cycles seven panes and voice is last, so the walk is bounded by the
    strip rather than by a fixed count: a pane inserted ahead of voice would
    otherwise leave this pressing one short.
    """
    tab_until(process, master_fd, output, b"MASC System")
    for _ in range(8):
        read_available(master_fd, output)
        start = len(output)
        os.write(master_fd, b"p")
        wait_for_output(process, master_fd, output, FRAME_END, start=start, timeout=3.0)
        # The pane switch loads over HTTP, so later frames carry what the first
        # does not. Judged after the frames stop, the way tab_until judges a
        # surface switch.
        drain_until_quiet(process, master_fd, output)
        plain = CSI_RE.sub(b"", bytes(output[start:]))
        if b"MASC Voice" in plain:
            return plain
    raise AssertionError("p never reached the voice pane")


def voice_wizard_interaction(requests: HttpRequests) -> Interaction:
    """The pane names its endpoints, e opens the wizard, and the questions walk.

    What this holds that the unit suites cannot: that the box is drawn at all,
    that the closed-set steps move under the arrow keys, that typing lands in
    the field and then in the draft summary, and that Esc leaves without a
    write -- no save route is in the fixtures, so a wizard that posted on Esc
    would be seen here as a failed request rather than silence.
    """

    def interact(
        process: "subprocess.Popen[bytes]",
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        # The admin read is what names endpoints; the public route answers
        # three booleans and no identity, so these two ids are proof the pane
        # is drawing the read the wizard was built for.
        listing = open_the_voice_pane(process, master_fd, output)
        for needle in (b"fixture-elevenlabs", b"fixture-whisper", b"elevenlabs_direct"):
            if needle not in listing:
                raise AssertionError(f"the voice pane omitted {needle!r}")
        # The address drawn is the one the server resolved. The pane used to
        # prefer base_url and showed an address a voice_mcp endpoint is never
        # called at.
        drain_until_quiet(process, master_fd, output)
        screen = screen_text(bytes(output))
        if b"127.0.0.1:9200/mcp" not in screen or b"127.0.0.1:9100" in screen:
            raise AssertionError(f"the voice_mcp row did not show its mcp_url: {screen!r}")

        def expect(frame: bytes, needle: bytes, what: str) -> None:
            if needle not in frame:
                raise AssertionError(f"{what}: {needle!r} missing from {frame!r}")

        opened = press_and_settle(process, master_fd, output, b"e")
        expect(opened, b"step 1/7", "the wizard did not open on the first of seven")
        expect(opened, b"setup", "the wizard title did not draw")
        expect(opened, b"speech out", "the first question did not show its answer")

        # A closed set walks under the arrows. Over and back, so a binding that
        # moves one way only is visible.
        expect(
            press_and_settle(process, master_fd, output, b"\x1b[C"),
            b"speech in",
            "the side did not switch under the right arrow",
        )
        expect(
            press_and_settle(process, master_fd, output, b"\x1b[C"),
            b"speech out",
            "the side did not switch back",
        )

        # Enter walks forward. Provider is the second closed set.
        provider = press_and_settle(process, master_fd, output, b"\r")
        expect(provider, b"step 2/7", "enter did not reach the provider step")
        expect(provider, b"elevenlabs", "the provider step showed no provider")

        # Typing reaches the field, and leaving the step reaches the draft.
        expect(
            press_and_settle(process, master_fd, output, b"\r"),
            b"step 3/7",
            "enter did not reach the name step",
        )
        # A letter is a full repaint, so a word costs as many repaints as it
        # has letters; the default settle cap cut this one at nine.
        # The name carries an [i] on purpose. The composer used to see every
        # key before the field did and claimed [i] as "focus the composer", so
        # this name reached the screen as "pty-endpo" and "nt" went into a
        # keeper message.
        typed = press_and_settle(process, master_fd, output, b"pty-endpoint", cap=15.0)
        expect(typed, b"pty-endpoint", "the name did not reach the field")

        credential = press_and_settle(process, master_fd, output, b"\r")
        expect(credential, b"step 4/7", "enter did not reach the credential step")
        # The draft summary is the only place the name can appear now: the
        # field it was typed into belongs to the step just left.
        expect(credential, b"pty-endpoint", "the name did not reach the draft summary")
        expect(
            credential,
            b"ELEVENLABS_API_KEY",
            "the credential step lost its prefilled variable",
        )

        # Up goes back and finds what was typed.
        back = press_and_settle(process, master_fd, output, b"\x1b[A")
        expect(back, b"step 3/7", "up did not go back a step")
        expect(back, b"pty-endpoint", "going back lost the typed name")

        # Forward again, filling what is left, so the last step can save.
        expect(
            press_and_settle(process, master_fd, output, b"\r"),
            b"step 4/7",
            "enter did not return to the credential step",
        )
        expect(
            press_and_settle(process, master_fd, output, b"\r"),
            b"step 5/7",
            "enter did not reach the model step",
        )
        press_and_settle(process, master_fd, output, b"eleven_multilingual_v2", cap=15.0)
        expect(
            press_and_settle(process, master_fd, output, b"\r"),
            b"step 6/7",
            "enter did not reach the voice step",
        )
        press_and_settle(process, master_fd, output, b"pty-voice-id", cap=15.0)
        review = press_and_settle(process, master_fd, output, b"\r")
        expect(review, b"step 7/7", "enter did not reach the review")
        # With nothing missing the review offers to save. A gap would be listed
        # here instead, which is the same screen answering the other way.
        expect(review, b"enter saves this", "the review did not offer to save")
        # The draft rows are read off the screen rather than off this frame:
        # only the rows that changed are repainted, and these did not.
        screen = screen_text(bytes(output))
        expect(screen, b"pty-endpoint", "the review lost the name")
        expect(screen, b"eleven_multilingual_v2", "the review lost the model")

        # What the wizard actually puts on the wire. The server side is held by
        # save_request -> apply -> loader in test/voice_wizard; this is the half
        # that test cannot see, which is whether the pane sends it.
        os.write(master_fd, b"\r")
        body = json.loads(
            wait_for_http_request(
                process, master_fd, output, requests, path="/api/v1/voice/setup"
            )
        )
        if body.get("expected_revision") != "fixture-voice-revision":
            raise AssertionError(
                f"the save did not carry the revision the pane read: {body!r}"
            )
        changes = {change.get("change"): change for change in body.get("changes", [])}
        if "put_endpoint" not in changes:
            raise AssertionError(f"the save omitted put_endpoint: {body!r}")
        # A voice name is provider vocabulary, so it is only right as the
        # section default while everything falling back to it shares this
        # endpoint's kind. This section holds a voice_mcp endpoint beside the
        # elevenlabs one, so voice_placement puts the voice on the endpoint and
        # leaves the section default the other endpoint can still read.
        if "set_tts_default_voice" in changes:
            raise AssertionError(f"the save rewrote the section's voice: {body!r}")
        # The model rides on the endpoint. Sent as the section's default it
        # became the model every other endpoint in the section was asked for.
        if "set_default_model" in changes:
            raise AssertionError(f"the save rewrote the section's model: {body!r}")
        endpoint = changes["put_endpoint"].get("endpoint", {})
        if endpoint.get("id") != "pty-endpoint":
            raise AssertionError(f"the endpoint is not the one typed: {endpoint!r}")
        if endpoint.get("model") != "eleven_multilingual_v2":
            raise AssertionError(f"the endpoint lost its model: {endpoint!r}")
        if endpoint.get("api_key_env") != "ELEVENLABS_API_KEY":
            raise AssertionError(f"the credential variable was lost: {endpoint!r}")
        # The name of the variable, never its value: runtime.toml is committed.
        if any("sk-" in str(value) for value in endpoint.values()):
            raise AssertionError(f"the save carried something key-shaped: {endpoint!r}")
        if endpoint.get("default_voice") != "pty-voice-id":
            raise AssertionError(f"the endpoint lost its voice: {endpoint!r}")

        # Esc leaves. The pane is underneath and no step counter remains.
        closed = press_and_settle(process, master_fd, output, b"\x1b")
        expect(closed, b"fixture-elevenlabs", "the pane did not come back")
        if b"step " in closed:
            raise AssertionError(f"Esc did not close the wizard: {closed!r}")

        # Quit is armed: this is the first press and the harness sends the
        # confirming one. Not judged on a frame -- the arming notice and the
        # exit race, and either is a correct answer to one press.
        read_available(master_fd, output)
        os.write(master_fd, b"q")

    return interact


def run_voice_wizard_regression(executable: str) -> None:
    requests: HttpRequests = []
    # The probe that follows a save is left to fail: whether an endpoint
    # answers is the endpoint's business, and a fixture that said yes would be
    # saying it for them.
    run_terminal_scenario(
        executable,
        description="The voice setup wizard opens, walks, saves, and leaves on Esc",
        interact=voice_wizard_interaction(requests),
        http_fixtures=voice_wizard_http_fixtures(),
        http_requests=requests,
    )


VOICE_SCROLL_ROWS = 24


def voice_scroll_http_fixtures() -> HttpFixtures:
    """More endpoints and probe rows than a 30-row terminal holds."""
    fixtures = overview_event_http_fixtures()
    fixtures["/api/v1/voice/config"] = (200, VOICE_CONFIG_FIXTURE)
    endpoints = [
        {
            "id": f"tts-endpoint-{index:02d}",
            "kind": "elevenlabs_direct",
            "enabled": True,
            "api_key_env": "ELEVENLABS_API_KEY",
            "address": "https://api.elevenlabs.io/v1",
        }
        for index in range(1, VOICE_SCROLL_ROWS + 1)
    ]
    setup = {**VOICE_SETUP_FIXTURE, "tts": {**VOICE_SETUP_FIXTURE["tts"], "endpoints": endpoints}}
    fixtures["/api/v1/voice/setup"] = RequestHttpResponse(
        lambda body: (200, {"revision": "fixture-voice-revision-2"})
        if body
        else (200, setup)
    )
    fixtures["/api/v1/voice/probe/tts"] = (
        200,
        {
            "endpoints": [
                {
                    "endpoint_id": f"probe-row-{index:02d}",
                    "kind": "elevenlabs_direct",
                    "state": "answered",
                    "detail": "24285 bytes of audio",
                }
                for index in range(1, VOICE_SCROLL_ROWS + 1)
            ]
        },
    )
    return fixtures


def voice_scroll_interaction() -> Interaction:
    """The endpoint list and the probe report can be read to their last row.

    Both used to be laid out into the frame with no offset, and the frame keeps
    its leading rows: the tail -- and past a point the footer -- was drawn and
    cut, with no key that brought it back.
    """

    def interact(
        process: "subprocess.Popen[bytes]",
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        def expect(frame: bytes, needle: bytes, what: str) -> None:
            if needle not in frame:
                raise AssertionError(f"{what}: {needle!r} missing from {frame!r}")

        def refuse(frame: bytes, needle: bytes, what: str) -> None:
            if needle in frame:
                raise AssertionError(f"{what}: {needle!r} present in {frame!r}")

        first = b"tts-endpoint-01"
        last = f"tts-endpoint-{VOICE_SCROLL_ROWS:02d}".encode()
        open_the_voice_pane(process, master_fd, output)
        drain_until_quiet(process, master_fd, output)
        screen = screen_text(bytes(output))
        expect(screen, first, "the pane did not list the endpoints")
        refuse(screen, last, "the fixture no longer overflows the terminal")
        expect(screen, b"j/k:select / scroll", "the pane footer did not say how to scroll")

        press_and_settle(process, master_fd, output, b"\x1b[F")
        screen = screen_text(bytes(output))
        expect(screen, last, "End did not reach the last endpoint")
        expect(screen, b"q:quit", "the footer was cut at the end of the list")

        press_and_settle(process, master_fd, output, b"\x1b[H")
        screen = screen_text(bytes(output))
        expect(screen, first, "Home did not return to the first endpoint")
        refuse(screen, last, "Home left the list at its end")

        press_and_settle(process, master_fd, output, b"e")
        for step in (b"\r", b"\r"):
            press_and_settle(process, master_fd, output, step)
        press_and_settle(process, master_fd, output, b"scroll-endpoint", cap=15.0)
        for step in (b"\r", b"\r"):
            press_and_settle(process, master_fd, output, step)
        press_and_settle(process, master_fd, output, b"eleven_multilingual_v2", cap=15.0)
        press_and_settle(process, master_fd, output, b"\r")
        press_and_settle(process, master_fd, output, b"scroll-voice", cap=15.0)
        expect(
            press_and_settle(process, master_fd, output, b"\r"),
            b"enter saves this",
            "the wizard did not reach a review it could save",
        )

        probe_last = f"probe-row-{VOICE_SCROLL_ROWS:02d}".encode()
        read_available(master_fd, output)
        start = len(output)
        os.write(master_fd, b"\r")
        wait_for_output(
            process, master_fd, output, b"probe-row-01", start=start, timeout=10.0
        )
        drain_until_quiet(process, master_fd, output)
        screen = screen_text(bytes(output))
        expect(screen, b"what answered", "the probe report did not draw")
        refuse(screen, probe_last, "the probe fixture no longer overflows the terminal")
        expect(screen, b"PgUp/PgDn:scroll", "the wizard footer did not say how to scroll")

        # A press at the end draws nothing new, so each one is judged by the
        # screen after the output stops rather than by a frame arriving.
        for _ in range(4):
            if probe_last in screen_text(bytes(output)):
                break
            write_all(master_fd, output, b"\x1b[6~")
            drain_until_quiet(process, master_fd, output)
        screen = screen_text(bytes(output))
        expect(screen, probe_last, "PgDn did not reach the last probe row")
        expect(screen, b"Esc:cancel", "the wizard footer was cut at the end of the report")

        closed = press_and_settle(process, master_fd, output, b"\x1b")
        refuse(closed, b"step ", "Esc did not close the wizard")
        read_available(master_fd, output)
        os.write(master_fd, b"q")

    return interact


def run_voice_scroll_regression(executable: str) -> None:
    run_terminal_scenario(
        executable,
        description="The voice endpoint list and the probe report scroll to their ends",
        interact=voice_scroll_interaction(),
        http_fixtures=voice_scroll_http_fixtures(),
    )
