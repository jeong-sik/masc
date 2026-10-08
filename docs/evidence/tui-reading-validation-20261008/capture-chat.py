"""Capture actual local fixture PTY frames for the conversation-first review."""
import base64
import hashlib
import json
import os
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "test"))
import tui_keyboard_harness as h
from tui_keyboard_chat import message_origin_history_fixture


def run(executable):
    fixtures = h.keeper_runtime_http_fixtures()
    status, history = message_origin_history_fixture()
    history[0]["content"] = "채팅 화면에서 필요한 내용만 읽고 싶어요. 저널과 실행 정보는 상세 보기에서 확인할게요."
    history[1]["content"] = (
        "대화 본문을 먼저 읽을 수 있도록 정리했습니다.\n\n"
        "발신자와 답변은 작은 여백으로 구분하고, 긴 문장은 일정한 폭으로 줄을 바꿉니다. "
        "저널과 요청 식별자는 상세 보기에서 확인할 수 있습니다.\n\n"
        "전송 실패나 승인 요청처럼 지금 확인해야 하는 정보는 계속 표시합니다.")
    fixtures["/api/v1/keepers/alpha/chat/history"] = status, history

    def interact(process, fd, _slave, output, _base):
        h.palette_go(process, fd, output, b"keeper alpha", "정리했습니다".encode())
        terminal_rows = 30
        last_paragraph = history[1]["content"].rsplit("\n\n", 1)[1].encode()
        for columns in (80, 120):
            frame = h.resize_and_wait(process, fd, output, rows=terminal_rows, columns=columns,
                                      needle="정리했습니다".encode(), controls=(h.FULL_REDRAW,),
                                      final_cursor=b"\x1b[?25h")
            if not frame.endswith(h.FRAME_END):
                raise AssertionError(f"{columns}-column capture ended before its frame completed")
            rows = h.screen_rows(frame)
            if set(rows) != set(range(1, terminal_rows + 1)):
                raise AssertionError(f"{columns}-column capture missed physical rows: {sorted(rows)!r}")
            paragraph_row = h.screen_row_of(rows, last_paragraph)
            composer_row = h.screen_row_of(rows, b"> ")
            context_row = h.screen_row_of(rows, b"Context")
            footer_row = h.screen_row_of(rows, b"Enter:send")
            if not (0 < paragraph_row < composer_row < context_row < footer_row):
                raise AssertionError(f"{columns}-column capture lost its last paragraph, composer or footer: {rows!r}")
            if b"/:commands" not in rows[footer_row] or b"Esc:" not in rows[footer_row]:
                raise AssertionError(f"{columns}-column capture has an incomplete footer: {rows[footer_row]!r}")
            print("STUDIO_CAPTURE=" + json.dumps({
                "suite": "conversation-first-local", "name": f"chat-{columns}",
                "rows": terminal_rows, "columns": columns, "provenance": "local fixture PTY",
                "frame_b64": base64.b64encode(frame).decode(),
                "screen": b"\n".join(rows[row] for row in range(1, terminal_rows + 1)).decode(),
            }, ensure_ascii=False), flush=True)
        h.send_and_wait(process, fd, output, b"\x1b", b"MASC Keepers")
        os.write(fd, b"q")

    print("STUDIO_BINARY_SHA256=" + hashlib.sha256(Path(executable).read_bytes()).hexdigest(), flush=True)
    h.run_terminal_scenario(executable, description="Conversation-first local review capture",
                            interact=interact, http_fixtures=fixtures,
                            workspace="Reading preview", terminal_cols=100)
    print("Conversation-first local review capture: PASS", flush=True)


if __name__ == "__main__":
    run(str(Path(sys.argv[1]).resolve()))
