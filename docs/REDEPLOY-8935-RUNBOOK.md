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
kill -TERM $(lsof -ti tcp:8935 -sTCP:LISTEN)
lsof -iTCP:8935 -sTCP:LISTEN   # 출력이 비면 내려간 것 — exit code로 판정하지 말 것
```

## 6. store preflight

서버가 살아 있으면 writer lease 소유로 거부되므로 반드시 정지 후에 돌린다.

```bash
MASC_DEPLOYMENT_PREFLIGHT_HELPER=<repo>/_build/default/bin/deployment_preflight_helper.exe \
  <repo>/scripts/check-runtime-deployment-preflight.sh --base-path <base>
```

성공 신호는 `[runtime-deployment-preflight] OK`. keeper 이벤트 큐/WAL 파싱, schedule ledger 계약, board attention candidate ledger `schema_version` 검사를 포함한다.

스토어 버전이 올라간 바이너리(이벤트 큐 v16 → v17, exact-lane run registry v4 → v5 등)를 올릴 때는 이전 버전 파일을 이 단계에서 지운다. 새 바이너리는 옛 파일을 열지 않으므로 남겨 두면 아무 도구도 다시 보지 않는 고아 파일이 된다. 지우기 전에 크기와 행 수를 기록한다 (`wc -lc <base>/.masc/exact-lane-runs-v4.jsonl`).

## 7. 기동

provider key가 로드된 interactive shell에서 실행한다. launchd 경로(`com.jeong-sik.masc-main`)는 `~/.zshenv`를 읽지 않아 provider 크리덴셜이 조용히 사라진다.

```bash
cd <repo>
nohup ./scripts/start-loopback.sh --with-keeper-bootstrap \
  > <base>/.masc/logs/masc-8935-$(date +%Y%m%d%H%M).out.log 2>&1 &
```

`--with-keeper-bootstrap`은 필수다 — `start-loopback.sh`는 상속된 `MASC_KEEPER_BOOTSTRAP_ENABLED`를 무시하고 기본 `false`로 덮으므로, 없이 올리면 autoboot keeper가 돌아오지 않는다.

## 8. 검증

```bash
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
- 기동 로그에 keeper meta parse 실패가 없다 (`rg "meta parse" <로그>`)

대시보드 TopBar는 같은 `/health` 필드를 읽는다. 브라우저 스크린샷은 보조 증거로 남긴다.

## 함정 요약

| 함정 | 결과 |
|---|---|
| `start-loopback.sh`에 `--with-keeper-bootstrap` 누락 | fleet이 빈 채로 기동 |
| launchd로 재기동 | provider key 소실 (keeper.env는 2줄뿐) |
| raw `pnpm run build` | `.build-stamp` 소실 → dashboard `missing` 고착 |
| 맨손 `dune build` (worktree 안) | 상위 repo를 빌드하는 거짓 검증 |
| ancestry 미확증 pull | 수리 커밋 없는 checkout 배포 (08-16 2회차 사고) |
| meta 스키마 확장 후 store 미정합 | 전 keeper meta 파싱 실패 |
| 포트 판정을 lsof exit code로 | 거짓 판정 — 출력 존재로 판정할 것 |
| 사전 broadcast·장기 run 확인 생략 | 진행 중 사다리 run이 서버 다운에 노출, non-autoboot keeper 미복귀 (08-17 5회차 사고) |
