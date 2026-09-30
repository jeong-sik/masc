"""Read complete judgement identities and literal evidence at actual pane widths."""
import json
import os
from pathlib import Path
import re
import sys
import unicodedata
import test_tui_keyboard_input as h

SOURCE_MODULES = (
    "bin/masc_tui_render.ml",
    "bin/masc_tui.ml",
    "bin/masc_tui_render_prim.ml",
    "bin/masc_tui_render_approvals.ml",
    "bin/masc_tui_render_approvals.mli",
)
TASK = 'task-' + 't' * 90 + '-TASKEND'
REQUEST = 'request-' + 'r' * 95 + '-REQUESTEND'
TITLE = 'TITLEHEAD `literal` **/*.ml ' + '한글 task evidence ' * 35 + 'TITLEEND'
AGENT = 'agent-' + 'a' * 90 + '-AGENTEND'
GATE = 'gate-' + 'g' * 90 + '-GATEEND'
EVALUATOR = 'runtime-' + 'e' * 90 + '-EVALUATOREND'
REASON = 'REASONHEAD # literal [draft](target) ' + '한글 reason ' * 35 + 'REASONEND'
REFERENCE = 'artifact:' + 'long-reference-' * 15 + 'REFERENCEEND'
CONTENT = 'CONTENTHEAD\n```\n*literal* **/*.ml\n' + '한글 artifact ' * 30 + 'CONTENTEND'
GOAL = 'goal-linked'
GOAL_TITLE = 'GOALHEAD ' + '한글 goal ' * 30 + 'GOALEND'
METRIC = 'METRICHEAD ' + '한글 metric ' * 30 + 'METRICEND'
WINDOW = re.compile(r'\b(\d+)-(\d+)/(\d+)\b')


def cell_width(text):
    return sum(0 if unicodedata.combining(c) else
               2 if unicodedata.east_asian_width(c) in ('W', 'F') else 1 for c in text)


def cell_index(text, boundary):
    cells = 0
    for index, char in enumerate(text):
        if cells == boundary:
            return index
        cells += cell_width(char)
        assert cells <= boundary, (boundary, text)
    assert cells == boundary, (boundary, text)
    return len(text)


def completed(output):
    raw = bytes(output)
    end = raw.rfind(h.FRAME_END)
    assert end >= 0, raw
    return raw[:end + len(h.FRAME_END)]


def fixtures():
    result = h.keeper_runtime_http_fixtures()
    request = h.verification_request_row(TASK)
    request.update(request_id=REQUEST, task_title=TITLE, submitted_by=AGENT,
                   required_artifacts=[REFERENCE], submitted_evidence=[REFERENCE])
    result[h.VERIFICATION_QUEUE_PATH] = (200, h.verification_snapshot([request]))
    result['/api/v1/verification/evidence'] = (200, {'result': {'evidence': {
        'access': 'available', 'items': [{'kind': 'artifact', 'reference': REFERENCE,
        'content': CONTENT, 'bytes': len(CONTENT.encode()), 'truncated': False}]}}})
    verdicts = h.harness_health_snapshot()
    verdicts['recent_verdicts'][0].update(task_id=TASK, task_title=TITLE,
        agent_name=AGENT, gate=GATE, evaluator_runtime=EVALUATOR,
        verdict='reject:' + REASON, fallback_reason=REASON)
    result[h.HARNESS_HEALTH_PATH] = (200, verdicts)
    goal = h.planning_goal(GOAL, GOAL_TITLE)
    goal.update(metric=METRIC, target_value='100%', task_count=1)
    result[h.PLANNING_PATH] = h.planning_snapshot([goal])
    return result


def prepare(base):
    Path(base, '.masc', 'tasks', 'backlog.json').write_text(json.dumps({
        'tasks': [{'id': TASK, 'title': TITLE, 'status': 'awaiting_verification',
                   'priority': 1, 'assignee': 'alpha', 'verification_id': REQUEST,
                   'created_at': '2026-08-22T00:00:00Z',
                   'started_at': '2026-08-22T00:00:00Z', 'submitted_at': '2026-08-22T00:00:00Z'}],
        'last_updated': '2026-08-22T00:00:00Z', 'version': 1}), encoding='utf-8')
    Path(base, '.masc', 'tasks', 'goal_task_links.json').write_text(json.dumps({
        'links': [{'goal_id': GOAL, 'task_ids': [TASK]}]}), encoding='utf-8')


def run(binary, columns, plain, review, timezone='UTC'):
    heading = 'VERIFICATION REQUEST' if review else 'EVALUATOR VERDICT'

    def interact(process, fd, _slave, output, _base):
        h.wait_for_output(process, fd, output, b'MASC Dashboard', start=0, timeout=10)
        h.tab_until(process, fd, output, b'MASC Work')
        h.wait_for_output(process, fd, output, b'GOALHEAD', start=0, timeout=10)
        h.send_and_wait(process, fd, output, b'v', b'TITLEHEAD')
        if not review:
            h.send_and_wait(process, fd, output, b'v', b'12 ruled')
        h.send_and_wait(process, fd, output, b'\r', heading.encode())
        resize_start = len(output)
        h.resize_and_wait(process, fd, output, rows=18, columns=columns,
                          needle=heading.encode(), controls=(h.FULL_REDRAW,))
        clear = output.rfind(h.FULL_REDRAW,resize_start)
        assert clear >= resize_start
        h.wait_for_output(process,fd,output,h.FRAME_END,
            start=h.end_of_needle(output,heading.encode(),clear),timeout=3)
        rows = h.screen_rows(completed(output))
        body_row, heading_line = next((row, text.decode('utf-8')) for row, text in sorted(rows.items())
            if heading in text.decode('utf-8'))
        # The heading owns two indent cells; wrapped rows start at the
        # pane's content edge, before that heading-specific indentation.
        left = cell_width(heading_line[:heading_line.index(heading)]) - 2
        right = columns
        for text in rows.values():
            line = text.decode('utf-8')
            if '[Recent]' in line:
                right = cell_width(line[:line.index('[Recent]')]) - 1
                break

        assert 0 <= left < right <= columns, (left,right,columns)

        def window():
            screen = h.screen_rows(completed(output))
            match = next((WINDOW.search(text.decode('utf-8')) for row, text in sorted(screen.items())
                          if WINDOW.search(text.decode('utf-8'))), None)
            assert match is not None, screen
            first, last, total = map(int, match.groups())
            body = []
            for index in range(last-first+1):
                line = screen[body_row+index].decode('utf-8', errors='strict')
                assert cell_width(line) <= columns, (columns, line)
                body.append(line[cell_index(line,left):cell_index(line,right)])
            return first, last, total, body

        if review:
            # Evidence is fetched separately from the request. Reach its
            # typed artifact row before collecting a stable document.
            while not any('- artifact ' in text.decode('utf-8')
                          for text in h.screen_rows(completed(output)).values()):
                first,last,total,_ = window()
                if last == total:
                    start = len(output)
                    h.wait_for_output(process,fd,output,b'- artifact ',start=start,timeout=10)
                    h.wait_for_output(process,fd,output,h.FRAME_END,
                        start=h.end_of_needle(output,b'- artifact ',start),timeout=3)
                    break
                target = min(total-(last-first),first+1)
                h.send_and_wait(process,fd,output,b'j',f'{target}-'.encode())
                assert window()[0] == target
            h.send_and_wait(process,fd,output,b'\x1b[H',b'1-')

        captured = {}
        while True:
            first, last, total, body = window()
            captured.update((first+i,line) for i,line in enumerate(body))
            if last == total:
                break
            target = min(total-(last-first), first+1)
            h.send_and_wait(process,fd,output,b'j', f'{target}-'.encode())
            assert window()[0] == target
        compact = ''.join(''.join(captured[i].split()) for i in sorted(captured))
        # The source is 14:00+09:00. Keep its complete displayed value
        # through scroll, in the terminal zone used for this PTY process.
        created = '2026-08-25 05:00:00' if timezone == 'UTC' else '2026-08-25 14:00:00'
        fields = (TASK, TITLE, AGENT, REQUEST, REFERENCE, CONTENT, created) if review else (
            TASK, TITLE, AGENT, GATE, EVALUATOR, REASON, GOAL_TITLE, METRIC, '100%')
        for field in fields:
            assert ''.join(field.split()) in compact, (columns, plain, review, field, compact)
        if review:
            assert '2026-08-25T14:00:00+09:00' not in compact, (columns, timezone, compact)
        h.send_and_wait(process,fd,output,b'\x1b[H',b'1-')
        assert window()[0] == 1
        first,last,total,_ = window()
        h.send_and_wait(process,fd,output,b'\x1b[F',f'{max(1,total-(last-first))}-'.encode())
        assert window()[1] == total
        print(f'JUDGEMENT_LAYOUT width={columns} NO_COLOR={plain} review={review} TZ={timezone}: full fields/scroll/edges PASS',flush=True)
        os.write(fd,b'q')

    h.run_terminal_scenario(binary, description=f'Judgement complete fields {columns} plain={plain} review={review} zone={timezone}',
        interact=interact, prepare_workspace=prepare, http_fixtures=fixtures(),
        extra_env={'TZ':timezone, **({'NO_COLOR':'1'} if plain else {})})


if __name__ == '__main__':
    for plain in (False,True):
        for columns in (30,40,60,80,120,160):
            for review in (True,False):
                run(os.path.abspath(sys.argv[1]),columns,plain,review)
    for plain in (False,True):
        run(os.path.abspath(sys.argv[1]),60,plain,True,timezone='Asia/Seoul')
    print('Review and Verdict complete metadata: PASS')
