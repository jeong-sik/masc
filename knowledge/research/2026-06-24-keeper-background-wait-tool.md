# Research: keeper "백그라운드 실행 후 대기/재개" 내부 tool

- 작성: 2026-06-24, vincent (+ Claude Opus 4.8)
- 방법: ultracode multi-agent workflow (5 reader 병렬 정독 → 설계 3안 → 안별 적대 검증 → 종합). 11/12 agent 성공, OAS async_agent reader 2회 모두 API 끊김으로 미완 → 해당 영역은 "확인 필요"로 명시.
- 후속: RFC-0290 (이 문서가 근거)
- 관련 RFC: RFC-0020 (hint/data 분리), RFC-0252/0266 (fusion), RFC-0286 (exec/keeper boundary), RFC-0287 (ws-direct)

이 문서는 설계 결정을 내리지 않는다. 현재 구현을 코드로 규명하고, 가능한 설계 공간을 다관점으로 평가한다. 결정은 RFC-0290.

---

## 1. 현재 masc는 어떻게 "잠들었다 깨어나는가"

### 1.1 구조: sustained fiber 안의 sleep↔turn 반복 (turn-yield가 아님)

keeper는 turn마다 재기동되지 않는다. keeper당 장기 Eio fiber 하나가 살아있고, 그 fiber 안에서 `let rec loop ()`가 sleep과 turn을 번갈아 돈다.

- 단일 fiber fork: `keeper_keepalive.ml:650 Eio.Fiber.fork ~sw:ctx.sw` → `:714 run_heartbeat_loop`
- 루프 본체: `keeper_heartbeat_loop.ml:738 let rec loop ()` — `if Atomic.get stop then () else (... loop ())`
- 각 iteration: (1) 메타/presence 동기화 → (2) smart-heartbeat gate 판정 → (3) turn 실행 → (4) 다음 cadence까지 sleep

핵심 구분: **"sustained fiber" ≠ "sustained in-memory context".** LLM 메시지 히스토리는 fiber 메모리에 상주하지 않고 매 turn 디스크 OAS checkpoint에서 재로드된다. OAS checkpoint의 typed message history가 대화 연속성의 SSOT이며, MASC의 task/goal/event 상태는 별도 typed store가 소유한다.

### 1.2 잠듦(wait): atomic-polling chunked sleep — Promise.await가 아님

- 두 sleep 사이트, 같은 primitive:
  - 인터-사이클 sleep: `keeper_heartbeat_loop.ml:952-957`
  - 아이들-백오프 sleep(gate의 Skip_idle): `keeper_heartbeat_loop.ml:600-605`
- primitive: `keeper_keepalive_signal.ml:235-261` — `chunk_sec`(기본 2.0s, `MASC_KEEPER_SLEEP_CHUNK_SEC`, range [0.1,10.0]) 단위로 `Eio.Time.sleep clock chunk`를 반복하며 매 chunk 전에 `stop`/`wakeup` atomic 확인. 반환 `sleep_outcome = Stopped | Woken | Timeout`.
- base interval: smart_hb이면 `Keeper_heartbeat_smart.effective_interval`, 아니면 `keepalive_interval_sec`(기본 30s, `MASC_KEEPER_HEARTBEAT_INTERVAL_SEC`[5,300], `env_config_keeper.ml:217-218`).

### 1.3 깨어남(wake): 외부 이벤트가 단일 bool atomic을 set

- `interruptible_sleep`이 `Atomic.compare_and_set wakeup true false` 성공 시 즉시 `Woken` 반환(`keeper_keepalive_signal.ml:246-252`). consume-once → missed-wakeup/thundering-herd 방지.
- SSOT: `Keeper_registry.wakeup` → `Atomic.set entry.fiber_wakeup true`(`keeper_registry.ml:357/365/385`, phase=Running 조건).
- 외부 트리거: board post(`server_bootstrap_loops.ml:443-446`), broadcast @mention(`:556-559`), gRPC directive(`keeper_keepalive.ml:225-318`).

### 1.4 "비동기 끝나면 이어서" — hint/data 분리 (RFC-0020)

1. 외부 이벤트가 `fiber_wakeup` atomic을 set (hint signal).
2. 작업 페이로드는 별도로 `Keeper_registry_event_queue`에 stimulus로 enqueue (data channel).
3. 깬 뒤 gate의 `pending_signal_present`(`keeper_heartbeat_loop.ml:504-533`)가 큐를 보고 Emit 강제 (RFC-0020 Rule 2).
4. turn dispatch의 `collect_keepalive_board_events`가 큐를 소비 → 결과가 turn 입력으로 도착.

`reactive_wake`(`last_wake_source=Woken`, `:852-857`)는 broadcast로 깬 turn이 전체 keeper를 스탬피드시키는 것을 억제한다.

### 1.5 별도 wait/wake 추상화: pulse.ml

`pulse.ml`은 keeper turn 루프가 아니다. `Eio.Fiber.first(timer vs Eio.Stream capacity-1 nudge)` 기반 추상화로 orchestrator(zombie/dedup)와 keeper_runtime supervisor sweep에만 쓰인다. 폴링 없이 latency≈0. "keeper가 어떻게 깨나"를 pulse.ml에서 찾으면 틀린 결론. (masc 안에 두 wait/wake 패턴이 공존: keeper loop=atomic-polling, supervisor=Fiber.first.)

---

## 2. 이미 존재하는 background+wait 레퍼런스

새 tool은 처음부터 만들 필요가 없다. 정확히 같은 패턴의 완성 구현이 2개 있다.

### 2.1 masc_fusion (주모델, RFC-0252/0266)

1. `keeper_tool_in_process_runtime.ml:400` `handle_masc_fusion`이 `Eio_context.get_root_switch_opt()`로 **서버수명 switch** 획득 (turn switch 아님 — turn 종료 시 취소 방지, 주석 `:392-399`).
2. `fusion_tool.ml:93 Fusion_run_registry.register_running` (fork **전**, in-memory Atomic+CAS, server-lifetime).
3. `fusion_tool.ml:103 Eio.Fiber.fork ~sw` + **즉시** `:134 {status:"fusion_started", run_id}` 반환 → keeper turn 막지 않음 (**await 안 함**).
4. 완료 회수 2경로: (a) push — `wakeup_keeper ~stimulus:(Fusion_completed ...)`, (b) poll — `masc_fusion_status`가 `Fusion_run_registry.global`을 keeper-scope 조회.
5. 취소 안전: 모든 종료 분기 `Cancelled`만 재전파, 나머지 흡수, 모든 분기 `mark_completed`. Cancelled 분기는 broadcast 생략하고 in-memory mark만 (`fusion_tool.ml:124-129`).

`Keeper_event_queue.stimulus_payload`는 닫힌 합(`keeper_event_queue.mli:54-65`), `Fusion_completed of fusion_completion` 포함 → 새 variant 추가 시 모든 exhaustive consumer를 컴파일러가 강제 (anti-workaround 설계).

### 2.2 Keeper_msg_async (대안 패턴)

submit→`request_id` 동기 반환, `Eio.Fiber.fork_daemon` 워커 + 워커 내부 **자체 child `Eio.Switch.run` 격리**, FSM(`Queued→Running→{Done|Cancelled|Lost}`) + 디스크 영속(재시작 후 Lost 복구) + timeout + 개별 cancel, `masc_keeper_msg_result` poll (`keeper_msg_async.ml:422`, surface `keeper_tool_surface_ops.ml:638`).

fusion 대비 차이: 디스크 영속 있음, child switch 격리(더 강건), poll-only(push wake 없음).

### 2.3 재사용 가능 인프라

- `domain_pool` (`submit_io_async`/`submit_cpu_async`, 무거운 실행 레인)
- provider admission queue는 제거됨. 장기 작업은 명시적인 run registry와 완료 wake를 사용하고, MASC에 provider-capacity gate를 다시 만들지 않는다.
- `server_bootstrap_loops_fiber.ml:21 fork_logged_fiber` (non-Cancelled 흡수 fault-iso 래퍼)
- subprocess 실행: `Autonomy_exec.run ~sw ~clock ~config ~argv ~timeout_s` (Result record 반환, `cdal_runtime/autonomy_exec.ml:295`). `Eio.Time.with_timeout_exn` 기반.

---

## 3. 설계 공간 — 3안 + 적대 검증

| | A. inline blocking await | B. turn-yield handle | C. hybrid |
|---|---|---|---|
| 요지 | 같은 tool이 promise await(timeout race) | fusion을 task-generic 일반화, await 없음 | A+B, timeout 분기 |
| tool surface | `bg_await`, `bg_status` | `bg_spawn`, `bg_status`, `bg_fetch` | `task_run/wait/status` |
| 대기 중 context | turn 열어둠 | 0 토큰 (turn 사이 disk checkpoint) | 혼합 |
| 적대 판정 | **survive (조건부, 4 fix)** | **false (P0 3개)** | **false (wait 제거 시 살림)** |

### 3.1 A안 — survive, 단 4 fix

- 치명: keeper=1 fiber serial → await 중 그 keeper가 board/mention에 deaf (head-of-line block). "zero latency" pro는 이 결함의 재서술. fusion이 fire-and-forget 택한 이유.
- "reuses verified infra"는 거짓: fusion은 fork 후 즉시 반환, await 절대 안 함. turn fiber가 root-switch fork promise를 block하는 것은 선례 없는 **새 wait primitive**.
- double-delivery: poll+wake 양쪽 결과 주입, drain 경계에 consumed guard 없음.
- 필수 fix: wait_ms 단자리 초 hard-clamp / typed `consumed` CAS flag / OAS async_agent LLM-job 분기 제거 / terminal exactly-once 4분기 테스트.

### 3.2 B안 — false (P0 3개)

- **P0① root switch FD leak**: `Autonomy_exec.run`의 spawn_child가 stdout/stderr FD를 `Eio.Switch.on_release ~sw`로 등록(`autonomy_exec.ml:231-232`). server-lifetime root switch에 fork하면 on_release는 서버 종료 시에만 발화 → **매 spawn마다 FD 2개 + 클로저 영구 누적**. fusion은 외부 subprocess가 없어 무해했음 — "기계적 일반화"가 깨지는 지점.
- **P0② admission cap 부재**: fusion은 `max_concurrent_panels` bound(`fusion_orchestrator.ml:42,123`). B안은 cap 없음. ~15 keeper × 무제한 spawn → root switch 무제한 fiber + `Eio_unix.run_in_systhread` waitpid blocking(`autonomy_exec.ml:310`) → systhread pool 압박 + scheduler starvation. CLAUDE.md backpressure 안티패턴의 정반대.
- **P0③ 시그니처 환각**: 설계가 `Autonomy_exec.run ~sw ~timeout command`로 호출했으나 실제는 `run ~sw ~clock ~config ~argv ~timeout_s` (Result record). workflow가 직접 재확인해 정정.

### 3.3 C안 — false as written, wait 제거 시 survivable

- inline await race + `task_wait` blocking re-await 둘 다 fusion에 선례 없는 net-new.
- `task_wait` backing store 없음: `fusion_run_registry`가 완료 엔트리를 `max_completed_retained=64` prune(`fusion_run_registry.ml:35,47-53`). wait 전 완료-prune되면 결과 silent loss.
- not-Running orphan: `wakeup_keeper`는 phase=Running일 때만 enqueue(`keeper_keepalive_signal.ml:272-283`). keeper paused/succession 중이면 `Task_completed` stimulus drop.
- 검증된 장점: scheduler starvation 없음 — `Promise.await`는 공유 단일 domain에서 yield(`keeper_supervisor_launch.ml:127`). 호출 keeper만 inline budget 동안 reactivity 정지.

---

## 4. OAS 경계 (부분 — async_agent API 미정독)

확인된 사실:
- keeper turn이 OAS 위에서 돈다(`run_turn`이 매 turn OAS checkpoint 로드, `keeper_agent_run.ml:262-263`).
- subprocess timeout primitive `Autonomy_exec.run`은 transport-level (OAS/Eio 측), keeper coordination 아님.

경계 규칙 (3안 일치):
- **MASC-only (OAS가 몰라야 함)**: bg run registry, `Keeper_event_queue` 완료 stimulus, `wakeup_keeper`/`fiber_wakeup`, heartbeat-loop drain, board 포스팅, keeper-scope 필터, tool descriptor.
- **OAS/Eio (MASC가 소비만)**: subprocess spawn/timeout, per-turn checkpoint, (있다면) async-agent 동시성 회계.
- **위반**: OAS async-tool 레이어가 `wakeup_keeper`를 호출하면 OAS가 keeper registry+board+event queue를 알게 됨(역방향 의존). result→wake 브릿지는 오직 MASC tool fiber의 terminal 콜백에서만.

확인 필요 (정독 안 됨):
- OAS `async_agent`/`approval` surface 정확한 API. 3안 모두 "LLM-job은 OAS async_agent 재사용"이라 했으나 미검증 추천.
- checkpoint **write** 타이밍 + root task fiber와 turn fiber의 동시 checkpoint read/write 위험 (C안 검증이 지목한 가장 유력한 OAS 경계 hazard).

---

## 5. 참고 구현 (claude-code / hermes / openclaw)

- workflow의 reference-impls reader가 부분 완료. claude-code의 background bash + 완료 시 재invoke 패턴, hermes의 watch_patterns substring + rate-limit(15s) + strike-limit가 확인됨.
- **차용 금지 신호**: hermes의 substring 매칭 + cooldown + strike-limit는 string 분류기 + cap/cooldown 워크어라운드 조합. masc는 typed 완료 시그널(닫힌 합 stimulus)을 우선.

---

## 6. 결론 (RFC-0290로 이어짐)

- 새 tool = fusion 일반화(B안 골격: fire-and-forget + 닫힌 합 stimulus wake). A의 inline은 짧은 opt-in만, C의 `task_wait`는 prune race로 초기 제외.
- B안 P0 3개(FD leak / cap 부재 / 시그니처)를 선결.
- `Autonomy_exec`는 임의 argv 실행 → keeper_sandbox/credential 인접 → **RFC 선행 필수** (CLAUDE.md agent_delegation, RFC-0286 boundary).
- 첫 PR(최소 증명): `keeper_event_queue` 닫힌 합에 `Bg_completed` variant 1줄 → 컴파일러가 모든 consumer를 강제.
