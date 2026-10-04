"""Registry/assets metadata remains readable through pages and stale reads."""
import copy
import os
import re
import sys
import tui_keyboard_harness as _keyboard_harness
import tui_keyboard_runtime as _keyboard_runtime


KEY = "prompt-__identity__-`raw`-" + "k" * 95 + "-KEYTAIL"
FILE = "config/" + "경로-__raw__-" * 22 + "FILETAIL.md"
VARIABLE = "variable_`raw`_" + "v" * 95 + "_VARTAIL"
BODY = "BODYHEAD " + "한글 prompt body " * 15 + "BODYTAIL"
REASON = "Unknown template variables: " + VARIABLE + " REASONTAIL"
ERROR = "ERRORHEAD " + "한글 실패 원인 " * 22 + "ERRORTAIL"
ASSET = "assets/" + "자산-__raw__-" * 22 + "ASSETTAIL.txt"
ASSET_FILE = "runtime/" + "긴경로-`raw`-" * 22 + "ASSETFILETAIL.txt"
ASSET_BODY = "ASSETBODYHEAD " + "한글 asset text " * 15 + "ASSETBODYTAIL"
WINDOW = re.compile(r"Detail \[(\d+)-(\d+)/(\d+)\]")


def completed(output):
    end = output.rfind(_keyboard_harness.FRAME_END)
    assert end >= 0, "No completed redraw"
    return bytes(output[:end + len(_keyboard_harness.FRAME_END)])


def window(output, columns):
    rows = _keyboard_harness.screen_rows(completed(output))
    position, match = next((row, WINDOW.search(text.decode("utf-8")))
        for row, text in sorted(rows.items()) if WINDOW.search(text.decode("utf-8")))
    first, last, total = map(int, match.groups())
    body = []
    for index in range(last - first + 1):
        text = rows.get(position + 1 + index, b"").decode("utf-8", errors="strict")
        assert _keyboard_harness.fixture_cell_width(text) <= columns, (columns, text)
        body.append(text.strip())
    return first, last, total, body


def collect(process, fd, output, columns):
    captured = {}
    while True:
        first, last, total, body = window(output, columns)
        captured.update((first + index, line) for index, line in enumerate(body))
        if last == total:
            break
        height = last - first + 1
        expected = min(total-height+1, first+max(1, height-1))
        _keyboard_harness.send_and_wait(process, fd, output, b"\x1b[6~", f"Detail [{expected}-".encode())
    return total, "".join("".join(captured[index].split()) for index in sorted(captured))


def run(executable, columns, no_color):
    fixtures = _keyboard_runtime.held_back_prompts_http_fixtures()
    _, catalog = fixtures["/api/v1/prompts"]
    row = catalog["prompts"][0]
    row.update(key=KEY, category="librarian", file_path=FILE, effective=BODY,
               description="DESCRIPTIONHEAD " + "설명 " * 20 + "DESCRIPTIONTAIL",
               template_variables=[VARIABLE])
    second = copy.deepcopy(row)
    second.update(key="second-prompt", category="keeper", effective="SECOND-PROMPT-BODY")
    catalog["prompts"].append(second)
    catalog["held_back"][0].update(key=KEY, reason=REASON)
    catalog["runtime_assets"] = [
        {"path": ASSET, "file_path": ASSET_FILE, "value": ASSET_BODY, "file_exists": True},
        {"path": "second.txt", "file_path": "config/second.txt", "value": "SECOND-ASSET-BODY", "file_exists": True}]
    fixtures["/api/v1/prompts"] = _keyboard_harness.SequencedHttpResponse([
        (200, catalog), (503, {"error": ERROR}), (200, catalog)])

    def interact(process, fd, _slave, output, _base):
        _keyboard_harness.tab_until(process, fd, output, b"MASC System")
        for _ in range(8):
            if "MASC 프롬프트".encode() in bytes(output):
                break
            _keyboard_harness.send_and_wait(process, fd, output, b"p", b"MASC ")
        else:
            raise AssertionError("prompts pane not reached")
        _keyboard_harness.wait_for_output(process, fd, output, b"KEYTAIL", start=0, timeout=10)
        _keyboard_harness.read_available(fd, output)
        start = len(output)
        _keyboard_harness.resize_and_wait(process, fd, output, rows=18, columns=columns,
                          needle=b"KEYTAIL", controls=(_keyboard_harness.FULL_REDRAW,))
        _keyboard_harness.wait_for_output(process, fd, output, _keyboard_harness.FRAME_END,
                          start=_keyboard_harness.end_of_needle(output, b"KEYTAIL", start), timeout=3)
        assert "Esc:back" in _keyboard_harness.screen_text(completed(output)).decode("utf-8")
        initial_total, text = collect(process, fd, output, columns)
        for field in (KEY, FILE, "템플릿변수:"+VARIABLE, BODY, REASON, "DESCRIPTIONTAIL", "다시 저장하면"):
            assert "".join(field.split()) in text, (columns, field, text)
        _keyboard_harness.send_and_wait(process, fd, output, b"\x1b[H", b"Detail [1-")
        _, last, _, _ = window(output, columns)
        _keyboard_harness.send_and_wait(process, fd, output, b"\x1b[F", f"/{initial_total}]".encode())
        first, shown_last, total, _ = window(output, columns)
        assert total == initial_total and shown_last == total
        assert first == max(1, total-last+1)
        _keyboard_harness.send_and_wait(process, fd, output, b"r", "새로고침 실패".encode())
        _keyboard_harness.send_and_wait(process, fd, output, b"\x1b[H", b"Detail [1-")
        _, stale = collect(process, fd, output, columns)
        for field in (ERROR, KEY, BODY, REASON):
            assert "".join(field.split()) in stale, (columns, field, stale)
        _keyboard_harness.send_and_wait(process, fd, output, b"r", f"/{initial_total}]".encode())
        _keyboard_harness.send_and_wait(process, fd, output, b"\x1b[H", b"Detail [1-")
        _keyboard_harness.send_and_wait(process, fd, output, b"j", b"SECOND-PROMPT-BODY")
        assert window(output, columns)[0] == 1
        assert "BODYHEAD" not in _keyboard_harness.screen_text(completed(output)).decode("utf-8")
        _, secondary = collect(process, fd, output, columns)
        assert "템플릿변수:"+VARIABLE in secondary, (columns, secondary)
        _keyboard_harness.send_and_wait(process, fd, output, b"k", f"/{initial_total}]".encode())
        _keyboard_harness.send_and_wait(process, fd, output, b"o", b"ASSETTAIL.txt")
        _, assets = collect(process, fd, output, columns)
        for field in (ASSET, ASSET_FILE, ASSET_BODY, "registry override·편집 대상이 아닙니다"):
            assert "".join(field.split()) in assets, (columns, field, assets)
        _keyboard_harness.send_and_wait(process, fd, output, b"\x1b[H", b"Detail [1-")
        _keyboard_harness.send_and_wait(process, fd, output, b"j", b"SECOND-ASSET-BODY")
        assert window(output, columns)[0] == 1
        assert "ASSETBODYHEAD" not in _keyboard_harness.screen_text(completed(output)).decode("utf-8")
        os.write(fd, b"q")

    _keyboard_harness.run_terminal_scenario(executable,
        description=f"Prompts full registry/assets {columns} NO_COLOR={no_color}",
        interact=interact, http_fixtures=fixtures,
        extra_env={"NO_COLOR": "1"} if no_color else {})


if __name__ == "__main__":
    for plain in (False, True):
        for width in (30, 40, 60, 80, 120):
            run(os.path.abspath(sys.argv[1]), width, plain)
    print("Prompts complete registry/assets and retained refresh failure: PASS")
