#!/usr/bin/env python3
"""PTY transport for zero-prompt Antigravity status-line observations.

Native code owns HOME/auth setup, settings, model identity and payload validation.
This process never sends terminal input and never retains the rendered terminal.
"""
import argparse
import errno
import json
import math
import os
from pathlib import Path
import pty
import select
import signal
import stat
import subprocess
import sys
import time


def unique_object(pairs):
    result = dict(pairs)
    if len(result) != len(pairs):
        raise ValueError('duplicate status fields')
    return result


def project(payload):
    if not isinstance(payload, dict):
        raise ValueError('status object required')
    model = payload.get('model')
    if isinstance(model, dict):
        model = {name: model.get(name) for name in ('id', 'display_name')}
    context = payload.get('context_window')
    if isinstance(context, dict):
        context = {name: context.get(name) for name in
                   ('total_input_tokens', 'total_output_tokens', 'context_window_size', 'current_usage')}
        if isinstance(context['current_usage'], dict):
            context['current_usage'] = {name: context['current_usage'].get(name) for name in
                                        ('input_tokens', 'output_tokens', 'cache_creation_input_tokens', 'cache_read_input_tokens')}
    return {'model': model, 'version': payload.get('version'), 'context_window': context}


def capture(path):
    # Only the safe projection reaches disk; email, transcript paths and the full
    # callback payload are neither logged nor forwarded to the native process.
    payload = project(json.load(sys.stdin, object_pairs_hook=unique_object))
    data = (json.dumps(payload, separators=(',', ':'))+'\n').encode()
    fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_NOFOLLOW)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o077:
            raise ValueError('unsafe status transport')
        if os.write(fd, data) != len(data):
            raise OSError('incomplete status write')
    finally:
        os.close(fd)
    print('MASC context observation')


def records(path):
    data = Path(path).read_bytes()
    # An in-flight callback append is not a complete transport record yet.
    lines = data.split(b'\n')[:-1]
    return [json.loads(line, object_pairs_hook=unique_object) for line in lines if line]


def transport_ready(rows):
    # Only ends the transport wait. Native parse_context still validates every
    # collected record's model, CLI version, zero-token usage and capacity.
    for row in rows:
        context = row.get('context_window')
        model = row.get('model')
        if isinstance(context, dict) and isinstance(model, dict):
            size = context.get('context_window_size')
            if type(size) is int and size > 0 and isinstance(model.get('id'), str):
                return True
    return False


def observe(args):
    master, slave = pty.openpty()
    process = None
    result = {'schema': 'masc.antigravity_status_transport.v1', 'status': 'failed', 'records': []}
    interrupted = False
    def interrupt(signum, frame):
        nonlocal interrupted
        interrupted = True
    previous = {sig: signal.signal(sig, interrupt) for sig in (signal.SIGTERM, signal.SIGINT)}
    try:
        process = subprocess.Popen([args.cli, '--model', args.model], cwd=args.home,
                                   stdin=slave, stdout=slave, stderr=slave, start_new_session=True)
        os.close(slave)
        slave = None
        deadline = time.monotonic()+args.timeout
        while not interrupted:
            rows = records(args.records)
            if transport_ready(rows):
                result.update(status='captured', records=rows)
                break
            remaining = deadline-time.monotonic()
            if remaining <= 0:
                result.update(status='timed_out', records=rows)
                break
            readable, _, _ = select.select([master], [], [], remaining)
            if readable:
                try:
                    data = os.read(master, 65536)  # discard terminal output immediately
                except OSError as error:
                    if error.errno != errno.EIO:
                        raise
                    data = b''
                if not data:
                    rows = records(args.records)
                    result.update(status='captured' if rows else 'failed', records=rows)
                    break
        if interrupted:
            result.update(status='interrupted')
    finally:
        if slave is not None:
            os.close(slave)
        if process is not None:
            # Do not poll/reap first: the unreaped leader reserves this PID/PGID,
            # including when it exited while a status-line child is still alive.
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()
        os.close(master)
        for sig, handler in previous.items():
            signal.signal(sig, handler)
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--capture')
    parser.add_argument('--home')
    parser.add_argument('--cli')
    parser.add_argument('--model')
    parser.add_argument('--records')
    parser.add_argument('--timeout', type=float)
    parser.add_argument('--version-probe', action='store_true')
    args = parser.parse_args()
    try:
        if args.capture:
            capture(args.capture)
            return
        if args.version_probe:
            os.chdir(args.home)
            os.execv(args.cli, [args.cli, '--version'])
        if not args.home or not args.cli or not args.model or not args.records or not args.timeout or not math.isfinite(args.timeout) or args.timeout <= 0:
            raise ValueError('invalid context transport arguments')
        print(json.dumps(observe(args)))
    except (OSError, ValueError, TypeError, KeyError):
        print(json.dumps({'schema': 'masc.antigravity_status_transport.v1', 'status': 'failed', 'records': []}))
        sys.exit(1)


if __name__ == '__main__':
    main()
