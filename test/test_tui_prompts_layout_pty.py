"""Registry/assets metadata remains readable through pages and stale reads."""
import copy
import os
import re
import sys
import test_tui_keyboard_input as h

SOURCE_MODULES = ("bin/masc_tui.ml", "bin/masc_tui_keys.ml", "bin/masc_tui_render.ml")
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
    end = output.rfind(h.FRAME_END)
    assert end >= 0, "No completed redraw"
    return bytes(output[:end + len(h.FRAME_END)])


def window(output, columns):
    rows = h.screen_rows(completed(output))
    position, match = next((row, WINDOW.search(text.decode("utf-8")))
        for row, text in sorted(rows.items()) if WINDOW.search(text.decode("utf-8")))
    first, last, total = map(int, match.groups())
    body = []
    for index in range(last - first + 1):
        text = rows.get(position + 1 + index, b"").decode("utf-8", errors="strict")
        assert h.fixture_cell_width(text) <= columns, (columns, text)
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
        h.send_and_wait(process, fd, output, b"\x1b[6~", f"Detail [{expected}-".encode())
    return total, "".join("".join(captured[index].split()) for index in sorted(captured))


def run(executable, columns, no_color):
    fixtures = h.held_back_prompts_http_fixtures()
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
    fixtures["/api/v1/prompts"] = h.SequencedHttpResponse([
        (200, catalog), (503, {"error": ERROR}), (200, catalog)])

    def interact(process, fd, _slave, output, _base):
        h.tab_until(process, fd, output, b"MASC System")
        for _ in range(8):
            if "MASC 프롬프트".encode() in bytes(output):
                break
            h.send_and_wait(process, fd, output, b"p", b"MASC ")
        else:
            raise AssertionError("prompts pane not reached")
        h.wait_for_output(process, fd, output, b"KEYTAIL", start=0, timeout=10)
        h.read_available(fd, output)
        start = len(output)
        h.resize_and_wait(process, fd, output, rows=18, columns=columns,
                          needle=b"KEYTAIL", controls=(h.FULL_REDRAW,))
        h.wait_for_output(process, fd, output, h.FRAME_END,
                          start=h.end_of_needle(output, b"KEYTAIL", start), timeout=3)
        assert "Esc:back" in h.screen_text(completed(output)).decode("utf-8")
        initial_total, text = collect(process, fd, output, columns)
        for field in (KEY, FILE, "템플릿변수:"+VARIABLE, BODY, REASON, "DESCRIPTIONTAIL", "다시 저장하면"):
            assert "".join(field.split()) in text, (columns, field, text)
        h.send_and_wait(process, fd, output, b"\x1b[H", b"Detail [1-")
        _, last, _, _ = window(output, columns)
        h.send_and_wait(process, fd, output, b"\x1b[F", f"/{initial_total}]".encode())
        first, shown_last, total, _ = window(output, columns)
        assert total == initial_total and shown_last == total
        assert first == max(1, total-last+1)
        h.send_and_wait(process, fd, output, b"r", "새로고침 실패".encode())
        h.send_and_wait(process, fd, output, b"\x1b[H", b"Detail [1-")
        _, stale = collect(process, fd, output, columns)
        for field in (ERROR, KEY, BODY, REASON):
            assert "".join(field.split()) in stale, (columns, field, stale)
        h.send_and_wait(process, fd, output, b"r", f"/{initial_total}]".encode())
        h.send_and_wait(process, fd, output, b"\x1b[H", b"Detail [1-")
        h.send_and_wait(process, fd, output, b"j", b"SECOND-PROMPT-BODY")
        assert window(output, columns)[0] == 1
        assert "BODYHEAD" not in h.screen_text(completed(output)).decode("utf-8")
        _, secondary = collect(process, fd, output, columns)
        assert "템플릿변수:"+VARIABLE in secondary, (columns, secondary)
        h.send_and_wait(process, fd, output, b"k", f"/{initial_total}]".encode())
        h.send_and_wait(process, fd, output, b"o", b"ASSETTAIL.txt")
        _, assets = collect(process, fd, output, columns)
        for field in (ASSET, ASSET_FILE, ASSET_BODY, "registry override·편집 대상이 아닙니다"):
            assert "".join(field.split()) in assets, (columns, field, assets)
        h.send_and_wait(process, fd, output, b"\x1b[H", b"Detail [1-")
        h.send_and_wait(process, fd, output, b"j", b"SECOND-ASSET-BODY")
        assert window(output, columns)[0] == 1
        assert "ASSETBODYHEAD" not in h.screen_text(completed(output)).decode("utf-8")
        os.write(fd, b"q")

    h.run_terminal_scenario(executable,
        description=f"Prompts full registry/assets {columns} NO_COLOR={no_color}",
        interact=interact, http_fixtures=fixtures,
        extra_env={"NO_COLOR": "1"} if no_color else {})


if __name__ == "__main__":
    for plain in (False, True):
        for width in (30, 40, 60, 80, 120):
            run(os.path.abspath(sys.argv[1]), width, plain)
    print("Prompts complete registry/assets and retained refresh failure: PASS")
