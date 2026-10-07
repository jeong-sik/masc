"""Real spectator/menu batches preserve visible cells under DECAWM and EL on resize."""
import base64
import fcntl
import os
import re
import signal
import struct
import sys
import termios
import unicodedata
import urllib.parse
import tui_keyboard_harness as h


def check_frame(frame, rows, cols):
    # xterm: DECAWM off leaves the cursor ON the rightmost cell after writing
    # it; EL 0 clears from that cell inclusively. Counting text width alone
    # misses a trailing EL deleting a full-width title, mosaic or footer.
    # https://invisible-island.net/xterm/ctlseqs/ctlseqs.html
    row = col = 1
    wrap = True
    pending_wrap = False
    screen = [[' '] * cols for _ in range(rows)]
    erased = []
    overwritten = []
    for token in re.split(r'(\x1b\[[0-9;?]*[A-Za-z])', frame.decode('utf-8')):
        if token.startswith('\x1b['):
            if token in ('\x1b[?7l', '\x1b[?7h'):
                wrap = token.endswith('h')
                pending_wrap = False
            elif token.endswith('H'):
                args = token[2:-1].split(';')
                row = int(args[0] or '1')
                col = int(args[1]) if len(args) > 1 else 1
                assert 1 <= row <= rows and 1 <= col <= cols, (row, col, rows, cols)
                pending_wrap = False
            elif token.endswith('K'):
                mode = int(token[2:-1] or '0')
                start, stop = {0: (col - 1, cols), 1: (0, col), 2: (0, cols)}[mode]
                for index in range(start, stop):
                    if screen[row - 1][index] != ' ':
                        erased.append((row, index + 1, screen[row - 1][index]))
                    screen[row - 1][index] = ' '
                pending_wrap = False
            elif token == '\x1b[2J':
                screen = [[' '] * cols for _ in range(rows)]
                pending_wrap = False
            else:
                assert token.endswith('m'), ('unmodeled terminal command', token)
            continue
        for char in token:
            if char == '\r':
                col = 1
                pending_wrap = False
            elif char == '\n':
                row += 1
                assert row <= rows, ('scroll', row, rows)
                pending_wrap = False
            else:
                width = 0 if unicodedata.combining(char) else 2 if unicodedata.east_asian_width(char) in ('W', 'F') else 1
                if width == 0:
                    continue
                if pending_wrap:
                    row += 1
                    col = 1
                    assert row <= rows, ('autowrap scroll', row, rows)
                assert col + width - 1 <= cols, ('overflow', col, width, cols)
                for index in range(col - 1, col - 1 + width):
                    if screen[row - 1][index] != ' ':
                        overwritten.append((row, index + 1, screen[row - 1][index]))
                    screen[row - 1][index] = char if index == col - 1 else ''
                next_col = col + width
                pending_wrap = wrap and next_col > cols
                col = min(cols, next_col)
    assert not erased, ('EL erased freshly rendered content', erased)
    assert not overwritten, ('rendered cells overwritten without repositioning', overwritten)
    assert wrap, 'the batch must restore automatic wrapping'
    return [''.join(line) for line in screen]


def run(executable):
    requests = []

    def loads():
        return [(path, body) for path, body in requests if path in ('/api/v1/msx/load', '/api/v1/msx/disk')]

    def live(path):
        source = urllib.parse.parse_qs(urllib.parse.urlsplit(path).query)['source_kind'][0]
        body = {'state': 'changed', 'source_kind': source, 'change_count': 1,
                'incarnation': source, 'screen': {'format': 'rgb8', 'width': 2, 'height': 1,
                'rgb_base64': base64.b64encode(b'\xff\x00\x00\x00\x00\xff').decode()}}
        if source == 'msx_capture':
            body['frame_number'] = 1
        else:
            body['activity'] = [{'at': 0, 'who': '여러키퍼_' * 10, 'action': '같이 보기'}]
        return 200, body

    def interact(process, master, slave, output, _base):
        def key(value, needle):
            start = len(output)
            os.write(master, value)
            h.wait_for_output(process, master, output, needle, start=start, timeout=8)

        def resize(rows, cols):
            h.read_available(master, output)
            start = len(output)
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', rows, cols, 0, 0))
            os.kill(process.pid, signal.SIGWINCH)
            h.wait_for_output(process, master, output, b'\x1b[?7l', start=start, timeout=8)
            start = output.index(b'\x1b[?7l', start)
            h.wait_for_output(process, master, output, b'\x1b[?7h', start=start, timeout=8)
            h.read_available(master, output)
            frames = re.findall(rb'\x1b\[\?7l.*?\x1b\[\?7h', bytes(output[start:]), re.S)
            assert frames, 'no complete spectator frame'
            try:
                return check_frame(frames[-1], rows, cols)
            except AssertionError as error:
                raise AssertionError({'rows': rows, 'cols': cols,
                    'frame': repr(frames[-1][:1000]), 'failure': error.args}) from error

        key(b':go Collab\r', b'No invites')
        for source in (b'm', b'd'):
            key(source, b'38;2;255;0;0')
            for rows, cols in ((30, 100), (20, 40), (3, 18), (2, 18), (1, 18), (2, 100), (1, 100), (1, 1), (30, 100)):
                screen = resize(rows, cols)
                if (rows, cols) == (20, 40):
                    assert any(line[0] == line[-1] == '▀' for line in screen[1:-1]), (
                        'the full-width mosaic must keep both edge pixels', screen)
                if cols == 18:
                    assert screen[0][-1] == '…', ('truncated title lost its final cell', screen[0])
                    if rows > 1:
                        assert screen[-1][-1] == '…', ('truncated footer lost its final cell', screen[-1])
            key(b'\x1b', b'MASC Collab')
        key(b'g', b'pick a game')
        # More entries than the short viewport must never scroll the terminal's
        # title/footer offscreen. No unacknowledged key burst precedes resize.
        for rows, cols in ((8, 40), (3, 18), (2, 18), (1, 18), (2, 100), (1, 100), (1, 1), (30, 100)):
            screen = resize(rows, cols)
            assert screen[0].strip(), ('menu title disappeared', screen)
            if rows > 1:
                assert screen[-1].strip(), ('menu footer disappeared', screen)
            if (rows, cols) == (8, 40):
                assert any(line.endswith('…') for line in screen[1:-1]), (
                    'full-width unselected game rows lost their last cell', screen)
        # The two watched machines precede the carts. Wait for this actual
        # highlighted load row before hiding it; an unseen Enter must not POST.
        key(b'jj', re.compile(rb'\x1b\[7m[^\r\n]*long-game-[^\r\n]*0\.rom'))
        for rows in (1, 2):
            resize(rows, 100)
            for press in (b'\r', b' '):
                key(press, b'\x1b[?7h')
                assert loads() == [], ('hidden selection mutated the machine', rows, loads())
        resize(3, 100)
        key(b'\r', b'viewport load refused')
        assert len(loads()) == 1, ('a visible selection should reach the fixture once', loads())
        # The refusal occupies the only body row. Enter must first expose the
        # choice again, without repeating the load hidden behind that status.
        key(b'\r', b'\x1b[?7h')
        assert len(loads()) == 1, ('status-only frame repeated an invisible load', loads())
        resize(30, 100)
        key(b'\x1b', b'spectating the server')
        key(b'\x1b', b'MASC Collab')
        key(b'\x1b', b'MASC Dashboard')
        os.write(master, b'q')

    h.run_terminal_scenario(executable, description='MSX and DOS spectator viewport bounds',
        interact=interact, http_requests=requests, http_fixtures={'/api/v1/play/invites': (200, {'invites': []}),
          '/api/v1/lane-addons/live': h.PathHttpResponse(live),
          '/api/v1/msx/carts': (200, {'carts': ['long-game-' + ('x' * 60) + str(i) + '.rom' for i in range(8)]}),
          '/api/v1/msx/load': (200, {'ok': False, 'message': 'viewport load refused'})})
    print('tui play viewport: PASS')


if __name__ == '__main__':
    run(sys.argv[1])
