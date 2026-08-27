# :8935 재배포 Runbook

`:8935`는 단일 운영 인스턴스이고 Cloudflare 터널(`masc.crying.pictures`, `masc-dev.crying.pictures`)이 직접 바라보는 대외 노출면이다 (`~/.cloudflared/config.yml`). `scripts/deploy.sh`는 별도 플레인(:8945, atomic lease handoff)용이며 이 문서의 대상이 아니다.

## 0. 재배포 필요 판정

```bash
git -C <repo> ls-remote origin refs/heads/main
curl -s http://127.0.0.1:8935/health | jq -r '.build.binary_commit, .build.binary_commit_source'
```

`binary_commit`은 빌드 타임에 임베드된다(`lib/build_commit/dune`의 `(universe)` rule → `lib/build_identity.ml`). `binary_commit_source`가 `embedded`이면 이 값이 곧 실행 중인 코드의 SHA다. 두 SHA가 같으면 재배포할 것이 없다.

## 1. 기준선 스냅샷

재기동 후 회귀 오판을 막기 위해 먼저 동결한다.

```bash
curl -s 'http://127.0.0.1:8935/health?full=1' > /tmp/health-before.json
jq '{fibers:.keeper_fibers, fleet:.keeper_fleet_safety.status,
     bootable:.keeper_fleet_safety.bootable_keeper_count,
     blocker:.keeper_fleet_safety.blocker,
     dash:.dashboard_surface.status}' /tmp/health-before.json
```

기존에 `degraded`였다면 재기동 후 `degraded`는 회귀가 아니다.

## 2. main 동기화와 ancestry 확증

```bash
cd <repo> && git pull --rebase origin main
git merge-base --is-ancestor <반드시-포함할-수리-SHA> HEAD && echo ANCESTOR_OK
```

ancestry 확증은 2026-08-16 운영 루프 2회차 사고(병합 파이프라인과 pull 경합으로 수리 커밋 미포함 checkout이 배포됨)의 재발 방지 단계다. 어떤 스크립트도 강제하지 않는 수동 단계이므로 생략하지 않는다.

## 3. 빌드

```bash
./scripts/dune-local.sh build bin/main_eio.exe bin/deployment_preflight_helper.exe
./scripts/build-dashboard-if-needed.sh
```

- 맨손 `dune build`는 금지 — wrapper가 `--root`를 고정하고 머신 전역 lock과 OCaml 버전 검증을 수행한다.
- 대시보드는 raw `pnpm run build` 금지 — vite `emptyOutDir`가 `assets/dashboard/.build-stamp`를 지우고, stamp를 다시 쓰는 것은 wrapper뿐이다. stamp가 없으면 `/health`의 `dashboard_surface.status`가 `missing`으로 고착된다 (`lib/web_dashboard.ml`).

## 4. keeper meta 스키마 정합 확인

새 binary가 `Keeper_meta_json.current_field_names`에 필드를 추가했다면, 파서가 그 키를 필수로 요구하므로 기존 `<base>/.masc/keepers/*.json`이 전부 파싱 실패한다 (enum 자동 복구는 missing key를 못 고친다 — `lib/keeper/keeper_meta_store.ml`). 다운타임(6단계와 7단계 사이)에 store를 정합시킨다: 원본을 `<base>/.masc/_archive/`로 통째 보존한 뒤, 각 meta JSON에 새 키를 기본값(`null` 등 writer의 부재 표현)으로 주입한다.

반대 방향(필드 제거)도 같은 단계에서 걸린다. hard cut으로 스키마에서 지운 필드를 디스크 meta가 아직 들고 있으면 새 binary는 그 meta를 읽지 못한다. 2026-08-23 `generation`·`last_blocker` 제거 때 키퍼 10개가 21분간 부팅하지 못했다. 런타임은 이제 그 meta를 버리고 TOML 선언에서 키퍼를 다시 만든다(#29610) — 누적 카운터와 `current_task_id`가 사라진다. 손실 없이 넘기려면 6단계 preflight가 걸러준 시점에 유령 필드만 지운다(필드 목록은 preflight 실패 메시지에 나온다):

```bash
for f in <base>/.masc/keepers/*.json; do
  jq 'del(.generation, .last_blocker)' "$f" >"$f.tmp" && mv "$f.tmp" "$f"
done
```

## 4.5 사전 조율 — 진행 중 작업 보호

재기동은 **모든 keeper를 내린다**. autoboot이 꺼진 keeper(장기 canary 전부)는 재기동 후 자동 복귀하지 않는다 — durable demand recovery가 `retained ... reason=autoboot_disabled`로 보존만 한다. 2026-08-17 5회차 재기동이 진행 중이던 24h 사다리 run의 turn을 서버 다운에 노출시킨 사고가 근거다 (redeploy receipt의 incident 절).

1. **broadcast 먼저**: 병렬 세션/keeper에게 재기동 예고를 보내고 이의를 기다린다 (MASC broadcast 또는 세션 간 메시지).
2. **진행 중 장기 run 확인**: 실행 중 keeper 목록에서 autoboot 꺼진 canary를 찾는다.
   ```bash
   curl -s 'http://127.0.0.1:8935/health?full=1' | jq '[.keepers[]? | select(.running == true)] | map(.name)'
   ```
   사다리(1h+) run이 진행 중이면 그 종료 시각 이후로 재기동을 미룬다.
3. **수동 boot 목록 캡처**: 정지 직전 실행 중이던 non-autoboot keeper 이름을 기록해 두고, 7단계 기동 후 각각 수동 boot으로 복귀시킨다.
4. **재기동 직후 부하 작업 금지**: autoboot keeper의 부팅 폭주가 소강될 때까지 캠페인·병렬 wave 같은 부하 작업을 시작하지 않는다. 근거: 2026-08-18 4차 재기동(13:57) 직후 시작한 E0 r5에서 부팅 폭주와 5턴 동시 wave가 겹쳐 glm 레인 rate limit 5/5 전멸(7개 미션 연쇄 실패) — 레인 냉각 후 재시도(r6)로만 해소됐다.

## 5. graceful shutdown

HTTP로 프로세스를 내리는 경로는 없다. 유효한 경로는 SIGTERM/SIGINT뿐이다 (`bin/main_eio.ml`: NOTIFY → HOOKS → BOARD flush → CANCEL, 기본 예산 최대 10초).

```bash
MASC_BASE_PATH=<base> ./scripts/masc-supervisor-control.sh stop
lsof -iTCP:8935 -sTCP:LISTEN   # 출력이 비면 내려간 것 — exit code로 판정하지 말 것
```

이 제어 스크립트는 supervisor에 TERM을 보낸다. supervisor는 현재 child에
같은 신호를 전달하고 child가 끝날 때까지 기다린다. 리스너 PID만 직접
내리면 supervisor가 장애로 판단해 다시 띄우므로 금지한다.

기존 프로세스를 supervisor 관리로 처음 전환할 때는 PID 파일이 없다.
이때만 리스너에 TERM을 직접 보낸다.

```bash
kill -TERM "$(lsof -ti tcp:8935 -sTCP:LISTEN)"
```

## 6. store preflight

서버가 살아 있으면 writer lease 소유로 거부되므로 반드시 정지 후에 돌린다.

```bash
MASC_DEPLOYMENT_PREFLIGHT_HELPER=<repo>/_build/default/bin/deployment_preflight_helper.exe \
  <repo>/scripts/check-runtime-deployment-preflight.sh --base-path <base>
```

성공 신호는 `[runtime-deployment-preflight] OK`. keeper meta 현재 스키마 검사, keeper 이벤트 큐/WAL 파싱, schedule ledger 계약, board attention candidate ledger `schema_version` 검사를 포함한다. OK/FAIL 줄 끝의 `helper=<경로> helper_commit=<SHA>`가 방금 빌드한 helper(2단계에서 확증한 SHA)인지 본다 — 다른 SHA면 옛 helper가 판정한 것이다.

meta 검사 범위는 keeper meta(`<base>/.masc/keepers/*.json`)뿐이다. `goals.json`(`lib/goal/goal_store.ml`의 닫힌 스키마)과 run registry 파일은 이 게이트가 검사하지 않는다.

이 단계는 5단계(정지)와 7단계(기동) 사이에서 돈다. 거부되면 서버는 내려간 채로 멈추고, 지적된 파일을 고친 뒤 이 단계를 다시 돌려 OK를 본 다음 7단계로 간다. 그 다운타임이 카운터를 지키는 값이다 — 기동 시 fail-open(#29610)은 meta를 버린다. keeper meta 거부는 helper 판정의 `class=` 토큰이 둘로 나뉜다: `not_current_schema`는 필드 불일치라 유령 필드 삭제/빠진 필드 주입으로 고치고, `unreadable_json`은 JSON 자체가 깨진 것이라 백업에서 복원한다(이 경우 런타임은 meta를 버리지 않고 그 keeper 부팅을 거부한다).

스토어 버전이 올라간 바이너리(이벤트 큐 v16 → v17, exact-lane run registry v4 → v5 등)를 올릴 때는 이전 버전 파일을 이 단계에서 지운다. 새 바이너리는 옛 파일을 열지 않으므로 남겨 두면 아무 도구도 다시 보지 않는 고아 파일이 된다. 지우기 전에 크기와 행 수를 기록한다 (`wc -lc <base>/.masc/exact-lane-runs-v4.jsonl`).

### schedule signal ledger 은퇴 (payload envelope 평탄화 배포에서 1회)

schedule payload 에서 `schema_version` 을 뺀 바이너리를 처음 올릴 때만 해당한다. 저장된 signal 행은 `payload_digest` 와 `occurrence_id` 를 payload 로부터 다시 계산해 대조하는데, payload 모양이 바뀌었으니 전 행이 어긋난다. preflight 는 첫 어긋난 행에서 멈춘다. board attention candidate ledger 와 같은 방식으로 은퇴시킨다 — 옛 행을 읽는 코드는 만들지 않는다.

먼저 아직 발화하거나 복구해야 할 occurrence가 없는지 검사한다. `Due`는 signal key를 지운 뒤 다시 발화할 수 있고, `Running`은 wake record의 옛 payload digest와 평탄화된 schedule의 새 digest가 달라 startup recovery가 닫히지 않는다. 둘 중 하나라도 있으면 아무 파일도 옮기지 말고 배포를 중단한다.

```bash
python3 - '<base>/.masc/schedules.json' <<'PY'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1])
d = json.loads(p.read_text())
blocked_schedules = [
    (s.get("schedule_id"), s.get("status"))
    for s in d["schedules"]
    if s.get("status") in {"due", "running"}
]
blocked_wakes = [
    (w.get("schedule_instance_id"), w.get("schedule_id"), w.get("status"))
    for w in d["wakes"]
    if w.get("status") == "running"
]
if blocked_schedules or blocked_wakes:
    print("BLOCKED schedule(s):", blocked_schedules)
    print("BLOCKED wake(s):", blocked_wakes)
    raise SystemExit(1)
print("OK: no due/running schedules or running wakes")
PY
```

검사가 통과하면 signal ledger와 dedupe key를 지우지 말고 배포 archive로 옮긴다. `signal_keys.json`은 이미 보낸 occurrence를 다시 안 보내려고 두는 id 목록이라 함께 은퇴한다. 새 payload 모양으로 계산한 id와 일치하지 않아 active 위치에 남겨도 아무 것도 막지 못한다.

```bash
schedule_retirement_archive='<base>/.masc/_archive/schedule-payload-v1-<deployment-id>'
if [ -e "$schedule_retirement_archive" ]; then
  echo "archive already exists: $schedule_retirement_archive" >&2
  exit 1
fi
mkdir -p "$schedule_retirement_archive"
find '<base>/.masc/schedules/signals' -name '*.jsonl' | wc -l
find '<base>/.masc/schedules/signals' -name '*.jsonl' -exec cat {} + | wc -l
if [ -d '<base>/.masc/schedules/signals' ]; then
  mv '<base>/.masc/schedules/signals' "$schedule_retirement_archive/signals"
fi
if [ -f '<base>/.masc/schedules/signal_keys.json' ]; then
  mv '<base>/.masc/schedules/signal_keys.json' "$schedule_retirement_archive/signal_keys.json"
fi
```

`schedules.json`은 지우지 않는다. 여기에는 아직 안 온 wake가 들어 있다. primary와 `.last-good`을 각각 archive에 복사한 뒤, 임시 파일과 rename으로 payload의 퇴역 필드를 원자적으로 제거한다. 새 decoder는 이 필드를 조용히 버리지 않고 거절하므로 둘 다 정리해야 한다.

```bash
for schedule_ledger_name in schedules.json schedules.json.last-good; do
  schedule_ledger_path="<base>/.masc/$schedule_ledger_name"
  if [ ! -f "$schedule_ledger_path" ]; then
    continue
  fi
  cp "$schedule_ledger_path" "$schedule_retirement_archive/$schedule_ledger_name"
  jq '(.schedules[]?.payload) |= del(.schema_version)' \
    "$schedule_ledger_path" >"$schedule_ledger_path.tmp"
  mv "$schedule_ledger_path.tmp" "$schedule_ledger_path"
done
```

### board post 의 content / score 은퇴 (게시판 중복 필드 숙청 배포에서 1회)

post 행에서 `content` 와 `score` 를 뺀 바이너리를 처음 올릴 때만 해당한다.

`content` 는 `body` 를 글자 그대로 복사한 값이었고, `score` 는 `votes_up - votes_down` 을 다시 적은 값이었다. 디코더는 두 값이 어긋나면 그 행을 통째로 버렸고, 버린 사실은 어디에도 남지 않았다. 두 키를 없앤 디코더는 그 키를 달고 있는 행을 모르는 필드로 보고 거절한다. 스토어를 먼저 손보지 않고 올리면 게시글과 댓글이 전부 사라진다. 옛 행을 읽는 코드는 만들지 않는다.

서버를 세운 뒤(§5) 실행한다. 먼저 몇 행이 걸리는지 센다.

```bash
python3 - '<base>/.masc' <<'COUNT'
import json, pathlib, sys
masc = pathlib.Path(sys.argv[1])
for name, keys in (('board_posts.jsonl', ('content', 'score')),
                   ('board_comments.jsonl', ('score',))):
    path = masc / name
    if not path.exists():
        print(f'{name}: absent')
        continue
    rows = [json.loads(l) for l in path.read_text().splitlines() if l.strip()]
    hit = sum(1 for r in rows if any(k in r for k in keys))
    print(f'{name}: rows={len(rows)} carrying_retired_key={hit}')
COUNT
```

행 수를 확인했으면 두 키를 벗겨 다시 쓴다. 백업을 먼저 뜬다.

```bash
cp '<base>/.masc/board_posts.jsonl' '<base>/.masc/backups/board_posts.jsonl.pre-purge'
cp '<base>/.masc/board_comments.jsonl' '<base>/.masc/backups/board_comments.jsonl.pre-purge'

python3 - '<base>/.masc' <<'STRIP'
import json, os, pathlib, sys
masc = pathlib.Path(sys.argv[1])
for name, keys in (('board_posts.jsonl', ('content', 'score')),
                   ('board_comments.jsonl', ('score',))):
    path = masc / name
    if not path.exists():
        continue
    out = []
    for line in path.read_text().splitlines():
        if not line.strip():
            continue
        row = json.loads(line)
        for k in keys:
            row.pop(k, None)
        out.append(json.dumps(row, ensure_ascii=False))
    tmp = path.with_suffix(path.suffix + '.new')
    tmp.write_text('\n'.join(out) + '\n')
    os.replace(tmp, path)
    print(f'{name}: rewrote {len(out)} rows')
STRIP
```

`board_attention_candidates/` 는 저장된 post 행을 통째로 품고 있어 같은 이유로 무효가 된다. `schema_version` 이 4 에서 5 로 올라갔으므로 옛 파일은 읽기 시점에 거절된다. 디렉터리를 비운다 — keeper 가 게시판을 다시 읽으면 후보는 다시 쌓인다.

```bash
mv '<base>/.masc/board_attention_candidates' '<base>/.masc/backups/board_attention_candidates.v4'
mkdir -p '<base>/.masc/board_attention_candidates'
```

기동(§7) 뒤 로그에서 로드된 수가 위에서 센 행 수와 맞는지 본다. 적으면 남은 행이 조용히 버려진 것이다.

```bash
rg -o 'loaded [0-9]+ (posts|comments)' '<base>/.masc/logs/masc-8935-supervised.out.log' | tail -2
```

### keeper chat 행이 읽기마다 버려질 때

증상은 로그에 이 줄이 쏟아지는 것이다. 2026-08-27 에 30분짜리 로그 하나에서 **18,445 건** 나왔다.

```
[keeper_chat_store] persistence read drop (invalid_payload) path=<base>/.masc/keeper_chat/<name>.jsonl:
  invalid delivery execution identity: tool_call transcript slot requires the same row execution_id
```

`keeper_chat_store.ml` 의 `validate_delivery_execution_identity` 는 transcript slot 이 `Tool_call` 이면 그 행에 같은 `execution_id` 가 있어야 한다고 요구한다. writer 가 그 필드를 쓰기 시작한 배포 이전 행에는 없으므로, 그 행들은 매 읽기마다 통째로 버려진다. 조용히 사라지는 게 아니라 WARN 을 쏟으면서 사라져서, 로그에서 진짜 문제를 찾기 어려워진다.

먼저 이게 레거시 데이터 문제인지 확인한다. 배포 이후 행이 전부 필드를 갖고 있으면 writer 는 정상이고 옛 행만 은퇴 대상이다. 배포 이후 행에도 빠진 게 있으면 writer 쪽 결함이니 여기서 멈춘다.

```bash
python3 - <<'PY'
import json, glob, datetime
CUT = <배포 시각의 unix seconds>
after_have = after_miss = before_miss = 0
for path in glob.glob('<base>/.masc/keeper_chat/*.jsonl'):
    for line in open(path):
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except Exception:
            continue
        slot = row.get('transcript_slot')
        kind = (slot.get('kind') if isinstance(slot, dict) else slot) or ''
        if kind != 'tool_call':
            continue
        if (row.get('ts') or 0) < CUT:
            if not row.get('execution_id'):
                before_miss += 1
        elif row.get('execution_id'):
            after_have += 1
        else:
            after_miss += 1
print('배포 이후 필드 있음 :', after_have)
print('배포 이후 필드 없음 :', after_miss, '(0 이 아니면 writer 결함 — 은퇴하지 말고 조사)')
print('배포 이전 필드 없음 :', before_miss, '(은퇴 대상)')
PY
```

`after_miss` 가 0 이면 거절되는 행만 골라 archive 로 옮긴다. 남는 행은 전부 현재 계약을 만족하므로 부분 정리가 아니다. 파일 전체를 자르지는 않는다 — 그러면 아직 정상적으로 렌더되는 `accepted_user` / `terminal_assistant` 행까지 잃는다.

```bash
chat_retirement_archive='<base>/.masc/_archive/keeper-chat-pre-execution-id-<deployment-id>'
if [ -e "$chat_retirement_archive" ]; then
  echo "archive already exists: $chat_retirement_archive" >&2
  exit 1
fi
mkdir -p "$chat_retirement_archive"
cp -R '<base>/.masc/keeper_chat' "$chat_retirement_archive/keeper_chat"
python3 - <<'PY'
import json, glob, os, stat
kept = retired = 0
for path in glob.glob('<base>/.masc/keeper_chat/*.jsonl'):
    original = os.stat(path)
    out = []
    changed = False
    for line in open(path):
        text = line.rstrip('\n')
        if not text.strip():
            continue
        try:
            row = json.loads(text)
        except Exception:
            out.append(text); kept += 1; continue
        slot = row.get('transcript_slot')
        kind = (slot.get('kind') if isinstance(slot, dict) else slot) or ''
        if kind == 'tool_call' and not row.get('execution_id'):
            retired += 1; changed = True
        else:
            out.append(text); kept += 1
    if changed:
        tmp = path + '.tmp'
        with open(tmp, 'w') as fh:
            for text in out:
                fh.write(text + '\n')
            fh.flush()
            os.fsync(fh.fileno())
        os.chmod(tmp, stat.S_IMODE(original.st_mode))
        os.replace(tmp, path)
        directory = os.open(os.path.dirname(path), os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
print('kept', kept, 'retired', retired)
PY
```

서버 정지 상태에서 돈다. 이 파일들은 append-only 이고 살아 있는 서버가 계속 쓰므로, 돌아가는 중에 rename 하면 그 사이 append 가 사라진다.

기동 후 검증은 같은 WARN 이 0 인지 본다.

```bash
rg -c 'persistence read drop' <기동 로그>
```

## 7. 기동

provider key가 로드된 interactive shell에서 실행한다. launchd 경로(`com.jeong-sik.masc-main`)는 `~/.zshenv`를 읽지 않아 provider 크리덴셜이 조용히 사라진다.

```bash
cd <repo>
MASC_BASE_PATH=<base> ./scripts/masc-supervisor-control.sh start
```

제어 스크립트는 `start-masc-supervised.sh`를 백그라운드에서 띄운다.
autoboot은 이 8935 운영 경로에서 기본 `true`다. supervisor는 health와
실행 파일 hash를 확인한 child가 종료되면 5초 뒤 다시 띄운다. 빌드가
실패하면 같은 검증을 거친 LKG만 사용한다. 기동 로그, supervisor 로그,
PID 파일은 `<base>/.masc/logs/`에 남는다.

## 8. 검증

```bash
MASC_BASE_PATH=<base> ./scripts/masc-supervisor-control.sh status
curl -s http://127.0.0.1:8935/health \
  | jq '{v:.version, c:.build.binary_commit, src:.build.binary_commit_source,
         dash:.dashboard_surface.status}'
curl -s 'http://127.0.0.1:8935/health?full=1' \
  | jq '{fibers:.keeper_fibers, fleet:.keeper_fleet_safety.status,
         bootable:.keeper_fleet_safety.bootable_keeper_count}'
```

합격 기준:

- `binary_commit` == 배포 의도 SHA, `binary_commit_source` == `embedded`
- `dashboard_surface.status` == `ok`
- `keeper_fibers`/`bootable_keeper_count`가 1단계 기준선으로 회복
- 기동 로그에 keeper meta fail-open WARN이 없다 (`rg "keeper meta unreadable at" <로그>` — `lib/keeper/keeper_meta_store.ml`의 `keeper meta unreadable at %s, treating as absent` 리터럴)

대시보드 TopBar는 같은 `/health` 필드를 읽는다. 브라우저 스크린샷은 보조 증거로 남긴다.

## 함정 요약

| 함정 | 결과 |
|---|---|
| supervisor child 리스너 PID만 직접 종료 | supervisor가 장애로 판단해 즉시 재기동 |
| `MASC_BASE_PATH`를 빼고 제어 스크립트 실행 | 다른 workspace를 실수로 띄우지 않고 즉시 거절 |
| launchd로 재기동 | provider key 소실 (keeper.env는 2줄뿐) |
| raw `pnpm run build` | `.build-stamp` 소실 → dashboard `missing` 고착 |
| 맨손 `dune build` (worktree 안) | 상위 repo를 빌드하는 거짓 검증 |
| ancestry 미확증 pull | 수리 커밋 없는 checkout 배포 (08-16 2회차 사고) |
| meta 스키마 확장 후 store 미정합 | 전 keeper meta 파싱 실패 |
| hard cut 제거 필드를 디스크 meta가 아직 가짐 | 부팅 시 meta 폐기 — 카운터·과제 바인딩 손실 (08-23 사고, #29610 이후엔 자동 재생성) |
| 포트 판정을 lsof exit code로 | 거짓 판정 — 출력 존재로 판정할 것 |
| 사전 broadcast·장기 run 확인 생략 | 진행 중 사다리 run이 서버 다운에 노출, non-autoboot keeper 미복귀 (08-17 5회차 사고) |
| 한 provider 의 model 행들이 `max-concurrent`를 서로 다르게 선언 | 그 endpoint 로 나가는 턴이 dispatch 전에 `Invalid_argument` 로 죽는다 (08-27 사고) |
| `start-loopback.sh`가 기동 전 리빌드하는데 main 이 깨져 있음 | 서버가 안 올라온다. LKG 가 없으면 리빌드 우회 기동이 유일한 복구 경로 |

### 한 endpoint 는 허용치 하나만 인정한다

`Provider_admission` 은 `(kind, base_url, api-key identity)` 로 endpoint 를 식별하고 그 정체성에 `max_concurrent_requests` 하나만 인정한다. `runtime.toml` 의 `[<provider>.<model>]` 블록들이 같은 provider 를 가리키면서 값을 다르게 적으면, 그 endpoint 로 나가는 턴이 요청을 만들기도 전에 죽는다.

```
Invalid request: Invalid_argument("Provider_admission: conflicting
max_concurrent_requests for openai_compat https://ollama.com/v1:
one config declares 2, another declares 4. ...")
```

turn 로그에는 `internal_unhandled_exception` / `site=runtime_runner.execute` 로 올라오므로 provider 설정 문제로 보이지 않는다. 2026-08-27 에 `ollama_cloud` 10 개 레인이 1/2/4 로 흩어져 있어 taskmaster 턴이 이렇게 죽었고, 그걸 관측한 다른 keeper 가 taskmaster 를 내렸다.

배포 전에 provider 별로 값이 하나인지 확인한다.

```bash
python3 - <<'PY'
import re, collections
text = open('<base>/.masc/config/runtime.toml').read()
seen = collections.defaultdict(set)
provider = None
for line in text.splitlines():
    header = re.match(r'\[([A-Za-z0-9_-]+)\.', line.strip())
    if header:
        provider = header.group(1)
    value = re.match(r'max-concurrent\s*=\s*(\d+)', line.strip())
    if value and provider:
        seen[provider].add(int(value.group(1)))
for name, values in sorted(seen.items()):
    if len(values) > 1:
        print('CONFLICT', name, sorted(values))
print('checked', len(seen), 'providers')
PY
```

같은 provider 의 서로 다른 endpoint 를 정말 원한다면 값을 맞추는 것 말고 정체성을 나누는 방법도 있다 (오류 메시지가 그렇게 말한다). 다만 그러면 `runtime.toml` 의 그 provider id 를 참조하는 모든 자리를 같이 옮겨야 한다.

이 검사를 처음 돌린 2026-08-27 에, 이미 터진 `ollama_cloud` 말고 **아직 터지지 않은 충돌이 하나 더** 나왔다. `glm-coding` 의 형제 세 행이 4 인데 `glm-4.6v` 만 2 였다. 그 바인딩으로 dispatch 된 적이 없어서 조용했던 것이다.

이 경우 값을 어느 쪽으로 맞출지 고민할 필요가 없다. endpoint 당 허용치는 하나이므로 형제가 4 인 이상 그 endpoint 는 이미 4 로 돌고 있고, 낮은 쪽 선언은 아무것도 조이지 못한 채 충돌만 만들고 있다. 높은 쪽으로 맞추는 것이 선언을 실제 동작과 일치시키는 일이다 — 반대로 맞추면 돌고 있던 endpoint 를 실제로 조이게 된다.

터진 충돌을 고친 뒤에 검사를 한 번 더 돌린다. 한 provider 를 맞추는 것으로 끝나지 않는다.
