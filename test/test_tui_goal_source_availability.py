"""Actual HTTP/PTY Goal source errors differ from a successfully empty store."""
import base64
import hashlib
import json
import os
from pathlib import Path
import sys
import zlib

import test_tui_keyboard_input as h


def run(executable):
    fixtures = h.overview_event_http_fixtures()
    cause = 'goals.json: criterion_revision missing'
    failure = {'ok': False, 'error_code': 'goal_store_unavailable', 'error': cause}
    current = [200, failure]
    reads = []

    def planning():
        reads.append({'path': h.PLANNING_PATH, 'response': current[1]})
        return tuple(current)

    detail_path = '/api/v1/dashboard/goals/detail?goal_id=source-goal'

    def detail():
        reads.append({'path': detail_path, 'response': failure})
        return 200, failure

    fixtures[h.PLANNING_PATH] = planning
    fixtures[detail_path] = detail

    def interact(process, master, _slave, output, _base):
        def capture(scenario, needle, columns):
            h.read_available(master, output)
            before = len(output)
            h.resize_and_wait(process, master, output, rows=40, columns=columns,
                              needle=needle, controls=(h.FULL_REDRAW,))
            redraw = output.find(h.FULL_REDRAW, before)
            assert redraw >= 0
            h.wait_for_output(process, master, output, h.FRAME_END, start=redraw, timeout=3.0)
            end = output.find(h.FRAME_END, redraw) + len(h.FRAME_END)
            start = output.rfind(h.FRAME_START, before, redraw)
            assert start >= 0
            frame = bytes(output[start:end])
            screen = h.screen_text(frame)
            if scenario == 'empty-ready':
                assert cause.encode() not in screen, screen
                assert b'(no goals)' in screen, screen
            else:
                assert cause.encode() in screen, screen
                assert b'approval queue store is unreadable' not in screen, screen
                if scenario == 'source-unavailable':
                    assert b'(no goals)' not in screen, screen
            print('GOAL_SOURCE_PTY_EVIDENCE ' + json.dumps({
                'scenario': scenario, 'http_reads': list(reads), 'rows': 40, 'columns': columns,
                'binary_sha256': hashlib.sha256(Path(executable).read_bytes()).hexdigest(),
                'frame_sha256': hashlib.sha256(frame).hexdigest(),
                'encoding': 'zlib+base64', 'pty': base64.b64encode(zlib.compress(frame)).decode(),
            }), flush=True)

        h.palette_go(process, master, output, b'go Planning', cause.encode())
        capture('source-unavailable', cause.encode(), 140)
        current[:] = h.planning_snapshot([])
        h.send_and_wait(process, master, output, b'r', b'(no goals)')
        capture('empty-ready', b'(no goals)', 141)
        current[:] = h.planning_snapshot([h.planning_goal('source-goal', 'source-goal-loaded')])
        h.send_and_wait(process, master, output, b'r', b'source-goal-loaded')
        h.send_and_wait(process, master, output, b'\x1b[C', cause.encode())
        capture('detail-unavailable', cause.encode(), 140)
        assert any(row['path'] == detail_path for row in reads), reads
        os.write(master, b'q')

    h.run_terminal_scenario(executable, description='Goal source failure and recovery',
                            interact=interact, http_fixtures=fixtures)


if __name__ == '__main__':
    run(os.path.abspath(sys.argv[1]))
    print('TUI Goal source failure and recovery: PASS')
