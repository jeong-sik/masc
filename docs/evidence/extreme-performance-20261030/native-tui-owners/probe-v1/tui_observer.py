"""Observe an owned native TUI; never assert screen text or layout.

The first synchronized-output end is transport readiness only. Sent keys and
later frames are separate observations, not per-key acknowledgement or paint.
"""
import errno
import fcntl
import hashlib
import json
import os
from pathlib import Path
import pty
import select
import signal
import struct
import subprocess
import termios
import time
from urllib.request import urlopen


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def health(port):
    with urlopen(f'http://127.0.0.1:{port}/health?full=1', timeout=15) as response:
        value = json.load(response)
    return {key: value.get(key) for key in ('build', 'paths', 'keeper_fibers')}


def observe(*, binary, base, port, server, runtime_instance, out, names):
    out.mkdir(exist_ok=False)
    binary = Path(binary).resolve(strict=True)
    before = health(port)
    if (server.poll() is not None
            or before['build']['runtime_instance_id'] != runtime_instance
            or Path(before['paths']['effective_base_path']).resolve() != base.resolve()):
        raise RuntimeError('owned server identity differs before TUI observation')
    copied = out / 'masc-tui'
    source_sha = sha(binary)
    copied.write_bytes(binary.read_bytes())
    copied.chmod(0o700)
    if sha(copied) != source_sha or sha(binary) != source_sha:
        raise RuntimeError('TUI binary changed while privately copied')
    build = subprocess.run([str(copied), '--build-commit'], capture_output=True, text=True)
    if build.returncode or build.stdout.strip() != before['build']['binary_commit']:
        raise RuntimeError('TUI/server embedded source differs')
    # Same environment isolation as the owner: no operator provider credentials
    # or saved HOME. This is a PTY transport, not a claimed physical emulator.
    guard = base / 'deny-guest-commands'
    env = {'PATH': str(guard) + os.pathsep + os.environ['PATH'], 'LANG': 'C.UTF-8',
           'HOME': str(base / 'home'), 'MASC_BASE_PATH': str(base),
           'MASC_CONFIG_DIR': str(base / '.masc/config'),
           'MASC_CONFIG_BOOTSTRAP': 'skip', 'TERM': 'xterm-256color',
           'MASC_TUI_SYNC': 'on', 'MASC_TUI_FRAME_TIMING': str(out / 'frame-timing.txt')}
    actions = [('keepers', b'3'), ('chat', b'c'),
               ('page-up-1', b'\x1b[5~'), ('page-up-2', b'\x1b[5~'),
               ('page-up-3', b'\x1b[5~'), ('page-down-1', b'\x1b[6~'),
               ('page-down-2', b'\x1b[6~'), ('clear-owned-draft', b'\x15'),
               ('switch-owned-keeper', ('/keeper ' + names[-1]).encode()),
               ('apply-switch', b'\r'), ('leave-chat', b'\x11'),
               ('next-surface-1', b'\t'), ('next-surface-2', b'\t')]
    started = time.perf_counter_ns()
    child, master = pty.fork()
    if child == 0:
        try:
            fcntl.ioctl(1, termios.TIOCSWINSZ, struct.pack('HHHH', 45, 150, 0, 0))
            os.chdir(base)
            os.execve(copied, [str(copied), '--base-path', str(base), '--port', str(port)], env)
        finally:
            os._exit(127)
    raw = bytearray()
    protocol_tail = b''
    events = []
    ready = None
    terminated = None
    status = None
    usage = None
    forced = False
    error = None
    next_action = 0
    try:
        while status is None:
            readable, _, _ = select.select([master], [], [], .02)
            if readable:
                read_start = time.perf_counter_ns()
                try:
                    chunk = os.read(master, 65536)
                except OSError as exc:
                    if exc.errno != errno.EIO:
                        raise
                    chunk = b''
                read_end = time.perf_counter_ns()
                marker = b'\x1b[?2026l'
                protocol_part = protocol_tail + chunk
                ends = protocol_part.count(marker)
                protocol_tail = protocol_part[-(len(marker)-1):]
                raw.extend(chunk)
                if ends:
                    events.append({'kind': 'transport_frame_ends', 'count': ends,
                                   'read_start_ns': str(read_start), 'read_end_ns': str(read_end)})
                    if ready is None:
                        ready = read_end
            now = time.perf_counter_ns()
            if server.poll() is not None:
                error = 'owned server became terminal during TUI observation'
                if terminated is None:
                    os.kill(child, signal.SIGTERM)
                    terminated = now
            if ready is not None and terminated is None:
                if next_action < len(actions) and now-ready >= int((next_action+1)*.4e9):
                    label, data = actions[next_action]
                    write_start = time.perf_counter_ns()
                    sent = os.write(master, data)
                    events.append({'kind': 'sent_input', 'action': label, 'bytes_hex': data.hex(),
                                   'bytes_written': sent, 'write_start_ns': str(write_start),
                                   'write_end_ns': str(time.perf_counter_ns())})
                    next_action += 1
                if next_action == len(actions) and now-ready >= int((len(actions)*.4+1.5)*1e9):
                    os.kill(child, signal.SIGTERM)
                    terminated = now
            elif ready is None and terminated is None and now-started > 20_000_000_000:
                error = 'transport observation window ended without synchronized output'
                os.kill(child, signal.SIGTERM)
                terminated = now
            if terminated is not None and now-terminated > 10_000_000_000 and not forced:
                os.kill(child, signal.SIGKILL)
                forced = True
            reaped, child_status, child_usage = os.wait4(child, os.WNOHANG)
            if reaped:
                status, usage = child_status, child_usage
    except Exception as exc:
        error = type(exc).__name__ + ': ' + str(exc)
    finally:
        if status is None:
            try:
                os.kill(child, signal.SIGKILL)
                forced = True
            except ProcessLookupError:
                pass
            _, status, usage = os.wait4(child, 0)
        os.close(master)
    ended = time.perf_counter_ns()
    try:
        after = health(port)
    except Exception as exc:
        after = {'error': type(exc).__name__ + ': ' + str(exc)}
    (out / 'terminal.bin').write_bytes(raw)
    timing = out / 'frame-timing.txt'
    result = {'scope': 'Native TUI with real owned Keeper owners and a scripted loopback provider. Input writes, protocol frame ends and native phase samples are separate observations. No text/layout assertions, per-key application acknowledgement, physical emulator/paint or real peer authority proof.',
              'source': build.stdout.strip(), 'binary_sha256': source_sha,
              'binary_sha256_after': sha(copied), 'server_before': before, 'server_after': after,
              'same_runtime': after.get('build', {}).get('runtime_instance_id') == runtime_instance,
              'server_pid': server.pid, 'server_returncode_at_end': server.poll(), 'tui_pid': child,
              'started_ns': str(started), 'ended_ns': str(ended),
              'clock': vars(time.get_clock_info('perf_counter')),
              'exit_code': os.waitstatus_to_exitcode(status), 'forced_kill': forced,
              'error': error, 'sent_actions': next_action, 'planned_actions': len(actions),
              'protocol_ready': ready is not None, 'timing_file_present': timing.is_file(),
              'user_cpu_seconds': usage.ru_utime if usage else None,
              'system_cpu_seconds': usage.ru_stime if usage else None,
              'terminal_bytes': len(raw), 'events': events}
    (out / 'observation.json').write_text(json.dumps(result, indent=2)+'\n')
    return result
