"""Manual native-TUI observation terminal, without screen assertions or mocked HTTP.

Reads JSON key/capture commands from stdin. Captures the actual child's terminal
stream and an interpreted cell buffer; terminal replies are normal VT emulation.
"""
import codecs
import fcntl
import json
import os
from pathlib import Path
import pty
import selectors
import signal
import struct
import sys
import termios
import time

import pyte

config_path = Path('/tmp/masc-addon-goal-resume-20261021/g06-runtime-session.json')
config = json.loads(config_path.read_text())
root = Path(config['workspace'])
capture_root = Path(config['capture_directory'])
columns, rows = 160, 56
pid, master = pty.fork()
if pid == 0:
    fcntl.ioctl(sys.stdin.fileno(), termios.TIOCSWINSZ, struct.pack('HHHH', rows, columns, 0, 0))
    env = {key: os.environ[key] for key in ['PATH', 'HOME', 'TMPDIR', 'LANG', 'USER', 'LOGNAME'] if key in os.environ}
    env.update({'TERM': 'xterm-256color', 'COLORTERM': 'truecolor',
                'MASC_BASE_PATH': str(root), 'MASC_HTTP_PORT': str(config['port'])})
    os.chdir(root)
    os.execvpe(config['tui'], [config['tui'], '--base-path', str(root), '--port', str(config['port'])], env)

config['tui_pid'] = pid
config['terminal'] = {'columns': columns, 'rows': rows, 'type': 'manual PTY / pyte VT cell capture'}
config_path.write_text(json.dumps(config, indent=2) + '\n')
class ObservationScreen(pyte.Screen):
    def write_process_input(self, data):
        os.write(master, data.encode())

    def report_device_status(self, mode, private=False):
        # pyte 0.8.2 does not accept the DEC private cursor-position query.
        # Reply with this terminal's actual cursor, without changing the app.
        if private and mode == 6:
            self.write_process_input(f'\x1b[?{self.cursor.y + 1};{self.cursor.x + 1}R')
        elif not private:
            super().report_device_status(mode)

screen = ObservationScreen(columns, rows)
stream = pyte.Stream(screen)
decoder = codecs.getincrementaldecoder('utf-8')('replace')
selector = selectors.DefaultSelector()
selector.register(master, selectors.EVENT_READ, 'tui')
selector.register(sys.stdin, selectors.EVENT_READ, 'command')
raw = open(capture_root / 'tui-terminal.bin', 'ab', buffering=0)
events = open(capture_root / 'terminal-commands.jsonl', 'a', buffering=1)

def receive():
    try:
        data = os.read(master, 65536)
    except OSError:
        return False
    if not data:
        return False
    raw.write(data)
    text = decoder.decode(data)
    stream.feed(text)
    return True

print(json.dumps({'terminal_pid': pid, 'workspace': str(root), 'commands': 'JSON keys, settle_ms, capture, show; stop to end only this TUI'}), flush=True)
running = True
while running:
    for key, _ in selector.select(timeout=1):
        if key.data == 'tui':
            if not receive():
                running = False
                break
        else:
            line = sys.stdin.readline()
            if not line:
                running = False
                break
            command = json.loads(line)
            events.write(json.dumps({'at': time.time(), **command}) + '\n')
            if command.get('stop'):
                os.kill(pid, signal.SIGTERM)
                running = False
                break
            if 'keys' in command:
                os.write(master, command['keys'].encode())
            until = time.monotonic() + command.get('settle_ms', 500) / 1000
            while time.monotonic() < until:
                ready = selector.select(timeout=max(0, until - time.monotonic()))
                for waiting, _ in ready:
                    if waiting.data == 'tui' and not receive():
                        running = False
            if command.get('capture'):
                label = command['capture']
                text = '\n'.join(row.rstrip() for row in screen.display) + '\n'
                (capture_root / (label + '.txt')).write_text(text)
                cells = [[{'char': screen.buffer[y][x].data, 'fg': screen.buffer[y][x].fg,
                           'bg': screen.buffer[y][x].bg, 'bold': screen.buffer[y][x].bold}
                          for x in range(columns)] for y in range(rows)]
                (capture_root / (label + '-cells.json')).write_text(json.dumps(cells, ensure_ascii=False))
                print(json.dumps({'capture': label, 'child_pid': pid, 'cursor': [screen.cursor.x, screen.cursor.y]}), flush=True)
                if command.get('show', True):
                    print(text, flush=True)
            else:
                print(json.dumps({'sent': True}), flush=True)
try:
    _, code = os.waitpid(pid, os.WNOHANG)
except ChildProcessError:
    code = None
print(json.dumps({'terminal_driver_ended': True, 'child_wait_status': code}), flush=True)
