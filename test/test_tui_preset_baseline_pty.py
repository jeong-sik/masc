"""Exercise default-baseline detail and restore through the real TUI in a PTY.

HTTP replies are controlled fixtures; this validates rendering and user input,
not the live backend. Backend persistence is covered by test_prompt_preset.
"""
import base64
import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile

import tui_keyboard_harness as h


def run(executable, output_dir):
    manifest = {"schema_version": 1, "name": "baseline-demo",
                "description": "기본 프롬프트 변경 확인",
                "created_at": "2026-10-08T03:00:00Z", "override_count": 1,
                "override_keys": ["keeper"], "keepers": ["alpha"],
                "assignment_count": 1, "lane_count": 1}
    comparison = {"status": "differs", "changes": [
        {"key": "keeper", "saved_sha256": "a" * 64, "current_sha256": "b" * 64},
        {"key": "judge", "saved_sha256": None, "current_sha256": "c" * 64},
        {"key": "retired", "saved_sha256": "d" * 64, "current_sha256": None}]}
    detail = {"ok": True, "directory": "/demo/.masc/presets/baseline-demo",
              "saved_settings": {"status": "matches"}, "default_prompts": comparison,
              "prompt_files": [{"key": "keeper", "path": "/demo/prompts/keeper.md", "source": "override"}],
              "preset": {"name": "baseline-demo", "prompt_overrides": [{"key": "keeper", "bytes": 256}],
                         "instructions": [{"keeper_file": "alpha.toml", "bytes": 128}],
                         "assignments": [{"keeper": "alpha", "runtime": "demo-runtime"}],
                         "lanes": [{"id": "librarian_exact"}]}}
    report = {"ok": True, "report": {"restored": "baseline-demo", "autosave": "_autosave",
              "prompt_overrides": {"effect": "immediate", "applied": ["keeper"], "skipped": []},
              "instructions": {"effect": "keeper_restart", "applied": ["alpha"], "skipped": []},
              "runtime": {"status": "unchanged"}, "default_prompts": comparison}}
    fixtures = h.overview_event_http_fixtures()
    fixtures["/api/v1/presets"] = (200, {"ok": True, "presets": [manifest], "unreadable": []})
    fixtures["/api/v1/presets/show?name=baseline-demo"] = (200, detail)
    fixtures["/api/v1/presets/restore"] = (200, report)
    requests = []
    output_dir.mkdir(parents=True, exist_ok=True)
    captures = []

    def capture(name, output, columns, rows):
        raw = bytes(output[:output.rfind(h.FRAME_END) + len(h.FRAME_END)])
        # Replay only screen drawing, excluding startup terminal queries whose
        # answers would be echoed by the replay process rather than the TUI.
        redraw = raw.rfind(h.FULL_REDRAW)
        assert redraw >= 0, "capture has no full screen drawing"
        raw = raw[redraw:]
        screen = h.screen_rows(raw)
        text = b"\n".join(screen.get(i, b"") for i in range(1, rows + 1)).decode("utf-8")
        (output_dir / (name + ".ansi")).write_bytes(raw)
        (output_dir / (name + ".txt")).write_text(text)
        captures.append({"name": name, "columns": columns, "rows": rows,
                         "frame_b64": base64.b64encode(raw).decode(), "screen": text})

    def interact(process, fd, _slave, output, _base):
        h.palette_go(process, fd, output, b"go System", b"runtime.toml")
        for _ in range(4):
            h.press_and_settle(process, fd, output, b"p")
        h.wait_for_output(process, fd, output, "기본 프롬프트 · 차이 3건".encode(), start=0, timeout=10)
        h.drain_until_quiet(process, fd, output)
        capture("detail-wide", output, 120, 42)
        detail_text = (output_dir / "detail-wide.txt").read_text()
        for label in ("변경 · keeper", "추가 · judge", "없음 · retired"):
            assert label in detail_text, (label, detail_text)
        h.press_and_settle(process, fd, output, b"u")
        assert not any(path == "/api/v1/presets/restore" for path, _ in requests)
        h.send_and_wait(process, fd, output, b"u", "baseline-demo 복원 · 이전 상태는 _autosave".encode())
        h.send_and_wait(process, fd, output, b"\x1b[F", b"restored preset baseline-demo")
        h.drain_until_quiet(process, fd, output)
        restore_requests = [json.loads(body) for path, body in requests if path == "/api/v1/presets/restore"]
        assert restore_requests == [{"name": "baseline-demo"}], restore_requests
        capture("restore-wide", output, 120, 42)
        restore_text = (output_dir / "restore-wide.txt").read_text()
        for label in ("restored preset baseline-demo", "기본 프롬프트 · 차이 3건",
                      "변경 · keeper", "추가 · judge", "없음 · retired"):
            assert label in restore_text, (label, restore_text)
        h.resize_and_wait(process, fd, output, rows=24, columns=60,
                          needle=b"baseline-demo", final_cursor=b"\x1b[?25l")
        h.send_and_wait(process, fd, output, b"\x1b[H", b"Selected:")
        h.drain_until_quiet(process, fd, output)
        capture("detail-narrow", output, 60, 24)
        h.press_and_settle(process, fd, output, b"\x1b[6~")
        capture("changes-narrow", output, 60, 24)
        narrow_text = ((output_dir / "detail-narrow.txt").read_text()
                       + (output_dir / "changes-narrow.txt").read_text())
        for label in ("변경 · keeper", "추가 · judge", "없음 · retired"):
            assert label in narrow_text, (label, narrow_text)
        os.write(fd, b"q")

    h.run_terminal_scenario(executable, description="Preset baseline drift is observable and restore proceeds",
                            interact=interact, http_fixtures=fixtures, http_requests=requests,
                            terminal_cols=120, terminal_rows=42, workspace="preset-demo")
    receipt = {"scope": "real TUI PTY over synthetic HTTP fixtures", "live_backend": False,
               "binary_sha256": hashlib.sha256(Path(executable).read_bytes()).hexdigest(),
               "captures": captures, "restore_requests": 1}
    (output_dir / "pty-receipt.json").write_text(json.dumps(receipt, indent=2, ensure_ascii=False))
    print("Preset baseline PTY: PASS")


if __name__ == "__main__":
    if len(sys.argv) > 2:
        run(os.path.abspath(sys.argv[1]), Path(sys.argv[2]))
    else:
        with tempfile.TemporaryDirectory(prefix="preset-baseline-pty-") as output:
            run(os.path.abspath(sys.argv[1]), Path(output))
