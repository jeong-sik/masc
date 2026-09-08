"""An operator can answer outside four offered choices without sending a skip."""
import json
import os
import sys
import test_tui_keyboard_input as h


def fixtures():
    data, _initial, _new = h.approval_selection_http_fixtures()
    status, asks = h.keeper_asks_response()
    question = asks['asks'][0]['questions'][0]
    question['choices'] = [{'choice_id': f'route-{i}', 'label': f'Route {i}'} for i in range(1, 5)]
    answered = False

    def answer():
        nonlocal answered
        answered = True
        return 200, {'ok': True}

    data[h.KEEPER_ASKS_PATH] = lambda: (status, {**asks, 'asks': [], 'open_count': 0} if answered else asks)
    data[h.KEEPER_ASK_ANSWER_PATH] = answer
    return data


def interaction(requests):
    def interact(process, fd, _slave, output, _base):
        h.wait_for_output(process, fd, output, b'cluster-a', start=0, timeout=10)
        h.palette_go(process, fd, output, b'go approvals', b'Questions waiting on you')
        h.send_and_wait(process, fd, output, b'a', b'[5/t] Other: write your own answer')
        h.send_and_wait(process, fd, output, b'1', b'1 (o) ')
        h.send_and_wait(process, fd, output, b'5', b'write: ')
        h.send_and_wait(process, fd, output, b'cancelled draft', b'cancelled draft')
        h.send_and_wait(process, fd, output, b'\x1b', b'1 (o) ')
        if any(path == h.KEEPER_ASK_ANSWER_PATH for path, _ in requests):
            raise AssertionError('cancelling an alternative sent an answer')
        h.send_and_wait(process, fd, output, b't', b'write: ')
        text = '다른 방법: q5 s c 명령 대신 원문 그대로 답변합니다.'
        h.send_and_wait(process, fd, output,
                        b'\x1b[200~' + text.encode() + b'\x1b[201~', text.encode())
        h.send_and_wait(process, fd, output, b'\r', b'wrote: ')
        if any(path == h.KEEPER_ASK_ANSWER_PATH for path, _ in requests):
            raise AssertionError('saving the text draft sent it prematurely')
        h.send_and_wait(process, fd, output, b'\r', b'Press Enter again to send')
        submitted_at = len(output)
        h.write_all(fd, b'\r')
        h.wait_for_http_request(process, fd, output, requests, path=h.KEEPER_ASK_ANSWER_PATH)
        h.wait_for_output(process, fd, output, b'none -- no Keeper is waiting on a decision',
                          start=submitted_at, timeout=10)
        sent = [json.loads(body) for path, body in requests if path == h.KEEPER_ASK_ANSWER_PATH]
        if len(sent) != 1:
            raise AssertionError(f'expected exactly one answer, got {len(sent)}')
        expected = [{'question_id': 'q-1', 'response': {'kind': 'wrote', 'text': text}}]
        if sent[0].get('answers') != expected:
            raise AssertionError(f'custom text changed on the wire: {sent[0]!r}')
        os.write(fd, b'q')
    return interact


def run(executable):
    requests = []
    h.run_terminal_scenario(executable, description='Custom fifth answer',
                            interact=interaction(requests), http_fixtures=fixtures(),
                            http_requests=requests)


if __name__ == '__main__':
    run(os.path.abspath(sys.argv[1]))
    print('Question alternative text: PASS')
