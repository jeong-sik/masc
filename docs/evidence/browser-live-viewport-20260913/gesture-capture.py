"""Drive an owned native TUI through a forwarding HTTP recorder to real Firefox."""
import base64
import fcntl
import hashlib
import http.server
import json
import math
import os
from pathlib import Path
import re
import select
import signal
import struct
import subprocess
import sys
import termios
import threading
import time
import urllib.error
import urllib.request


def run(*, repo, executable, base, api_port, token, out, observe, navigate):
    sys.path.insert(0, str(repo / 'test'))
    import test_tui_keyboard_input as h
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    receipts, inputs, images = [], [], []
    lock = threading.Lock()

    class Forward(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_args):
            pass

        def forward(self):
            body = self.rfile.read(int(self.headers.get('Content-Length', 0)))
            headers = {k: self.headers[k] for k in ('Authorization', 'Content-Type') if k in self.headers}
            req = urllib.request.Request(f'http://127.0.0.1:{api_port}' + self.path,
                data=body if body else None, headers=headers, method=self.command)
            try:
                response = opener.open(req, timeout=60)
            except urllib.error.HTTPError as error:
                response = error
            with response:
                payload, status = response.read(), response.status
            if self.path.startswith('/api/v1/dashboard/browser-lane/'):
                value = json.loads(payload)
                # Preserve screenshot bytes as an artifact, never auth headers.
                if self.path.endswith('/screenshot') and value.get('ok'):
                    png = base64.b64decode(value['data']['data'], validate=True)
                    sha = hashlib.sha256(png).hexdigest()
                    (out / f'http-image-{sha}.png').write_bytes(png)
                    value['data']['data'] = {'sha256': sha, 'bytes': len(png)}
                with lock:
                    receipts.append({'path': self.path, 'method': self.command,
                        'input': json.loads(body) if body else None, 'status': status,
                        'response': value, 'completed_monotonic': time.monotonic()})
            self.send_response(status)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

        do_GET = forward
        do_POST = forward

    proxy = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Forward)
    threading.Thread(target=proxy.serve_forever, daemon=True).start()
    master, slave = os.openpty()
    raw, process = bytearray(), None
    env = {k: v for k, v in os.environ.items()
           if k in ('HOME', 'PATH', 'LANG', 'LC_ALL', 'TMPDIR', 'USER', 'LOGNAME', 'SHELL')}
    env.update(MASC_BASE_PATH=str(base), MASC_HOST='127.0.0.1', MASC_TOKEN=token,
        MASC_TUI_SYNC='off', MASC_TUI_FORCE_COLOR='1', TERM='xterm-256color',
        NO_PROXY='127.0.0.1,localhost')
    result = {'scope': 'real native TUI keystrokes/mouse reports; unchanged HTTP forwarding; real live Firefox',
              'columns': 130, 'rows': 35, 'inputs': inputs, 'images': images, 'receipts': receipts}

    def wait(needle, start=0):
        h.wait_for_output(process, master, raw, needle, start=start, timeout=30)

    def send(keys, needle):
        h.read_available(master, raw)
        start = len(raw)
        inputs.append({'keys_hex': keys.hex(), 'monotonic': time.monotonic()})
        h.write_all(master, raw, keys)
        wait(needle, start)
        return bytes(raw[start:])

    def image_input(keys, name):
        return record_image(send(keys, b'j/k:center'), name)

    def record_image(frame, name):
        chunks = re.findall(rb'\x1b_G([^;]+);([^\x1b]*)\x1b\\', frame)
        encoded, height = [], None
        for header, payload in chunks:
            fields = dict(part.split(b'=', 1) for part in header.split(b',') if b'=' in part)
            if fields.get(b'a') == b'T':
                assert fields[b'f'] == b'100'
                encoded, height = [payload], int(fields[b'r'])
            elif height is not None and b'm' in fields:
                encoded.append(payload)
            if height is not None and fields.get(b'm') == b'0':
                break
        assert height is not None, 'native TUI emitted no complete PNG placement'
        png = base64.b64decode(b''.join(encoded), validate=True)
        assert png[:8] == b'\x89PNG\r\n\x1a\n'
        width_px, height_px = struct.unpack('>II', png[16:24])
        (out / f'tui-image-{name}.png').write_bytes(png)
        (out / f'tui-image-{name}.pty').write_bytes(raw)
        image = {'name': name, 'png_sha256': hashlib.sha256(png).hexdigest(),
                 'pixel_width': width_px, 'pixel_height': height_px,
                 'placement_rows': height, 'pty_prefix_bytes': len(raw)}
        images.append(image)
        # The terminal declared 10x20 pixel cells. Kitty preserves PNG aspect
        # ratio when only r is given. Caption is three rows; image begins at 4.
        return height * 2 * width_px / height_px, height

    def mouse_point(geometry, x, y):
        columns, rows = geometry
        return max(1, math.floor(x * columns) + 1), 4 + math.floor(y * rows)

    def mouse(geometry, start, end):
        a, b = mouse_point(geometry, *start), mouse_point(geometry, *end)
        return f'\x1b[<0;{a[0]};{a[1]}M\x1b[<0;{b[0]};{b[1]}m'.encode()

    def confirm(label, expected):
        deadline = time.monotonic() + 20
        while True:
            value = observe(label)
            if any(n.get('text') == expected for n in value['nodes']):
                return value
            if time.monotonic() >= deadline:
                raise AssertionError(f'{label}: effect not observed; input will not be replayed')
            h.read_available(master, raw)
            time.sleep(.1)

    try:
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 35, 130, 0, 0))
        os.set_blocking(master, False)
        process = subprocess.Popen([str(executable), '--base-path', str(base),
            '--workspace', base.name, '--port', str(proxy.server_port)], cwd=base, env=env,
            stdin=slave, stdout=slave, stderr=slave, preexec_fn=h.configure_child_terminal, close_fds=True)
        result.update(pid=process.pid, tui_sha256=hashlib.sha256(executable.read_bytes()).hexdigest())
        h.write_all(master, raw, b'\x1b[6;20;10t' + h.GRAPHICS_SUPPORTED_REPLY)
        wait(b'MASC Overview')
        send(b':go Browser Lane\r', b'MASC Browser Lane')
        wait(b'Gesture Lab')
        geometry = image_input(b'\x0f', 'initial')
        geometry = image_input(mouse(geometry, (.5, .06), (.5, .06)), 'clicked')
        confirm('click-observed', 'Details opened by link click')
        before_scroll_sha = images[-1]['png_sha256']
        image_input(b'j', 'scrolled')
        result['immediate_scroll_image_changed'] = images[-1]['png_sha256'] != before_scroll_sha
        confirm('scroll-observed', 'Gesture Lab; Pane scroll=120')
        # An immediate browser capture can precede its next paint. Observe
        # subsequent native TUI frames without sending refresh or replaying j.
        update_deadline = time.monotonic() + 30
        cadence_frames = 0
        while cadence_frames == 0 or images[-1]['png_sha256'] == before_scroll_sha:
            if time.monotonic() >= update_deadline:
                raise AssertionError('scroll image did not update without input')
            start = images[-1]['pty_prefix_bytes']
            wait(b'j/k:center', start)
            record_image(bytes(raw[start:]), 'scroll-cadence-' + str(len(images)))
            cadence_frames += 1
        result['scroll_image_updated_without_additional_input'] = True
        result['cadence_frames_observed_after_scroll'] = cadence_frames
        # Another actor uses the real Browser Lane while this image remains
        # open. Its old viewport is deliberately probed once at the backend;
        # that failed probe is outside the TUI and never counted as a TUI action.
        old_scroll = [row['input'] for row in receipts if row['path'].endswith('/interact')][-1]
        h.read_available(master, raw)
        start = len(raw)
        destination = navigate(old_scroll)
        wait(destination.encode(), start)
        image_start = raw.find(destination.encode(), start)
        wait(b'j/k:center', image_start)
        record_image(bytes(raw[image_start:]), 'external-navigation')
        fresh = confirm('external-navigation-observed', 'Gesture Lab; Pane scroll=0')
        assert fresh['url'] == destination
        image_input(b'j', 'external-navigation-scrolled')
        confirm('new-document-scroll-observed', 'Gesture Lab; Pane scroll=120')
        new_scroll = [row['input'] for row in receipts if row['path'].endswith('/interact')][-1]
        assert new_scroll['expectedUrl'] == destination
        assert new_scroll['viewport']['documentId'] == fresh['documentId']
        assert new_scroll['viewport']['documentId'] != old_scroll['viewport']['documentId']
        result['external_navigation_followed_without_tui_input'] = True
        result['post_navigation_gesture_used_displayed_document'] = True
        actions = [row for row in receipts if row['path'].endswith('/interact')]
        assert [row['input']['action'] for row in actions] == ['click_at','scroll_at','scroll_at']
        assert all(row['status'] == 200 and row['response']['ok'] is True for row in actions)
        send(b'\x1b', b'Gesture Lab')
        send(b's', b'Page content')
        wait(b'Pane scroll=120')
        result['result'] = 'passed'
    except Exception as error:
        result.update(result='failed', error=repr(error))
        raise
    finally:
        original_error = sys.exc_info()[1]
        cleanup_errors = []

        def cleanup(stage, action):
            try:
                action()
            except BaseException as error:
                cleanup_errors.append({'stage': stage, 'error': repr(error)})

        # Each resource has its own cleanup boundary: a failed PTY read/write
        # or process signal must not bypass proxy shutdown or either FD close.
        def drain_exit(timeout):
            deadline = time.monotonic() + timeout
            while process.poll() is None:
                h.read_available(master, raw)
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise subprocess.TimeoutExpired(process.args, timeout)
                select.select([master], [], [], min(.05, remaining))
            h.read_available(master, raw)

        cleanup('read-final-pty', lambda: h.read_available(master, raw))
        if process is not None:
            if process.poll() is None:
                cleanup('terminate-tui', lambda: os.killpg(process.pid, signal.SIGTERM))
                cleanup('wait-terminated-tui', lambda: drain_exit(10))
            if process.poll() is None:
                cleanup('kill-tui', lambda: os.killpg(process.pid, signal.SIGKILL))
                cleanup('wait-killed-tui', lambda: drain_exit(5))
            result['tui_exit'] = process.poll()
            if result['tui_exit'] != 0:
                cleanup_errors.append({'stage': 'tui-exit', 'error': repr(result['tui_exit'])})
        else:
            result['tui_exit'] = None
        cleanup('write-final-pty', lambda: (out / 'tui-gestures.pty').write_bytes(raw))
        cleanup('shutdown-proxy', proxy.shutdown)
        cleanup('close-proxy', proxy.server_close)
        cleanup('close-master', lambda: os.close(master))
        cleanup('close-slave', lambda: os.close(slave))
        result['cleanup_errors'] = cleanup_errors
        if cleanup_errors:
            result['result'] = 'failed'
        cleanup('write-result', lambda: (out / 'tui-gestures.json').write_text(
            json.dumps(result, ensure_ascii=False, indent=2)))
        if cleanup_errors:
            result['result'] = 'failed'
            # A failed report write cannot record itself in that same file.
            # Emit the complete diagnostics independently and fail the run.
            print('Gesture cleanup failed: ' + json.dumps(cleanup_errors), file=sys.stderr)
            if original_error is None:
                raise RuntimeError('Gesture cleanup incomplete: ' + repr(cleanup_errors))
    return result
