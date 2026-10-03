"""Read complete Tools metadata through physical rows at real pane widths."""
import os
import re
import sys
import unicodedata
import test_tui_keyboard_input as h


PATH = '.masc/skills/' + '한글-root-' * 35 + 'PATHEND'
REVISION = 'revision-' + 'r' * 85 + '-REVEND'
REJECT_REVISION = 'rejected-' + 'j' * 85 + '-REJECTREVEND'
REJECTION = 'REJECTHEAD preserve `literal` **/*.ml [draft](target) ' + '한글 reason ' * 40 + 'REJECTEND'
NODE = 'node-' + 'n' * 95 + '-NODEEND'
TOOL = 'tool-' + 't' * 95 + '-TOOLEND'
DEPENDENCY = 'depends-' + 'd' * 95 + '-DEPENDEND'
UNAVAILABLE = 'UNAVAILABLEHEAD ' + '한글 ledger ' * 35 + 'UNAVAILABLEEND'
TIMESTAMP = '2026-08-28T03:04:05.123456789Z'
WINDOW = re.compile(r'\[rows (\d+)-(\d+)/(\d+)\]')


def cell_width(text):
    return sum(0 if unicodedata.combining(c) else
               2 if unicodedata.east_asian_width(c) in ('W', 'F') else 1 for c in text)


def fixtures():
    result = h.skills_usage_clarity_http_fixtures(unavailable=(UNAVAILABLE,))
    payload = result['/api/v1/skills'][1]
    snapshot = payload['snapshot']
    snapshot['config'] = {'kind': 'configured', 'revision': REVISION, 'resource_read_max_bytes': 65536}
    snapshot['sources'] = [{'id': 'workspace', 'anchor': 'base-path', 'path': PATH,
                            'access': 'read-only', 'observation': {'kind': 'ready', 'candidates': 1}}]
    snapshot['rejections'] = [{'source_index': 0, 'source_id': 'workspace', 'package_id': 'broken',
        'content_revision': REJECT_REVISION, 'reason': {'kind': 'document_rejected', 'diagnostics': [{
        'code': 'name_mismatch', 'message': REJECTION, 'declared': 'declared', 'directory': 'broken'}]}}]
    surface = payload['surfaces'][0]
    surface['kind'] = 'composition'
    surface['usage'][0]['last_used_at'] = TIMESTAMP
    surface['profile']['flow'] = {
        'nodes': [{'id': NODE, 'tool_name': TOOL, 'dependencies': [{'node_id': DEPENDENCY, 'kind': 'data'}],
                   'batch_index': 7, 'execution_mode': 'serial'},
                  {'id': 'unbatched-node', 'tool_name': 'unbatched-tool', 'dependencies': [],
                   'batch_index': 8, 'execution_mode': 'parallel'}],
        'batches': [{'index': 7, 'execution_mode': 'serial', 'node_ids': [NODE]}]}
    return result


def completed(output):
    end = output.rfind(h.FRAME_END)
    assert end >= 0, 'No completed redraw'
    return bytes(output[:end + len(h.FRAME_END)])


def window(output, columns):
    rows = h.screen_rows(completed(output))
    counter_row, match = next((row, WINDOW.search(text.decode('utf-8')))
        for row, text in sorted(rows.items()) if WINDOW.search(text.decode('utf-8')))
    first, last, total = map(int, match.groups())
    height = last - first + 1
    body = []
    for row in range(counter_row - height, counter_row):
        line = rows[row].decode('utf-8', errors='strict')
        assert cell_width(line) <= columns, (columns, cell_width(line), line)
        # Card borders surround the metadata, and are not metadata bytes.
        body.append(line.strip().strip('│').strip())
    return first, last, total, body


def run(binary, columns, no_color):
    def interact(process, fd, _slave, output, _base):
        h.tab_until(process, fd, output, b'MASC System')
        h.send_and_wait(process, fd, output, b't', b'MASC System / Tools')
        h.send_and_wait(process, fd, output, b'p' * 3, b'1 of 2 catalog Skills observed')
        h.read_available(fd, output)
        start = len(output)
        h.resize_and_wait(process, fd, output, rows=18, columns=columns,
                          needle=b'[rows 1-', controls=(h.FULL_REDRAW,))
        h.wait_for_output(process, fd, output, h.FRAME_END,
                          start=h.end_of_needle(output, b'[rows 1-', start), timeout=3)
        collected = {}
        while True:
            first, last, total, body = window(output, columns)
            collected.update((first + index, line) for index, line in enumerate(body))
            if last == total:
                break
            height = last - first + 1
            target = min(total - height + 1, first + max(1, height - 1))
            h.send_and_wait(process, fd, output, b'\x1b[6~', f'[rows {target}-'.encode())
        compact = ''.join(''.join(collected[i].split()) for i in sorted(collected))
        for value in (PATH, REVISION, REJECT_REVISION, REJECTION, NODE, TOOL, DEPENDENCY, UNAVAILABLE,
                      TIMESTAMP, 'unbatched-node', 'unbatched-tool', 'kind:data', 'batch:8'):
            assert ''.join(value.split()) in compact, (columns, no_color, value, compact)
        h.send_and_wait(process, fd, output, b'\x1b[H', b'[rows 1-')
        first, last, total, _ = window(output, columns)
        height = last - first + 1
        h.send_and_wait(process, fd, output, b'\x1b[F', f'[rows {max(1,total-height+1)}-'.encode())
        assert window(output, columns)[1] == total
        h.send_and_wait(process, fd, output, b'\x1b[H', b'[rows 1-')
        assert window(output, columns)[0] == 1
        print(f'TOOLS_LAYOUT_PTY width={columns} NO_COLOR={no_color}: full metadata/pages/edges PASS', flush=True)
        os.write(fd, b'q')
    h.run_terminal_scenario(binary, description=f'Tools complete metadata {columns} NO_COLOR={no_color}',
        interact=interact, http_fixtures=fixtures(), extra_env={'NO_COLOR': '1'} if no_color else {})


if __name__ == '__main__':
    for plain in (False, True):
        for width in (30, 40, 60, 80, 120):
            run(os.path.abspath(sys.argv[1]), width, plain)
    print('Tools complete metadata and physical viewport: PASS')
