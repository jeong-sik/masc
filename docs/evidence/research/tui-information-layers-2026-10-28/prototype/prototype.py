#!/usr/bin/env python3
"""Static, synthetic frame sketches; not the MASC renderer or a UI test."""
import json
import pathlib
import sys
import unicodedata

OUT = pathlib.Path(sys.argv[1])
OUT.mkdir(parents=True, exist_ok=True)
CHAT = [
    '› 이번 PR의 변경 사항을 확인해 줘',
    '● 현재 작업: 소스와 기존 리뷰를 확인 중',
    '  현재 턴이 끝나면 대기 중인 요청을 처리합니다.',
    '› 큐에서 문서 검토를 먼저 처리해 줘',
    '● 요청을 받았습니다. 기존 결과와 이어서 보겠습니다.',
    '  메모: 코드와 실행 결과는 별도로 확인합니다.',
    '› 테스트 결과도 알려 줘',
    '● 빌드 결과는 아직 확인되지 않았습니다.',
    '  서버의 상태를 다시 읽고 있습니다.',
    '› 이 대화는 비교용 가상 내용입니다.',
    '● 확인했습니다. 큐는 현재 실행을 중단하지 않습니다.',
    '  다음 요청을 선택하면 그 항목의 동작을 표시합니다.',
]
QUEUE = [
    '  실행 중 · PR 변경과 기존 리뷰 확인',
    '  로컬 대기 · 디자인 시안 확인',
    '› 서버 대기 · 문서 검토와 남은 리뷰 코멘트를 먼저 정리해 줘',
    '  서버 대기 · 실패한 검사 결과를 확인해 줘',
    '  서버 대기 · 변경된 API의 호출 관계를 정리해 줘',
    '  서버 대기 · 사용자 안내를 업데이트해 줘',
    '  이벤트 · 검토 요청에 대한 알림',
    '  이벤트 · 새 결과 도착',
    '  이벤트 · 작업 상태 변경',
    '  예약 · 내일 아침 보고서 확인',
    '  예약 · 매시간 미확인 항목 정리',
    '  로컬 대기 · 나중에 실행할 요청',
    '  서버 대기 · 추가 확인 01',
    '  서버 대기 · 추가 확인 02',
    '  서버 대기 · 추가 확인 03',
    '  서버 대기 · 추가 확인 04',
    '  서버 대기 · 추가 확인 05',
    '  서버 대기 · 추가 확인 06',
]

def cells(text):
    return sum(0 if unicodedata.combining(ch) else
               2 if unicodedata.east_asian_width(ch) in ('W', 'F') else 1
               for ch in text)

def fit(text, width):
    if cells(text) <= width:
        return text + ' ' * (width - cells(text))
    result = ''
    for ch in text:
        if cells(result + ch) > max(0, width - 1):
            break
        result += ch
    return result + '…' + ' ' * max(0, width - cells(result) - 1)

def panel(width, height):
    # Fixed rows reflect one possible selected-message/receipt state, not MASC output.
    inner = width - 2
    fixed = [' Queue · fixture', ' 확인됨 · 현재 턴 이후 순서 변경',
             ' 결과 · 선택한 요청을 다음으로 표시', ' 안내 · 현재 턴은 중단하지 않음']
    visible = QUEUE[:max(0, height - len(fixed) - 2)]
    lines = ['┌' + '─' * inner + '┐']
    lines += ['│' + fit(line, inner) + '│' for line in fixed + visible]
    lines += ['│' + ' ' * inner + '│'] * max(0, height - 1 - len(lines))
    lines += ['└' + '─' * inner + '┘']
    clipped = sum(cells(line) > inner for line in visible)
    return lines[:height], {'queue_rows_visible':len(visible),
                            'queue_rows_clipped':clipped,
                            'selected_row_clipped':cells(QUEUE[2]) > inner if len(visible)>2 else None,
                            'fixed_rows_clipped':sum(cells(line) > inner for line in fixed),
                            'panel_inner_cells':inner}

def chat(width, height):
    lines = [' Chat · fixture'] + CHAT[-max(0, height - 1):]
    lines = lines[:height] + [''] * max(0, height - len(lines))
    content = lines[1:]
    return ([fit(line, width) for line in lines],
            min(len(CHAT), max(0, height - 1)),
            sum(bool(line) and cells(line) > width for line in content))

def draw(width, height, mode):
    body_height = height - 3
    if mode == 'full':
        body, stats = panel(width, body_height)
        chat_count = 0
        chat_clipped = 0
    elif mode == 'side':
        left = (width * 52) // 100
        chat_lines, chat_count, chat_clipped = chat(left, body_height)
        pane, stats = panel(width - left, body_height)
        body = [a+b for a,b in zip(chat_lines, pane)]
    else:
        sheet_height = (body_height * 60) // 100
        chat_lines, chat_count, chat_clipped = chat(width, body_height - sheet_height)
        pane, stats = panel(width, sheet_height)
        body = chat_lines + pane
    footer = fit(' ↑↓ 선택  Enter 상세  n 다음  l 마지막  r 새로고침  ? 도움말  Esc 닫기', width)
    rows = [fit(' 대시보드  작업  ▸키퍼  사용량  보드  워크스페이스  시스템', width)] + body + [footer, fit(' › 초안은 가상 내용', width)]
    stats.update({'mode':mode, 'columns':width, 'rows':height,
                  'chat_content_rows_visible':chat_count,
                  'chat_content_rows_clipped':chat_clipped,
                  'queue_rows_total':len(QUEUE)})
    return '\n'.join(rows) + '\n', stats

summary = []
for width, height in [(80,24), (120,36), (160,40)]:
    for mode in ('full', 'side', 'bottom'):
        screen, stats = draw(width, height, mode)
        # Trailing blank cells have no visual content. Omit them in the text
        # artifact so the sketches are readable as ordinary repository files.
        stored = '\n'.join(line.rstrip() for line in screen.splitlines()) + '\n'
        (OUT / f'{mode}-{width}x{height}.txt').write_text(stored, encoding='utf-8')
        summary.append(stats)
(OUT / 'measurements.json').write_text(json.dumps(summary, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
print(json.dumps(summary, ensure_ascii=False, indent=2))
