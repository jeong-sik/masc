"""Both spectator sources stay inside the terminal when resized without cell metrics."""
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
    row = col = 1
    for token in re.split(r'(\x1b\[[0-9;?]*[A-Za-z])', frame.decode('utf-8')):
        if token.startswith('\x1b['):
            if token.endswith('H'):
                args = token[2:-1].split(';')
                row = int(args[0] or '1')
                col = int(args[1]) if len(args) > 1 else 1
                assert 1 <= row <= rows and 1 <= col <= cols, (row, col, rows, cols)
            continue
        for char in token:
            if char == '\r':
                col = 1
            elif char == '\n':
                row += 1
                assert row <= rows, ('scroll', row, rows)
            else:
                width = 0 if unicodedata.combining(char) else 2 if unicodedata.east_asian_width(char) in ('W', 'F') else 1
                assert col + width - 1 <= cols, ('overflow', col, width, cols)
                col += width


def run(executable):
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
            start = len(output)
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', rows, cols, 0, 0))
            os.kill(process.pid, signal.SIGWINCH)
            h.wait_for_output(process, master, output, b'\x1b[?7l', start=start, timeout=8)
            start = output.index(b'\x1b[?7l', start)
            h.wait_for_output(process, master, output, b'\x1b[?7h', start=start, timeout=8)
            h.read_available(master, output)
            frames = re.findall(rb'\x1b\[\?7l(.*?)\x1b\[\?7h', bytes(output[start:]), re.S)
            assert frames, 'no complete spectator frame'
            check_frame(frames[-1], rows, cols)

        key(b':go Collab\r', b'No invites')
        for source in (b'm', b'd'):
            key(source, b'38;2;255;0;0')
            for rows, cols in ((30, 100), (8, 40), (3, 18), (30, 100)):
                resize(rows, cols)
            key(b'\x1b', b'MASC Collab')
        key(b'\x1b', b'MASC Dashboard')
        os.write(master, b'q')

    h.run_terminal_scenario(executable, description='MSX and DOS spectator viewport bounds',
        interact=interact, http_fixtures={'/api/v1/play/invites': (200, {'invites': []}),
          '/api/v1/lane-addons/live': h.PathHttpResponse(live)})
    print('tui play viewport: PASS')


if __name__ == '__main__':
    run(sys.argv[1])
