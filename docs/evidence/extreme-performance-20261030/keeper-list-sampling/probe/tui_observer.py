"""Observe an owned native TUI; never assert screen text or layout.

The first synchronized-output end is transport readiness only. Sent keys and
later frames are separate observations, not per-key acknowledgement or paint.
"""
import errno
import fcntl
import hashlib
import http.client
import json
import os
from pathlib import Path
import pty
import select
import signal
import struct
import sys
import subprocess
import termios
import time


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def health(port):
    connection = http.client.HTTPConnection('127.0.0.1', port, timeout=15)
    try:
        connection.request('GET', '/health?full=1')
        response = connection.getresponse()
        if response.status != 200:
            raise RuntimeError('owned health returned HTTP ' + str(response.status))
        value = json.loads(response.read())
    finally:
        connection.close()
    return {key: value.get(key) for key in ('build', 'paths', 'keeper_fibers')}


def decode_sync_controls(tail, was_open, chunk):
    prefix = b'\x1b[?2026'
    part = tail + chunk
    completed = unpaired_ends = begins = cursor = 0
    is_open = was_open
    while True:
        at = part.find(prefix, cursor)
        if at < 0 or at + len(prefix) >= len(part):
            break
        code = part[at + len(prefix)]
        cursor = at + len(prefix) + 1
        if code == ord('h'):
            begins += 1
            is_open = True
        elif code == ord('l'):
            if is_open:
                completed += 1
                is_open = False
            else:
                unpaired_ends += 1
    return part[-len(prefix):], is_open, {
        'begins': begins, 'completed_blocks': completed, 'unpaired_ends': unpaired_ends}


def parse_native_report(text):
    records = []
    malformed_json = []
    malformed_summary = []
    declared_frames = {}
    declared_stage_calls = 0
    lines = text.splitlines()
    for number, line in enumerate(lines, 1):
        if line.startswith('{'):
            try:
                records.append(json.loads(line))
            except json.JSONDecodeError:
                malformed_json.append(number)
        else:
            try:
                for phase in ('build', 'present'):
                    if line.startswith(phase + ' frames='):
                        declared_frames[phase] = int(line.split()[1].split('=')[1])
                if ((line.startswith('  stage frame=') or line.startswith('  stage outside-build '))
                        and ' calls=' in line):
                    declared_stage_calls += int(line.rsplit('calls=', 1)[1])
            except (IndexError, ValueError):
                malformed_summary.append(number)
    frames = [row for row in records if row.get('schema') == 'masc.tui.frame.v2']
    stages = [row for row in records if row.get('schema') in
              ('masc.tui.stage.v1', 'masc.tui.stage_note.v1')]
    ask_omissions = [row for row in records if 'omissions' in row.get('schema', '')]
    diagnostic_omissions = [line for line in lines if not line.startswith('{') and ' omitted=' in line]
    ordinals = {phase: [row['frame'] for row in frames if row['phase'] == phase]
                for phase in ('build', 'present')}
    consistent = (text.endswith('\n') and not malformed_json and not malformed_summary
        and not ask_omissions and not diagnostic_omissions
        and len(stages) == declared_stage_calls
        and all(declared_frames.get(phase, 0) > 0
                and values == list(range(1, declared_frames[phase]+1))
                for phase, values in ordinals.items()))
    return {'native_raw_frame_records': len(frames), 'native_raw_stage_records': len(stages),
            'native_raw_ask_omissions': ask_omissions, 'native_diagnostic_omissions': diagnostic_omissions,
            'native_declared_frames': declared_frames, 'native_declared_stage_calls': declared_stage_calls,
            'native_malformed_json_lines': malformed_json, 'native_malformed_summary_lines': malformed_summary,
            'native_report_consistent': consistent}


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
    # Same environment isolation as the owner: no operator provider credentials
    # or saved HOME. This is a PTY transport, not a claimed physical emulator.
    guard = base / 'deny-guest-commands'
    # Server discovery prefers the executable's sibling before PATH. Both
    # routes reach this owned fail-fast shim, which can never start a server.
    autostart_log = out / 'denied-autostart.jsonl'
    autostart_shim = out / 'masc'
    autostart_shim.write_text('#!' + sys.executable + '\nimport json,sys,time\n'
        + 'with open(' + repr(str(autostart_log)) + ", 'a') as stream:\n"
        + "    stream.write(json.dumps({'argv':sys.argv,'at_ns':time.perf_counter_ns()})+'\\n')\n"
        + 'sys.exit(126)\n')
    autostart_shim.chmod(0o700)
    env = {'PATH': str(out) + os.pathsep + str(guard) + os.pathsep + os.environ['PATH'], 'LANG': 'C.UTF-8',
           'HOME': str(base / 'home'), 'MASC_BASE_PATH': str(base),
           'MASC_CONFIG_DIR': str(base / '.masc/config'),
           'MASC_CONFIG_BOOTSTRAP': 'skip', 'TERM': 'xterm-256color',
           'MASC_TUI_SYNC': 'on', 'MASC_TUI_FRAME_TIMING': str(out / 'frame-timing.txt')}
    build = subprocess.run([str(copied), '--build-commit'], capture_output=True,
                           text=True, env=env, cwd=base)
    if build.returncode or build.stdout.strip() != before['build']['binary_commit']:
        raise RuntimeError('TUI/server embedded source differs')
    actions = [('keepers', b'3')]
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
    sync_open = False
    events = []
    ready = None
    terminated = None
    status = None
    usage = None
    forced = False
    error = None
    next_action = 0
    pty_eof = False
    profiler = None
    profiler_started = profiler_ended = None
    profiler_forced = False
    profile_command = ['/usr/bin/sample', str(child), '5', '1', '-mayDie', '-file', str(out / 'native-stacks.txt')]

    def consume(chunk, read_start, read_end):
        nonlocal protocol_tail, sync_open, ready
        protocol_tail, sync_open, controls = decode_sync_controls(protocol_tail, sync_open, chunk)
        raw.extend(chunk)
        if any(controls.values()):
            events.append({'kind': 'sync_transport_controls', **controls,
                           'read_start_ns': str(read_start), 'read_end_ns': str(read_end)})
            if controls['completed_blocks'] and ready is None:
                ready = read_end

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
                consume(chunk, read_start, read_end)
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
                    if sent != len(data):
                        raise RuntimeError('partial owned input write; remaining bytes were not replayed')
                    next_action += 1
                if next_action == len(actions) and profiler is None and now-ready >= 1_000_000_000:
                    profiler_started = time.perf_counter_ns()
                    with (out / 'sample.stdout').open('wb') as log, (out / 'sample.stderr').open('wb') as err:
                        profiler = subprocess.Popen(profile_command, stdout=log, stderr=err,
                                                    env=env, cwd=base, start_new_session=True)
                if profiler is not None and profiler_ended is None and profiler.poll() is not None:
                    profiler_ended = time.perf_counter_ns()
                if (next_action == len(actions) and now-ready >= 8_000_000_000
                        and (profiler_ended is not None or now-ready >= 20_000_000_000)):
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
                # A reaped child can leave its final output buffered in the
                # PTY. Drain it through the same decoder before closing master.
                fcntl.fcntl(master, fcntl.F_SETFL,
                            fcntl.fcntl(master, fcntl.F_GETFL) | os.O_NONBLOCK)
                while True:
                    read_start = time.perf_counter_ns()
                    try:
                        chunk = os.read(master, 65536)
                    except OSError as exc:
                        if exc.errno == errno.EIO:
                            pty_eof = True
                            break
                        if exc.errno in (errno.EAGAIN, errno.EWOULDBLOCK):
                            break
                        raise
                    if not chunk:
                        pty_eof = True
                        break
                    consume(chunk, read_start, time.perf_counter_ns())
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
        if profiler is not None:
            if profiler.poll() is None:
                try:
                    os.killpg(profiler.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                profiler_forced = True
            try:
                profiler.wait(timeout=10)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(profiler.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                profiler_forced = True
                profiler.wait()
            if profiler_ended is None:
                profiler_ended = time.perf_counter_ns()
        os.close(master)
    ended = time.perf_counter_ns()
    try:
        after = health(port)
    except Exception as exc:
        after = {'error': type(exc).__name__ + ': ' + str(exc)}
    (out / 'terminal.bin').write_bytes(raw)
    timing = out / 'frame-timing.txt'
    autostart_attempts = [json.loads(row) for row in autostart_log.read_text().splitlines()] if autostart_log.exists() else []
    report = parse_native_report(timing.read_text() if timing.is_file() else '')
    result = {'scope': 'Sampling-instrumented native TUI with real owned Keeper owners and a scripted loopback provider. Input writes, protocol frame ends and native phase samples are separate observations. Sampling overhead is present; timings are not an uninstrumented latency baseline. No text/layout assertions, per-key application acknowledgement, physical emulator/paint or real peer authority proof.',
              'source': build.stdout.strip(), 'binary_sha256': source_sha,
              'binary_sha256_after': sha(copied), 'server_before': before, 'server_after': after,
              'same_runtime': after.get('build', {}).get('runtime_instance_id') == runtime_instance,
              'server_pid': server.pid, 'server_returncode_at_end': server.poll(), 'tui_pid': child,
              'started_ns': str(started), 'ended_ns': str(ended),
              'clock': vars(time.get_clock_info('perf_counter')),
              'exit_code': os.waitstatus_to_exitcode(status), 'forced_kill': forced,
              'error': error, 'sent_actions': next_action, 'planned_actions': len(actions),
              'protocol_ready': ready is not None, 'timing_file_present': timing.is_file(),
              'sync_block_open_at_end': sync_open, 'denied_autostart_attempts': autostart_attempts,
              'observer_source_sha256': sha(Path(__file__)),
              'pty_eof_observed': pty_eof, **report,
              'user_cpu_seconds': usage.ru_utime if usage else None,
              'system_cpu_seconds': usage.ru_stime if usage else None,
              'terminal_bytes': len(raw), 'events': events}
    result['profiler'] = {'command':profile_command, 'returncode':profiler.returncode if profiler else None,
        'started_ns':str(profiler_started) if profiler_started is not None else None,
        'ended_ns':str(profiler_ended) if profiler_ended is not None else None,
        'forced':profiler_forced, 'report_sha256':sha(out/'native-stacks.txt') if (out/'native-stacks.txt').is_file() else None}
    result['capture_qualified'] = (result['exit_code'] == 0 and not forced and error is None
        and result['same_runtime'] and result['server_returncode_at_end'] is None
        and result['binary_sha256_after'] == source_sha and ready is not None
        and next_action == len(actions) and not sync_open and not autostart_attempts
        and pty_eof and report['native_report_consistent']
        and profiler is not None and profiler.returncode == 0 and not profiler_forced
        and (out/'native-stacks.txt').is_file())
    result['qualification_scope'] = 'Transport/control and native phase capture only; input application, complete stage coverage, peer effects, physical paint and the performance target are not certified.'
    (out / 'observation.json').write_text(json.dumps(result, indent=2)+'\n')
    return result
