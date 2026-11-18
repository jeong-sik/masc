import json, re, sys, datetime, collections, statistics
c = json.load(open(sys.argv[1]))
THEMES = [
 ('capacity/frame/size', r'capacity|input limit|input refusal|too large|over-capacity|크기|한도|너무 커|큰 원본|max_tokens|budget|예산|읽는 폭|폭을|적게 읽|descen|fit subsequent|여러 장|목록 장|63자|200 MiB|memory 에 올리기|메모리에 올리기'),
 ('restart/resume/recovery', r'restart|resum|재개|서버가 멈춰|shutdown|startup|기동|reopen|recover|복구|reconnect|interrupted|끊긴'),
 ('declaration/replacement', r'declaration|선언|교체'),
 ('admission', r'admission|admit|접수'),
 ('frontier/settle/terminal', r'frontier|settle|settlement|(?-i:ACK)|closure|닫혀|terminal|종단|finaliz|끝내'),
 ('unknown/uncertain outcome & fencing', r'unknown|uncertain|모르는|unconfirmed|fence|fencing|outward_effect|시작 표시|Conflicted|생성 요청을 보내기'),
 ('gate (absorb gate, gate destination)', r'gate|관문|판정 서버|destination'),
 ('absorb/absorption judgment', r'absorb|absorption|흡수|claim'),
 ('message floor/official turn/atom', r'floor|official turn|공식 턴|official 턴|\batoms?\b|턴 경계|turn boundary|끝 줄|end line|turn.s end|checkpoint cut'),
 ('cursor/progress/range', r'cursor|progress|진행|request id|unread|range|범위|위치|catch-up|따라잡|다음 읽기|frozen'),
 ('cancellation/drain', r'cancel|취소|drain'),
 ('continuity/snapshot/working context', r'continuity|연속성|snapshot|스냅숏|스냅샷|working context|working state|working-context'),
 ('exact request/worker lifecycle', r'exact worker|Exact worker|request bod|본문|Exact 요청|Exact 호출|exact 기록|exact 걸음|Exact 시작|exact 파일|exact durable|exact atom|Exact request'),
 ('CLI fallback/provider/slot', r'\bCLI\b|fallback|provider|429|Retry-After|timeout|Codex|slot|슬롯'),
 ('binding/inventory/store reads (lane-addon)', r'binding|inventory|validate-stores|records 권한|기록 권한|기록을 남기지|기록을 썼'),
 ('container/browser/host infra', r'Apple|container|컨테이너|Docker|browser|Gecko|image|이미지|워커를 만들|worker start'),
 ('purge/checkpoint', r'purge|checkpoint|체크포인트'),
 ('history resolution/Cut/intent', r'\bCuts?\b|intent|history 원본|history original|missing history|program|history outcome'),
 ('wake/wakeup', r'wake|깨워|깨우|깨운'),
 ('refusal/typed failure cause', r'refus|refuse|reject|거절|failure cause|failure kind|typed failure|not_allowed'),
 ('preflight/deploy check/validate-stores', r'preflight|배포 전|배포 검사|설치 전 검사|validate-stores|deploy'),
 ('visibility/health/log wording', r'surface|expose|health|warn|\blogs?\b|TUI|보여|알려|dashboard|wording|attention|status'),
 ('structured output/JSON format', r'JSON|json_object|response_format|structured-output|exact output'),
]
fx = sorted([x for x in c if x['type']=='fix'], key=lambda x: x['date'])
assign = {t: [] for t,_ in THEMES}
uncl = []
for x in fx:
    hit = False
    for t, rx in THEMES:
        if re.search(rx, x['subject'], re.I):
            assign[t].append(x); hit = True
    if not hit: uncl.append(x)
def short(s, n=110):
    return s if len(s) <= n else s[:n-1] + '…'
print('fix commits', len(fx), 'classified (>=1 theme)', len(fx)-len(uncl), 'unclassified', len(uncl))
print()
print('| theme | fixes | first | last | since 2026-10-01 | since 2026-11-01 | examples (first · middle · last) |')
print('|---|---:|---|---|---:|---:|---|')
for t, _ in sorted(THEMES, key=lambda tr: -len(assign[tr[0]])):
    xs = assign[t]
    if not xs: continue
    ex = [xs[0], xs[len(xs)//2], xs[-1]] if len(xs) >= 3 else xs
    exs = ' · '.join(f"{short(e['subject'])}" for e in ex)
    print(f"| {t} | {len(xs)} | {xs[0]['date'][:10]} | {xs[-1]['date'][:10]} | {sum(1 for e in xs if e['date']>='2026-10-01')} | {sum(1 for e in xs if e['date']>='2026-11-01')} | {exs} |")
print()
print('Unclassified fix subjects:', len(uncl))
for x in uncl: print('-', x['date'][:10], short(x['subject'], 120))
# per-month matrix for top themes
print()
months = sorted({x['date'][:7] for x in fx})
print('| theme | ' + ' | '.join(months) + ' |')
print('|---|' + '---:|'*len(months))
for t,_ in sorted(THEMES, key=lambda tr: -len(assign[tr[0]])):
    cm = collections.Counter(x['date'][:7] for x in assign[t])
    print(f'| {t} | ' + ' | '.join(str(cm[m]) for m in months) + ' |')
json.dump({t:[x['hash'] for x in v] for t,v in assign.items()}, open(sys.argv[2],'w'))
