"""A server batch occupies one TUI status row while a later message waits."""

import json
import os
import sys

import test_tui_keyboard_input as h

SOURCE_MODULES = (
    "bin/masc_tui_render_chat.ml",
    "bin/masc_tui_types.ml",
)


class BatchFixture(h.AtomicChatFixture):
    def stream(self, body: bytes) -> h.StreamingHttpResponse:
        response = super().stream(body)
        request = json.loads(body)
        with self.lock:
            position = next(
                index for index, submitted in enumerate(self.submitted, 1)
                if submitted["request_id"] == request["request_id"]
            )

        def chunks():
            original = response.chunks()
            yield next(original)
            if position <= 3:
                with self.admitted:
                    if not self.admitted.wait_for(
                        lambda: len(self.submitted) >= 3, timeout=10
                    ):
                        raise AssertionError("three batch members were not admitted")
                    execution_id = self.submitted[0]["request_id"]
                event = {
                    "type": "CUSTOM",
                    "threadId": "keeper:alpha",
                    "timestamp": 1.0,
                    "name": "KEEPER_CHAT_BATCH_BOUND",
                    "value": {
                        "operation_id": request["request_id"],
                        "execution_id": execution_id,
                    },
                }
                yield f"data: {json.dumps(event)}\n\n".encode()
                started = {
                    "type": "RUN_STARTED",
                    "threadId": "keeper:alpha",
                    "timestamp": 1.0,
                    "runId": f"keeper-operation-run-{request['request_id']}",
                }
                yield f"data: {json.dumps(started)}\n\n".encode()
            for chunk in original:
                if position > 3:
                    yield chunk
                    continue
                events = [
                    part for part in chunk.split(b"\n\n")
                    if part and json.loads(part.removeprefix(b"data: "))["type"] != "RUN_STARTED"
                ]
                yield b"\n\n".join(events) + b"\n\n"

        return h.StreamingHttpResponse(chunks)


def run(executable: str) -> None:
    fixture = BatchFixture()

    def interact(process, master_fd, _slave_fd, output, _base_path):
        try:
            h.open_atomic_chat(process, master_fd, output)
            for index, message in enumerate(
                (b"batch-one", b"batch-two", b"batch-three", b"next-turn"), 1
            ):
                h.send_and_wait(
                    process, master_fd, output,
                    message, h.composer_showing(message),
                )
                os.write(master_fd, b"\r")
                h.wait_for_atomic_admissions(
                    process, master_fd, output, fixture, index
                )
            h.wait_for_output(
                process, master_fd, output,
                b"3 messages in one turn \xc2\xb7 running", start=0, timeout=10,
            )
            screen = h.screen_text(bytes(output))
            grouped = b"3 messages in one turn \xc2\xb7 running"
            if screen.count(b"3 messages in one turn") != 1 or grouped not in screen:
                raise AssertionError(f"batch drew multiple status rows: {screen!r}")
            if len(fixture.submitted) != 4:
                raise AssertionError("TUI failed to submit the later message")
            fixture.release.set()
            h.escape_to_keeper_detail(process, master_fd, output, name=b"alpha")
            h.send_and_wait(process, master_fd, output, b"\x1b", b"MASC Keepers")
            os.write(master_fd, b"q")
        finally:
            fixture.release_interrupt.set()
            fixture.release.set()

    h.run_terminal_scenario(
        executable,
        description="Server batch has one TUI status row",
        interact=interact,
        http_fixtures=fixture.fixtures,
        refresh=0.2,
    )


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("TUI batch status: PASS")
