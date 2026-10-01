"""Ctrl-O preserves the selected saved, queued, or newly staged attachment."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import threading
import time

import test_tui_keyboard_input as h

SOURCE_MODULES = ("bin/masc_tui.ml", "bin/masc_tui_image_preview.ml")
MODES = ("success", "refused", "malformed", "wrong-digest", "wrong-bytes",
         "corrupt-content", "missing-envelope", "cancel", "queued", "queued-clock-skew",
         "delayed-history", "delayed-history-clock-skew", "settled-history")
CHAT = "Keepers ▸ alpha ▸ chat".encode()
STAGED_NAME = "newest.png"
# A test observation window, not proof that the client handled its stale result.
CANCELLATION_OBSERVATION_SECONDS = 1.0
# An old server row sorts beyond newly typed client rows when the server
# clock runs ahead. This offset changes fixture data only, never the host clock.
HISTORY_CLOCK_SKEW_SECONDS = 3600


def run(executable, *, mode, evidence_dir=None):
    fetched = threading.Event()
    released = threading.Event()
    response_ready = threading.Event()
    queued = mode in ("queued", "queued-clock-skew")
    delayed_history = mode in ("delayed-history", "delayed-history-clock-skew")
    clock_skew = mode in ("queued-clock-skew", "delayed-history-clock-skew")
    settled_history = mode == "settled-history"
    queue = h.AtomicChatFixture(hold_first_acceptance=True) if queued else None
    fixtures = queue.fixtures if queue is not None else {}
    history = h.GatedHttpResponse((200, []), hold_seconds=15)
    image = []
    request_count = []
    submitted = []

    def prepare(base_path):
        h.seed_image_workspace(base_path)
        png = Path(base_path, h.IMAGE_NAME).read_bytes()
        image.append(png)
        Path(base_path, STAGED_NAME).write_bytes(png)
        payload = base64.b64encode(png).decode()
        sha = hashlib.sha256(payload.encode()).hexdigest()
        marker = f'[masc:blob sha256={sha} bytes={len(payload)} mime=text/plain preview="attachment payload"]'
        history.response = (200, [{
            "id": "retained-image", "role": "user", "content": "retained-image-ready",
            "ts": time.time() + (HISTORY_CLOCK_SKEW_SECONDS if clock_skew else 0), "attachments": [{
                "id": "image-1", "type": "image", "name": "../../label-only.png",
                "mime_type": "image/png", "data": marker,
            }],
        }])
        fixtures["/api/v1/keepers/alpha/chat/history"] = (
            history if delayed_history else (lambda: history.response)
        )

        if settled_history:
            def complete_local_image(body):
                submitted.append(json.loads(body))
                # A later bounded tail no longer includes the original user
                # request. Its session row therefore survives reconciliation.
                # This timestamp follows the POST; no clock wait is needed.
                history.response = (200, [{
                    "id": "newer-retained-image", "role": "user",
                    "content": "bounded-tail-image-ready", "ts": time.time(),
                    "attachments": [{
                        "id": "newer-image", "type": "image", "name": "newer-retained.png",
                        "mime_type": "image/png", "data": marker,
                    }],
                }])
                return h.keeper_chat_succeeded_response(body)

            fixtures["/api/v1/keepers/chat/stream"] = h.RequestHttpResponse(complete_local_image)

        def fetch():
            request_count.append(sha)
            fetched.set()
            if mode == "cancel" and not released.wait(timeout=10):
                raise AssertionError("held artifact response was never released")
            response_ready.set()
            if mode == "refused":
                return 503, {"error": "fixture artifact unavailable"}
            envelope = {"sha256": sha, "bytes": len(payload), "mime": "text/plain", "content": payload}
            if mode == "malformed":
                envelope["content"] = 123
            elif mode == "wrong-digest":
                envelope["sha256"] = "a" * 64
            elif mode == "wrong-bytes":
                envelope["bytes"] = len(payload) + 1
            elif mode == "corrupt-content":
                # Same length and still valid base64, but not the recorded blob.
                envelope["content"] = ("A" if payload[0] != "A" else "B") + payload[1:]
            elif mode == "missing-envelope":
                envelope = {"content": payload}
            return 200, envelope

        fixtures["/api/v1/artifacts/" + sha] = fetch

    def capture(output, *, suffix=""):
        if evidence_dir is not None:
            evidence_dir.mkdir(parents=True, exist_ok=True)
            raw = bytes(output)
            name = mode + ("-" + suffix if suffix else "")
            (evidence_dir / (name + ".ansi")).write_bytes(raw)
            (evidence_dir / (name + ".txt")).write_text(
                "\n".join(line.rstrip() for line in h.screen_text(raw).decode(errors="replace").splitlines()) + "\n")

    def stage(process, fd, output, base_path):
        command = f"/attach {Path(base_path, STAGED_NAME)}\r".encode()
        h.send_and_wait(process, fd, output, command, b"attached " + STAGED_NAME.encode())

    def wait_for_image(process, fd, output, *, start, title):
        h.wait_for_output(process, fd, output, b"a=T", start=start, timeout=5)
        # The first PTY read may contain only the graphics header. This tiny
        # fixture fits one Kitty chunk; require its payload and terminator.
        h.wait_for_output(process, fd, output, base64.b64encode(image[0]) + b"\x1b\\", start=start, timeout=5)
        if b"\x1b[1;1H" + title not in output[start:]:
            raise AssertionError("Ctrl-O displayed a different image source")

    def dismiss_image(process, fd, output):
        dismissed = len(output)
        os.write(fd, b" ")
        h.wait_for_output(process, fd, output, b"a=d", start=dismissed, timeout=5)
        h.wait_for_output(process, fd, output, CHAT, start=dismissed, timeout=5)
        title_end = h.end_of_needle(output, CHAT, dismissed)
        h.wait_for_output(process, fd, output, h.FRAME_END, start=title_end, timeout=5)

    def wait_for_artifact_error(process, fd, output, *, start, reason):
        # The notice shares a 100-column footer with key hints. Its reason may
        # be truncated; require the visible reason and artifact label together
        # on one row of the completed retained frame instead of its hidden tail.
        h.wait_for_output(process, fd, output, reason, start=start, timeout=5)
        reason_end = h.end_of_needle(output, reason, start)
        h.wait_for_output(process, fd, output, h.FRAME_END, start=reason_end, timeout=5)
        frame_end = output.find(h.FRAME_END, reason_end) + len(h.FRAME_END)
        rows = h.screen_rows(bytes(output[:frame_end]))
        target = b"sent image ../../label-only.png:"
        if not any(target in row and reason in row for row in rows.values()):
            raise AssertionError("artifact label and rejection reason were not visible in the same completed frame")
        if b"a=T" in output[start:frame_end]:
            raise AssertionError("a rejected artifact emitted image bytes")
        capture(output[:frame_end], suffix="error")

    def interact(process, fd, _slave, output, base_path):
        try:
            if queue is not None:
                h.open_atomic_chat(process, fd, output)
                h.wait_for_output(process, fd, output, b"retained-image-ready", start=0, timeout=5)
                h.send_and_wait(process, fd, output, b"held-turn", h.composer_showing(b"held-turn"))
                os.write(fd, b"\r")
                if not h.wait_for_fixture_event(process, fd, output, queue.first_post_received, timeout=5):
                    raise AssertionError("first admission was not held")
                stage(process, fd, output, base_path)
                h.send_and_wait(process, fd, output, b"queued-image", h.composer_showing(b"queued-image"))
                h.send_and_wait(process, fd, output, b"\r", "내 메시지 2건 대기".encode())
                if len(queue.received) != 1:
                    raise AssertionError("image request was not waiting locally behind the first admission")
            else:
                h.send_and_wait(process, fd, output, b"3", b"MASC Keepers")
                h.select_keeper_row(process, fd, output, b"alpha")
                h.send_and_wait(process, fd, output, b"\r", b"Keepers \xe2\x96\xb8 \x1b[1malpha")
                h.send_and_wait(process, fd, output, b"m", CHAT if delayed_history else b"retained-image-ready")
                if delayed_history:
                    if not h.wait_for_fixture_event(process, fd, output, history.requested, timeout=5):
                        raise AssertionError("initial history load did not reach its gate")
                    stage(process, fd, output, base_path)
                    loaded_from = len(output)
                    history.release.set()
                    h.wait_for_output(process, fd, output, b"retained-image-ready", start=loaded_from, timeout=5)
                    loaded_end = h.end_of_needle(output, b"retained-image-ready", loaded_from)
                    h.wait_for_output(process, fd, output, h.FRAME_END, start=loaded_end, timeout=5)

            if settled_history:
                stage(process, fd, output, base_path)
                h.send_and_wait(process, fd, output, b"settled-local-image", h.composer_showing(b"settled-local-image"))
                sent_from = len(output)
                os.write(fd, b"\r")
                h.wait_for_output(process, fd, output, b"reply-settled-local-image", start=sent_from, timeout=5)
                h.wait_for_output(process, fd, output, b"bounded-tail-image-ready", start=sent_from, timeout=5)

                def settled_frame():
                    end = output.rfind(h.FRAME_END)
                    if end < sent_from:
                        return False
                    screen = h.screen_text(bytes(output[:end + len(h.FRAME_END)]))
                    return (b"reply-settled-local-image" in screen
                            and b"bounded-tail-image-ready" in screen
                            and b"IN PROGRESS" not in screen and "내 메시지".encode() not in screen
                            and b"stream ended; settling" not in screen)

                if not h.wait_for_fixture_state(process, fd, output, settled_frame, timeout=5):
                    raise AssertionError("new bounded history was not drawn after the image turn settled")
                if len(submitted) != 1 or len(submitted[0].get("attachments", [])) != 1:
                    raise AssertionError("local image turn did not submit its attachment")

            start = len(output)
            os.write(fd, b"\x0f")
            if queued or delayed_history:
                wait_for_image(process, fd, output, start=start, title=STAGED_NAME.encode())
                if request_count:
                    raise AssertionError("Ctrl-O fetched an older saved image instead of the newer attachment")
                capture(output, suffix="open")
                dismiss_image(process, fd, output)
                if queue is not None:
                    queue.release_first_acceptance.set()
                    h.wait_for_atomic_admissions(process, fd, output, queue, 2)
                    sent = queue.submitted[1]
                    attachments = sent.get("attachments", [])
                    if sent["message"] != "queued-image" or len(attachments) != 1:
                        raise AssertionError("queued preview lost the original image request")
                    if attachments[0].get("data") != base64.b64encode(image[0]).decode():
                        raise AssertionError("queued preview changed the image payload before dispatch")
                    queue.release.set()
                    h.wait_for_output(process, fd, output, b"reply-queued-image", start=start, timeout=10)
            elif not h.wait_for_fixture_event(process, fd, output, fetched, timeout=5):
                capture(output)
                raise AssertionError("Ctrl-O did not fetch the displayed retained attachment")
            elif mode == "cancel":
                h.send_and_wait(process, fd, output, b"cancelled-preview", h.composer_showing(b"cancelled-preview"))
                released.set()
                if not h.wait_for_fixture_event(process, fd, output, response_ready, timeout=5):
                    raise AssertionError("held artifact response was not released")
                # response_ready is server-side, before the socket write. A
                # discarded Sent_image_ready has no client receipt on this
                # surface, so this is only a bounded negative observation.
                if h.poll_for_output(process, fd, output, b"a=T", start=start,
                                     timeout=CANCELLATION_OBSERVATION_SECONDS):
                    raise AssertionError("an image opened during the cancellation observation window")
                h.send_and_wait(process, fd, output, b"-still-chat", h.composer_showing(b"cancelled-preview-still-chat"))
                if b"a=T" in output[start:]:
                    raise AssertionError("an image opened before the post-cancellation draft edit")
                h.send_and_wait(process, fd, output, b"\x15", h.composer_showing(b""))
                print(f"Cancellation observation: no image transfer for {CANCELLATION_OBSERVATION_SECONDS}s "
                      "after fixture release; client completion is unobserved")
            elif mode in ("success", "settled-history"):
                title = b"newer-retained.png" if settled_history else b"../../label-only.png"
                wait_for_image(process, fd, output, start=start, title=title)
                capture(output, suffix="open")
                dismiss_image(process, fd, output)
            else:
                if mode in ("malformed", "missing-envelope"):
                    reason = b"sent image response requires"
                elif mode in ("wrong-digest", "wrong-bytes"):
                    reason = b"sent image response does not"
                elif mode == "corrupt-content":
                    reason = b"sent image content does not"
                else:
                    reason = b"HTTP 503: fixture artifact"
                wait_for_artifact_error(process, fd, output, start=start, reason=reason)
                h.send_and_wait(process, fd, output, b"still-alive", h.composer_showing(b"still-alive"))
                h.send_and_wait(process, fd, output, b"\x15", h.composer_showing(b""))
                if b"a=T" in output[start:]:
                    raise AssertionError("a rejected artifact emitted image bytes before the next draft edit")
            if not (queued or delayed_history) and len(request_count) != 1:
                raise AssertionError("one preview made duplicate artifact requests")
            capture(output)
            h.escape_to_keeper_detail(process, fd, output, name=b"alpha")
            h.send_and_wait(process, fd, output, b"\x1b", b"MASC Keepers")
            os.write(fd, b"q")
        finally:
            released.set()
            history.release.set()
            if queue is not None:
                queue.release_first_acceptance.set()
                queue.release_interrupt.set()
                queue.release.set()

    h.run_terminal_scenario(
        executable,
        description="Stored image preview: " + mode,
        interact=interact,
        http_fixtures=fixtures,
        prepare_workspace=prepare,
        preload_input=h.GRAPHICS_SUPPORTED_REPLY,
        refresh=0.2,
    )


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("executable")
    parser.add_argument("--mode", choices=MODES)
    parser.add_argument("--evidence-dir", type=Path)
    args = parser.parse_args()
    for mode in ([args.mode] if args.mode else MODES):
        run(os.path.abspath(args.executable), mode=mode, evidence_dir=args.evidence_dir)
    print("stored image preview: PASS")
