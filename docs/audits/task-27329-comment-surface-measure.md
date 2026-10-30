# task-589 / #27329 — 댓글 표면 판단 굶음: 수정 전/후 실측 기록

- 일자: 2026-09-02 (측정), 기록 동일
- 대상 리포: `jeong-sik/masc`, base `main` @ `3d8fc497cfdb55fcadc2bb9875b77e34ab8434a6`
- 작업: task-589 (계약: 재현·원인·수정·적색/녹색 실측·표면별 표·PR URL+병합 SHA)
- 작성: rondo

## 1. 결함과 원인

- `Keeper_board_audience.route_for_keeper` 의 `Thread_participants` 갈래가
  `Available None → Available Ignore` 로 접었다. 댓글(`Board_comment_added`)이
  `Thread_participants` 로 분류되고 수신 레인이 스레드에 한 번도 참여하지 않은
  경우(우연 레인) 항상 이 갈래로 접혀, 판단 자체에 후보가 도달하지 못했다.
- 보상 경로도 없다: keepalive replay scan(`keeper_world_observation.ml`)은
  `Board_post_created` 신호만 재합성한다. 즉 댓글 표면의 판단 후보는
  push 경로가 유일한 생산자였고, 그 경로가 `Ignore` 로 막혀 굶었다.
- 소비 루프(`keeper_keepalive_signal.ml`)는 즉시전달 경로에서
  `Judge_discoverable` 을 경계 위반(fail-visible 에러)으로 처리하고 있어서,
  audience 쪽에서 승격만 하면 소비 쪽이 터지는 구조였다. 양쪽을 한 쌍으로 고쳤다.

## 2. 측정 방법

- 라이브 함대 스토어(`$MASC_BASE_PATH/board_attention_candidates/*.jsonl`)는
  호스트 런타임(`/tmp/masc-runtime/.masc`)에만 존재하고 이 샌드박스(microvm)에서는
  접근할 수 없다(2026-09-02 실측: 경로 없음). 따라서 재현 가능한 실측 형태로
  **동일 명령·동일 스위트의 적색/녹색 쌍**을 사용한다.
  - "전" = lib 변경만 `git stash` 로 제거한 워킹트리 + 새 회귀 테스트 포함
  - "후" = 수정 완료 워킹트리 + 동일 테스트
- 스위트: `dune exec test/test_keeper_keepalive_helpers.exe` (TMPDIR 을 저장소 내
  쓰기 가능 경로로 지정해 `/tmp` 읽기전용 결함 회피).
- 배포 후 함대 수준 확인은 감사문서 §12 의 jq 파이프라인으로 재실측하면 된다:
  comment 후보 수가 0보다 커지는지 (운영 담당).

## 3. 명령과 출력 전문

### 3.1 수정 전 (적색)

명령 (실행 exit code 1):

```sh
cd masc && git stash push -m "before-measure: lib only" \
  -- lib/keeper/keeper_board_audience.ml lib/keeper/keeper_keepalive_signal.ml \
  && TMPDIR="$PWD/.dune-tmp" dune exec test/test_keeper_keepalive_helpers.exe
# 이후 git stash pop
```

출력 전문 (ANSI 색상 코드 제거, 그 외 무손실):

```text
Saved working directory and index state On main: before-measure: lib only
Testing `keeper keepalive helpers'.
This run has ID `471NCSDM'.

  [OK]          current_task_reconciliation          0   heartbeat reconciles...
  [OK]          directive_orphan_warn_gate           0   first unknown keeper...
  [OK]          directive_orphan_warn_gate           1   same unknown keeper ...
  [OK]          directive_orphan_warn_gate           2   clock regression doe...
  [OK]          directive_orphan_warn_gate           3   warn gate is per agent...
  [OK]          directive_orphan_warn_gate           4   warn gate state is b...
  [OK]          board_signal_delivery                0   goal keyword overlap...
  [OK]          board_signal_delivery                1   mentions use exact t...
  [OK]          board_signal_delivery                2   closed audience rout...
  [OK]          board_signal_delivery                3   exact mentions deliv...
  [OK]          board_signal_delivery                4   mixed address signal...
  [OK]          board_signal_delivery                5   paused exact mention...
  [OK]          board_signal_delivery                6   Restarting exact men...
  [OK]          board_signal_delivery                7   lane metadata failur...
  [OK]          board_signal_delivery                8   thread participant w...
  [OK]          board_signal_delivery                9   thread participant d...
> [FAIL]        board_signal_delivery               10   comment routes bysta...
  [OK]          board_signal_delivery               11   comment on own post ...
  [OK]          board_signal_delivery               12   vote on own post wak...
  [OK]          board_signal_delivery               13   vote on own comment ...
  [OK]          interruptible_cadence                0   directed wake cuts c...
  [OK]          interruptible_cadence                1   explicit stop cuts c...
  [OK]          interruptible_cadence                2   cadence wake consume...
  [OK]          interruptible_cadence                3   cadence handshake pr...
  [OK]          interruptible_cadence                4   autoboot warmup boun...
  [OK]          interruptible_cadence                5   elapsed warmup keeps...
  [OK]          interruptible_cadence                6   rate-limit backoff c...
  [OK]          interruptible_cadence                7   sleep distinguishes ...

┌──────────────────────────────────────────────────────────────────────────────┐
│ [FAIL]        board_signal_delivery               10   comment routes by...  │
└──────────────────────────────────────────────────────────────────────────────┘
[2026-09-02 23:05:13] [INFO] [Workspace] MASC base resolved: /Users/dancer/me/.masc/playground/rondo/masc/.dune-tmp/keeper-heartbeat-current-task8b2912 → /Users/dancer/me/.masc/playground/rondo/masc (git root)
[2026-09-02 23:05:13] [INFO] [Workspace] Ignoring test MASC_BASE_PATH override=/Users/dancer/me/.masc/playground/rondo/masc/.dune-tmp/keeper-heartbeat-current-task1fd856 for requested path /Users/dancer/me/.masc/playground/rondo/masc/.dune-tmp/keeper-heartbeat-current-task8b2912
[2026-09-02 23:05:13] [ERROR] [Backend] task-351 guard: keeping scratch base /Users/dancer/me/.masc/playground/rondo/masc/.dune-tmp/keeper-heartbeat-current-task8b2912 for temp-dir request
[2026-09-02 23:05:13] [INFO] [Workspace] Synchronized MASC_BASE_PATH=/Users/dancer/me/.masc/playground/rondo/masc/.dune-tmp/keeper-heartbeat-current-task8b2912 for test executable test_keeper_keepalive_helpers.exe
[2026-09-02 23:05:13] [INFO] [Keeper] registry: registering keeper name=threadlane base_path=/Users/dancer/me/.masc/playground/rondo/masc/.dune-tmp/keeper-heartbeat-current-task8b2912 phase=running
[2026-09-02 23:05:13] [WARN] [Board] backend() called before server init, auto-initializing JSONL
[2026-09-02 23:05:13] [INFO] [Keeper] registry: registering keeper name=bystanderlane base_path=/Users/dancer/me/.masc/playground/rondo/masc/.dune-tmp/keeper-heartbeat-current-task8b2912 phase=running
ASSERT participant lane keeps direct delivery
ASSERT bystander lane escalates to judgment
File "test/test_keeper_keepalive_helpers.ml", line 1099, character 7:
FAIL bystander lane escalates to judgment

   Expected: `true'
   Received: `false'

Raised at Alcotest_engine__Test.check in file "src/alcotest-engine/test.ml", lines 216-226, characters 4-19
Called from Dune__exe__Test_keeper_keepalive_helpers.test_comment_routes_bystander_lane_to_a in file "test/test_keeper_keepalive_helpers.ml", lines 1099-1102, characters 7-48
Called from Stdlib__Fun.protect in file "fun.ml", line 34, characters 8-15
Re-raised at Stdlib__Fun.protect in file "fun.ml", line 39, characters 6-52
Called from Stdlib__Fun.protect in file "fun.ml", line 34, characters 8-15
Re-raised at Stdlib__Fun.protect in file "fun.ml", line 39, characters 6-52
Called from Eio_unix__Thread_pool.run in file "lib_eio/unix/thread_pool.ml", line 108, characters 8-13
Re-raised at Eio_unix__Thread_pool.run in file "lib_eio/unix/thread_pool.ml", line 113, characters 4-39
Called from Eio_linux__Sched.run.(fun) in file "lib_eio_linux/sched.ml", line 468, characters 22-90
Re-raised at Eio_linux__Sched.run.(fun) in file "lib_eio_linux/sched.ml", line 479, characters 22-57
Called from Eio_linux__Sched.with_eventfd in file "lib_eio_linux/sched.ml", line 506, characters 8-18
Re-raised at Eio_linux__Sched.with_eventfd in file "lib_eio_linux/sched.ml", line 511, characters 4-19
Called from Eio_linux__Sched.with_sched in file "lib_eio_linux/sched.ml", lines 543-545, characters 8-109
Re-raised at Eio_linux__Sched.with_sched in file "lib_eio_linux/sched.ml", line 556, characters 8-43
Called from Alcotest_engine__Core.Make.protect_test.(fun) in file "src/alcotest-engine/core.ml", line 186, characters 17-23
Called from Alcotest_engine__Monad.Identity.catch in file "src/alcotest-engine/monad.ml", line 24, characters 31-35

Logs saved to `/masc-work/rondo/masc/_build/_tests/keeper keepalive helpers/board_signal_delivery.010.output`.
──────────────────────────────────────────────────────────────────────────────
Full test results in `/masc-work/rondo/masc/_build/_tests/keeper keepalive helpers`.
1 failure! in 0.588s. 28 tests run.
On branch main
Your branch is up to date with 'origin/main'.

Changes not staged for commit:
	modified:   lib/keeper/keeper_board_audience.ml
	modified:   lib/keeper/keeper_keepalive_signal.ml
	modified:   test/test_keeper_keepalive_helpers.ml

no changes added to commit (use "git add" and/or "git commit -a")
Dropped refs/stash@{0} (7d46ef068422cf4bad4abff2de4ea6dd4fcf4e00)
== stash after pop ==
 M lib/keeper/keeper_board_audience.ml
 M lib/keeper/keeper_keepalive_signal.ml
 M test/test_keeper_keepalive_helpers.ml
```

### 3.2 수정 후 (녹색)

명령 (실행 exit code 0):

```sh
cd masc && mkdir -p .dune-tmp && \
  TMPDIR="$PWD/.dune-tmp" dune exec test/test_keeper_keepalive_helpers.exe
```

출력 전문 (ANSI 색상 코드 제거, 그 외 무손실):

```text
Testing `keeper keepalive helpers'.
This run has ID `VH4AWTUP'.

  [OK]          current_task_reconciliation          0   heartbeat reconciles...
  [OK]          directive_orphan_warn_gate           0   first unknown keeper...
  [OK]          directive_orphan_warn_gate           1   same unknown keeper ...
  [OK]          directive_orphan_warn_gate           2   clock regression doe...
  [OK]          directive_orphan_warn_gate           3   warn gate is per agent...
  [OK]          directive_orphan_warn_gate           4   warn gate state is b...
  [OK]          board_signal_delivery                0   goal keyword overlap...
  [OK]          board_signal_delivery                1   mentions use exact t...
  [OK]          board_signal_delivery                2   closed audience rout...
  [OK]          board_signal_delivery                3   exact mentions deliv...
  [OK]          board_signal_delivery                4   mixed address signal...
  [OK]          board_signal_delivery                5   paused exact mention...
  [OK]          board_signal_delivery                6   Restarting exact men...
  [OK]          board_signal_delivery                7   lane metadata failur...
  [OK]          board_signal_delivery                8   thread participant w...
  [OK]          board_signal_delivery                9   thread participant d...
  [OK]          board_signal_delivery               10   comment routes bysta...
  [OK]          board_signal_delivery               11   comment on own post ...
  [OK]          board_signal_delivery               12   vote on own post wak...
  [OK]          board_signal_delivery               13   vote on own comment ...
  [OK]          interruptible_cadence                0   directed wake cuts c...
  [OK]          interruptible_cadence                1   explicit stop cuts c...
  [OK]          interruptible_cadence                2   cadence wake consume...
  [OK]          interruptible_cadence                3   cadence handshake pr...
  [OK]          interruptible_cadence                4   autoboot warmup boun...
  [OK]          interruptible_cadence                5   elapsed warmup keeps...
  [OK]          interruptible_cadence                6   rate-limit backoff c...
  [OK]          interruptible_cadence                7   sleep distinguishes ...

Full test results in `/masc-work/rondo/masc/_build/_tests/keeper keepalive helpers`.
Test Successful in 0.630s. 28 tests run.
Warning: option "-j-std" is deprecated.
```

## 4. 표면별 판단 도달 매트릭스 (결정론적 스위트 기준)

| 신호 × 레인 상태 | 수정 전 | 수정 후 |
| --- | --- | --- |
| comment × Thread_participants × 참여 레인 (이전 셀프 댓글 후 외부 댓글) | `Deliver Thread_reply_after_self_comment` (직접 전달) | 동일 (무변경, 케이스 8·9·10 전반부) |
| comment × Thread_participants × 우연(비참여) 레인 | `Ignore` → 판단 후보 0건 (**굶음**) | `Judge_discoverable` → attention 후보 1건, 레인 이벤트 큐 0건 |
| comment × 자기 글/자기 댓글 | `Deliver` (직접 전달) | 동일 (케이스 11) |
| post_created × Discoverable | `Judge_discoverable` → 후보 | 동일 (`audience="discoverable"` 라벨 유지) |
| vote/reaction × Thread_participants × 비참여 | `Ignore` | 동일 (`Ignore` 유지 — replay scan 이 post_created 만 재합성하므로 push 가 유일 생산자인 건 댓글뿐) |
| 기존 회귀 (#25600 store 실패 경로) | `Unavailable` 전파 | 동일 (무변경) |

## 5. 변경 지점 (파일:줄, 병합 시점 기준)

- `lib/keeper/keeper_board_audience.ml:79` — `Thread_participants` 갈래: `Available None` 에서
  댓글 신호만 `Judge_discoverable` 로 승격, 나머지 kind 는 기존 `Ignore` 접기 유지.
- `lib/keeper/keeper_keepalive_signal.ml:373` — `record_board_attention_candidate` 에
  `~audience_label` 인자 추가(기존 `"discoverable"` 하드코딩 제거).
- `lib/keeper/keeper_keepalive_signal.ml:612` — Discoverable 갈래는 동일 라벨(`"discoverable"`)로 유지.
- `lib/keeper/keeper_keepalive_signal.ml:727` — 즉시전달 루프: 댓글 신호의
  `Judge_discoverable` 은 후보 기록으로 소비, 다른 kind 는 기존
  `unexpected_discoverable_immediate_route` fail-visible 유지.
- `test/test_keeper_keepalive_helpers.ml` — 회귀 2건 추가(케이스 10·11).

## 6. 결과 요약

- 적색: 28 run 1 failure (댓글 우연 레인 후보 0건)
- 녹색: 28 run 0 failure
- 기존 26케이스 전후 무차이 — 결함 경로만 이동, 회귀 없음.

## 7. PR / 병합

- PR: (PR 생성 후 기입)
- 병합 SHA: (병합 후 기입)
