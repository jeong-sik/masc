"""An operator can answer outside four offered choices without sending a skip."""
import json
import os
import sys

import tui_keyboard_approvals as _keyboard_approvals
import tui_keyboard_harness as _keyboard_harness

# The sources this scenario stands over. scripts/ci/run-edited-tests.sh runs
# a suite when a pull request changes a path the suite names, so without
# this a change to the drawn text below reaches main with no scenario run.
# The reader's own words ("Questions waiting on you", the empty note) come
# from masc_tui_render_approvals.ml; the composer row's ("Press Enter again to send",
# "wrote: ") from masc_tui_render_prim.ml.
SOURCE_MODULES = (
    "bin/masc_tui_render_approvals.ml",
    "bin/masc_tui_render_approvals.mli",
    "bin/masc_tui_render.ml",
    "bin/masc_tui_render_prim.ml",
    "test/tui_keyboard_approvals.py",
    "test/tui_keyboard_harness.py",
)


def fixtures():
    data, _initial, _new = _keyboard_harness.approval_selection_http_fixtures()
    status, asks = _keyboard_approvals.keeper_asks_response()
    question = asks['asks'][0]['questions'][0]
    question['choices'] = [{'choice_id': f'route-{i}', 'label': f'Route {i}'} for i in range(1, 5)]
    answered = False

    def answer():
        nonlocal answered
        answered = True
        return 200, {'ok': True}

    data[_keyboard_harness.KEEPER_ASKS_PATH] = lambda: (status, {**asks, 'asks': [], 'open_count': 0} if answered else asks)
    data[_keyboard_approvals.KEEPER_ASK_ANSWER_PATH] = answer
    return data


def interaction(requests):
    def interact(process, fd, _slave, output, _base):
        _keyboard_harness.wait_for_output(process, fd, output, b'Health: ', start=0, timeout=10)
        _keyboard_harness.palette_go(process, fd, output, b'go approvals', b'Questions waiting on you')
        _keyboard_harness.send_and_wait(process, fd, output, b'a', b'[5/t] Other: write your own answer')
        _keyboard_harness.send_and_wait(process, fd, output, b'1', b'1 (o) ')
        _keyboard_harness.send_and_wait(process, fd, output, b'5', b'write: ')
        _keyboard_harness.send_and_wait(process, fd, output, b'q5 i s c cancelled draft', b'q5 i s c cancelled draft')
        _keyboard_harness.send_and_wait(process, fd, output, b'\x1b', b'1 (o) ')
        if any(path == _keyboard_approvals.KEEPER_ASK_ANSWER_PATH for path, _ in requests):
            raise AssertionError('cancelling an alternative sent an answer')
        _keyboard_harness.send_and_wait(process, fd, output, b't', b'write: ')
        text = '다른 방법: q5 s c 명령 대신 원문 그대로 답변합니다.'
        _keyboard_harness.send_and_wait(process, fd, output,
                        b'\x1b[200~' + text.encode() + b'\x1b[201~', text.encode())
        _keyboard_harness.send_and_wait(process, fd, output, b'\r', b'wrote: ')
        if any(path == _keyboard_approvals.KEEPER_ASK_ANSWER_PATH for path, _ in requests):
            raise AssertionError('saving the text draft sent it prematurely')
        _keyboard_harness.send_and_wait(process, fd, output, b'\r', b'Press Enter again to send')
        submitted_at = len(output)
        _keyboard_harness.write_all(fd, output, b'\r')
        _keyboard_harness.wait_for_http_request(process, fd, output, requests, path=_keyboard_approvals.KEEPER_ASK_ANSWER_PATH)
        _keyboard_harness.wait_for_output(process, fd, output, b'none -- no Keeper is waiting on a decision',
                          start=submitted_at, timeout=10)
        if any(path != _keyboard_approvals.KEEPER_ASK_ANSWER_PATH
               and not (path == '/mcp' and json.loads(body).get('method') == 'initialize')
               for path, body in requests):
            raise AssertionError(f'answer input escaped into another action: {requests!r}')
        sent = [json.loads(body) for path, body in requests if path == _keyboard_approvals.KEEPER_ASK_ANSWER_PATH]
        if len(sent) != 1:
            raise AssertionError(f'expected exactly one answer, got {len(sent)}')
        expected = [{'question_id': 'q-1', 'response': {'kind': 'wrote', 'text': text}}]
        if sent[0].get('answers') != expected:
            raise AssertionError(f'custom text changed on the wire: {sent[0]!r}')
        os.write(fd, b'q')
    return interact


def run(executable):
    requests = []
    _keyboard_harness.run_terminal_scenario(executable, description='Custom fifth answer',
                            interact=interaction(requests), http_fixtures=fixtures(),
                            http_requests=requests)


if __name__ == '__main__':
    run(os.path.abspath(sys.argv[1]))
    print('Question alternative text: PASS')
