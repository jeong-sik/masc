"""Drain worker output while feeding bulk MCP fixture input.

Some fixtures exceed the host's small pipe capacity in both directions. A
writer thread makes progress independent of the stdout reader; neither side
waits for the other's entire batch before reading. This is test transport only.
"""
from __future__ import annotations

import subprocess
import threading


def run_stdio(args, *, input, capture_output=True, text=True, check=True,
              timeout=10, cwd=None):
    assert capture_output and text
    process = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, text=True, cwd=cwd)
    pipe = process.stdin
    process.stdin = None  # communicate owns reads; the writer owns this pipe.
    errors = []
    def feed():
        try:
            with pipe:
                pipe.write(input)
        except (BrokenPipeError, OSError) as error:
            errors.append(error)
    writer = threading.Thread(target=feed)
    writer.start()
    try:
        stdout, stderr = process.communicate(timeout=timeout)
    except BaseException:
        process.kill()
        process.communicate()
        raise
    finally:
        writer.join()
    if check and process.returncode:
        raise subprocess.CalledProcessError(process.returncode, args, stdout, stderr)
    if errors:
        raise errors[0]
    return subprocess.CompletedProcess(args, process.returncode, stdout, stderr)
