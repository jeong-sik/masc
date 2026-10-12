"""Actual candidate TUI and HTTP server: no fixture API, no shared runtime."""
import fcntl
import json
import os
import re
from pathlib import Path
import select
import struct
import subprocess
import sys
import termios
import time

executable, base, port, token_file, output = sys.argv[1:]
output = Path(output)
master, slave = os.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 40, 140, 0, 0))
os.set_blocking(master, False)
environment = {key:value for key,value in os.environ.items()
               if not key.startswith('MASC_') and key not in ('NO_COLOR', 'TMUX', 'LINES', 'COLUMNS')}
environment.update(MASC_BASE_PATH=base, MASC_HOST='127.0.0.1', MASC_TUI_SYNC='off',
                   TERM='xterm-256color', MASC_TOKEN=Path(token_file).read_text().strip())
process = subprocess.Popen([executable, '--base-path', base, '--port', port, '--refresh', '5'],
    stdin=slave, stdout=slave, stderr=slave, env=environment, start_new_session=True)
wire = bytearray()

def read():
    if select.select([master], [], [], 0.1)[0]:
        try: wire.extend(os.read(master, 65536))
        except BlockingIOError: pass

def wait(needle, start=0):
    deadline = time.monotonic() + 25
    while needle not in wire[start:]:
        if process.poll() is not None: raise RuntimeError('TUI exited before expected content')
        if time.monotonic() > deadline: raise RuntimeError('Missing TUI content: ' + repr(needle))
        read()

def key(value, needle):
    start = len(wire)
    os.write(master, value)
    wait(needle, start)
    return start

def wait_dos_pixels(start):
    deadline = time.monotonic() + 25
    while True:
        frames = re.findall(rb'\x1b\[\?7l.*?\x1b\[\?7h', bytes(wire[start:]), re.S)
        for frame in frames:
            # Only a completed DOS spectator draw after opening this viewer is
            # evidence. Dashboard text also contains true-colour ANSI escapes.
            if b'DOS ' not in frame:
                continue
            if re.search(rb'\x1b\[38;2;\d+;\d+;\d+m', frame) and '▀'.encode() in frame:
                return
        if process.poll() is not None: raise RuntimeError('TUI exited before DOS pixels')
        if time.monotonic() > deadline: raise RuntimeError('Missing fresh DOS mosaic frame')
        read()

try:
    wait(b'MASC Dashboard')
    key(b':go Collab\r', b'MASC Collab')
    dos_start = key(b'd', b'Browser-to-TUI')
    wait_dos_pixels(dos_start)
    key(b'\t', '대화 · Enter'.encode())
    payload = 'TUI-to-browser 한글'.encode()
    key(b'\x1b[200~' + payload + b'\x1b[201~', payload)
    key(b'\r', '▶ play-proof'.encode())
    key(b'\x1b', b'Esc: back')
    key(b'\x1b[14~', b'MSX ')
    key(b'\x1b', b'MASC Collab')
    key(b'\x1b', b'MASC Dashboard')
    os.write(master, b'qq')
    deadline = time.monotonic() + 15
    while process.poll() is None and time.monotonic() < deadline: read()
    assert process.wait(timeout=1) == 0
    (output / 'tui-client.json').write_text(json.dumps({'pass':True,
      'checks':['real DOS emulator pixels drawn', 'real browser message visible', 'Korean-safe public composer', 'real TUI message sent',
                'same viewer switches MSX/DOS', 'normal exit']}, indent=2))
    print('Actual candidate TUI public room: PASS')
finally:
    if process.poll() is None:
        process.terminate()
        try: process.wait(timeout=5)
        except subprocess.TimeoutExpired: process.kill(); process.wait()
    (output / 'tui-client.raw').write_bytes(wire)
    os.close(master)
    os.close(slave)
