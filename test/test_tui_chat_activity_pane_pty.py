"""Self-composed chat and Board frames reserve the Activity pane above the footer."""
import sys
import base64
import json
import test_tui_keyboard_input as h



def board_interaction(process, fd, _slave, output, _base):
    h.palette_go(process, fd, output, b"go board", b"MASC Board")
    h.send_and_wait(process, fd, output, b"w", b"first line: title")
    for draft in (b"", b"short draft"):
        if draft:
            h.write_all(fd, output, draft)
        h.drain_until_quiet(process, fd, output, cap=4.0)
        screen = h.screen_rows(bytes(output))
        # A self-composed frame owns its footer, even when the draft is empty.
        footer = h.screen_row_of(screen, b"Esc:")
        if footer != 30:
            raise AssertionError(f"Board footer is at {footer}, expected 30: {screen!r}")
        if b"\xe2\x94\x82" in screen[30]:
            raise AssertionError(f"Activity extends into Board footer: {screen[30]!r}")
        # Empty Activity rows intentionally have no vertical rule. Check its
        # header to prove the pane is present, and the footer's final position
        # to prove short drafts were padded before it.
        pane_cell = h.acting_pane_header_cell(output)
        expected = h.KEEPER_CHAT_PANE_COLUMNS - h.ACTING_PANE_NARROW_COLUMNS + 1
        if pane_cell != expected:
            raise AssertionError(f"Board Activity header at {pane_cell}, expected {expected}")
    h.send_and_wait(process, fd, output, b"\x1b", b"d:discard")
    h.send_and_wait(process, fd, output, b"d", b"MASC Board")
    h.write_all(fd, output, b"q")


def output_handoff_scenario(executable):
    fixture = h.AtomicChatFixture(no_control_token=True)
    phase = {"tail": "FIRST_PROGRESS_LINE\n한글 진행 내용", "failed": False}

    def turns():
        if phase["failed"]:
            return 503, {"error": "fixture poll failed"}
        status, payload = fixture.turns()
        turn = payload["keepers"][0]["turn"]
        if turn is not None:
            turn["preview"]["text_tail"] = phase["tail"]
            if not phase["tail"]:
                turn["preview"]["status_text"] = "EMPTY_PREVIEW_OBSERVED"
        return status, payload

    fixture.fixtures["/api/v1/keepers/turns"] = turns
    fixture.fixtures["/api/v1/keepers/alpha/chat/history"] = (200, [])

    def screen(process, fd, output):
        h.drain_until_quiet(process, fd, output, cap=1.0)
        return h.screen_rows(bytes(output))

    def interact(process, fd, _slave, output, _base):
        try:
            h.tab_until(process, fd, output, b"MASC Keepers")
            h.select_keeper_row(process, fd, output, b"alpha")
            h.send_and_wait(process, fd, output, b"c",
                            b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat")
            h.wait_for_output(process, fd, output, b"FIRST_PROGRESS_LINE", start=0, timeout=12)
            rows = screen(process, fd, output)
            excerpt_at = h.screen_row_of(rows, b"FIRST_PROGRESS_LINE")
            continuation_at = h.screen_row_of(rows, "한글 진행 내용".encode())
            if continuation_at <= excerpt_at:
                raise AssertionError(f"multiline output lost its separate row: {rows!r}")
            activity_at = h.screen_row_of(rows, b"Esc stops it")
            if excerpt_at >= activity_at:
                raise AssertionError(f"output is outside conversation: {rows!r}")
            text = b"\n".join(rows.values())
            if text.count(b"FIRST_PROGRESS_LINE") != 1 or b"Latest output:" in text:
                raise AssertionError(f"output duplicated in footer: {rows!r}")
            if "최근 출력 발췌".encode() not in text:
                raise AssertionError(f"incomplete preview not labelled: {rows!r}")
            h.send_and_wait(process, fd, output, b"queued-question-preserved", b"queued-question-preserved")
            h.send_and_wait(process, fd, output, b"\r", b"WAITING TO START")
            phase["tail"] = "SECOND_PROGRESS_LINE"
            h.wait_for_output(process, fd, output, b"SECOND_PROGRESS_LINE", start=len(output), timeout=12)
            rows = screen(process, fd, output)
            text = b"\n".join(rows.values())
            for marker in (b"SECOND_PROGRESS_LINE", b"queued-question-preserved", b"WAITING TO START"):
                if marker not in text:
                    raise AssertionError(f"running output or queued input lost {marker!r}: {rows!r}")
            if b"FIRST_PROGRESS_LINE" in text or b"Latest output:" in text:
                raise AssertionError(f"rolling excerpt was appended as history: {rows!r}")
            print(json.dumps({"provenance": "fixture PTY", "scenario": "autonomous output behind queued chat",
                              "encoding": "base64", "pty": base64.b64encode(bytes(output)).decode()}), flush=True)
            phase["failed"] = True
            h.wait_for_output(process, fd, output, "마지막 관측, 갱신 실패".encode(), start=len(output), timeout=12)
            phase["failed"] = False
            phase["tail"] = ""
            h.wait_for_output(process, fd, output, b"EMPTY_PREVIEW_OBSERVED", start=len(output), timeout=12)
            rows = screen(process, fd, output)
            if b"SECOND_PROGRESS_LINE" in b"\n".join(rows.values()):
                raise AssertionError(f"empty preview retained previous output: {rows!r}")
        finally:
            settlement_start = len(output)
            fixture.release.set()
            fixture.release_interrupt.set()
            fixture.release_first_acceptance.set()
        # Esc interrupts an active request. Wait for the actual return action
        # before using it, rather than racing the terminal events after release.
        h.wait_for_output(process, fd, output, b"Esc:list",
                          start=settlement_start, timeout=12)
        h.send_and_wait(process, fd, output, b"\x1b", b"MASC Keepers")
        h.write_all(fd, output, b"q")

    h.run_terminal_scenario(executable, description="Autonomous output stays in the conversation beside queued input",
                            interact=interact, http_fixtures=fixture.fixtures, refresh=0.5,
                            terminal_cols=100)


if __name__ == "__main__":
    h.run_terminal_scenario(
        sys.argv[1],
        description="Keeper chat draws the Activity pane beside it",
        interact=h.keeper_chat_draws_activity_pane_interaction,
        terminal_cols=h.KEEPER_CHAT_PANE_COLUMNS,
    )
    h.run_terminal_scenario(
        sys.argv[1],
        description="Board drafts keep the footer below the Activity pane",
        interact=board_interaction,
        terminal_cols=h.KEEPER_CHAT_PANE_COLUMNS,
    )
    output_handoff_scenario(sys.argv[1])
    print("tui chat Activity pane: PASS")
