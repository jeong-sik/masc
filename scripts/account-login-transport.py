#!/usr/bin/env python3
"""Private bidirectional login transport; never records terminal input/output.

The native caller supplies only a resolved argv and account environment. Commands
on stdin are NDJSON; stdout contains output chunks and one process-exit record.
Authentication is observed by the caller, never inferred from terminal text.
"""
import codecs
import errno
import json
import os
import pty
import select
import signal
import subprocess
import sys
import termios


KEYS = {'enter': b'\r', 'up': b'\x1b[A', 'down': b'\x1b[B',
        'tab': b'\t', 'eof': b'\x04'}


def emit(event, **fields):
    print(json.dumps(dict(event=event, **fields)), flush=True)


def suppress_echo(fd):
    attributes = termios.tcgetattr(fd)
    attributes[3] &= ~(termios.ECHO | termios.ECHONL)
    termios.tcsetattr(fd, termios.TCSANOW, attributes)


def kill_group(pid):
    try:
        os.killpg(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    except PermissionError:
        # Darwin reports EPERM for a group containing only its reserved zombie
        # leader. Keep failures against a still-running leader visible. WNOWAIT
        # retains the PID reservation until the caller reaps it below.
        observed = os.waitid(os.P_PID, pid, os.WEXITED | os.WNOHANG | os.WNOWAIT)
        if sys.platform != 'darwin' or observed is None:
            raise


def run(argv, terminal):
    child = None
    pid = None
    input_fd = None
    outputs = {}
    interrupted = False
    pending = b''
    queued_input = bytearray()
    input_eof = False
    pending_acks = 0
    status = None

    def interrupt(_signum, _frame):
        nonlocal interrupted
        interrupted = True

    previous = {sig: signal.signal(sig, interrupt)
                for sig in (signal.SIGTERM, signal.SIGINT)}
    try:
        if terminal:
            pid, master = pty.fork()
            if pid == 0:
                try:
                    # Configure the slave before the client can print a prompt
                    # or receive a code. Disable newline echo independently.
                    suppress_echo(0)
                    os.execvpe(argv[0], argv, os.environ)
                except OSError:
                    os._exit(127)
            input_fd = master
            suppress_echo(master)
            outputs[master] = ('terminal', codecs.getincrementaldecoder('utf-8')('replace'))
        else:
            child = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=subprocess.PIPE, start_new_session=True)
            pid = child.pid
            input_fd = child.stdin.fileno()
            outputs = {stream.fileno(): (name, codecs.getincrementaldecoder('utf-8')('replace'))
                       for name, stream in (('stdout', child.stdout), ('stderr', child.stderr))}
        os.set_blocking(input_fd, False)
        while not interrupted:
            # WNOWAIT reserves the leader's PID until its complete group is gone.
            # This detects a leader exiting while a descendant still holds pipes.
            if status is None:
                observed = os.waitid(os.P_PID, pid, os.WEXITED | os.WNOHANG | os.WNOWAIT)
                if observed is not None:
                    status = observed.si_status if observed.si_code == os.CLD_EXITED else -observed.si_status
                    kill_group(pid)
            if status is not None and not outputs:
                break
            if status is not None:
                queued_input.clear()
                pending_acks = 0
            # Transport responsiveness, not an authentication/session deadline.
            writable_input = [input_fd] if input_fd is not None and queued_input else []
            readable, writable, _ = select.select([0, *outputs], writable_input, [], 0.1)
            for fd in readable:
                if fd == 0:
                    data = os.read(0, 65536)
                    if not data:
                        interrupted = True
                        break
                    pending += data
                    while b'\n' in pending:
                        line, pending = pending.split(b'\n', 1)
                        command = json.loads(line)
                        if command == {'kind': 'cancel'}:
                            interrupted = True
                            queued_input.clear()
                            break
                        if status is not None:
                            continue
                        if set(command) == {'kind', 'text'} and command['kind'] == 'text' and isinstance(command['text'], str):
                            data = command['text'].encode() + (b'\r' if terminal else b'\n')
                        elif set(command) == {'kind', 'key'} and command['kind'] == 'key' and command['key'] in KEYS:
                            if not terminal and command['key'] == 'eof':
                                input_eof = True
                                pending_acks += 1
                                continue
                            data = KEYS[command['key']]
                            if not terminal and command['key'] == 'enter':
                                data = b'\n'
                        else:
                            raise ValueError('invalid input')
                        if input_fd is not None and not input_eof:
                            queued_input.extend(data)
                            pending_acks += 1
                else:
                    name, decoder = outputs[fd]
                    try:
                        data = os.read(fd, 65536)
                    except OSError as error:
                        if error.errno != errno.EIO:
                            raise
                        data = b''
                    text = decoder.decode(data, final=not data)
                    if text:
                        emit('output', stream=name, text=text)
                    if not data:
                        del outputs[fd]
            # Read cancellation/disconnect before offering queued data to the
            # client. A full pipe must never prevent control-plane progress.
            if interrupted:
                queued_input.clear()
                break
            if input_fd in writable and queued_input:
                try:
                    if terminal:
                        suppress_echo(input_fd)
                    written = os.write(input_fd, queued_input)
                    del queued_input[:written]
                except BlockingIOError:
                    pass
                except OSError as error:
                    if error.errno not in (errno.EPIPE, errno.EIO):
                        raise
                    queued_input.clear()
                    pending_acks = 0
                    input_eof = not terminal
            if input_eof and not queued_input and input_fd is not None:
                child.stdin.close()
                input_fd = None
            if not queued_input:
                for _ in range(pending_acks):
                    emit('input_ready')
                pending_acks = 0
        if interrupted:
            emit('cancelled')
        else:
            emit('exited', code=status)
    finally:
        if pid is not None and pid > 0:
            kill_group(pid)
            if child is not None:
                child.wait()
                for stream in (child.stdin, child.stdout, child.stderr):
                    stream.close()
            else:
                os.waitpid(pid, 0)
                os.close(input_fd)
        for sig, handler in previous.items():
            signal.signal(sig, handler)


if __name__ == '__main__':
    try:
        mode, *command = sys.argv[1:]
        if mode not in ('pipe', 'pty') or not command:
            raise ValueError('invalid invocation')
        run(command, mode == 'pty')
    except (OSError, ValueError, TypeError, KeyError):
        # No traceback, argv, input, or provider diagnostics in server logs.
        emit('transport_error')
        sys.exit(1)
