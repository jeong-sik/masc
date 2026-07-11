# RFC-0342: Dead/paused keeper event-queue reap — close the write-only black hole

- Status: Draft
- Author: Claude (Fable 5)
- Date: 2026-07-11
- Related: RFC-0246 (wake-cascade-recovery-tombstone), RFC-0022 (runtime-attempt-liveness), RFC-0341 (keeper-lifecycle-projection-ssot)
- Subsystem: keeper supervision / event queue (correctness-critical: a supervisor regression can freeze the whole fleet)

## 원문 (사용자 보고, 2026-07-11)

> "keeper drain event queue pending, since 2026.07.10 오후 06:29. 7시간 가까이 drain이 안 비워지고 있다 … 이거 drain 이 안되는게 맞는거아님? 고쳐야하는 부분 고쳐야해"

맞다. drain은 안 되고 있으며, 이는 로직 버그가 아니라 **설계 공백**이다. 이 RFC가 그 공백을 닫는다.

## 1. 실측된 문제 (라이브 재현 + file:line, 2026-07-11)

라이브 인스턴스에서 keeper `rondo`가 `paused=true`, `keepalive_running=false`, `latched_reason=Dead_tombstone`, `auto_resume_after_sec=null` 상태이고, 그 event queue에 `2026-07-10T09:29:33Z`(=18:29 KST)부터 배수되지 않은 항목이 7시간째 남아 있었다.

**근본 = enqueue와 drain의 liveness 비대칭 (adversarial 검증 완료):**

1. **enqueue는 liveness를 검사하지 않는다** — 생산자는 대상 keeper의 `paused`/`keepalive_running`을 보지 않고 무조건 durable event_queue에 쓴다. `keeper_registry_event_queue.ml:74-109` (`enqueue`): 등록된 keeper면 live-atomic CAS + persist, 미등록이면 "persisting stimulus for replay"로 디스크에 쓴다. 어느 쪽도 무조건.
2. **drain은 keeper 자신의 live heartbeat 안에서만 실행된다** — 유일 소비자: `keeper_heartbeat_stimulus_intake.ml:343` `heartbeat_event_intake` → `Keeper_registry_event_queue.drain_board` (`keeper_registry_event_queue.ml:253`), `keeper_heartbeat_loop`에서만 호출. `keepalive_running=false`면 절대 안 돈다.
3. 따라서 죽거나 멈춘 keeper = **write-only 블랙홀**: 생산자는 계속 append, 아무도 read 안 함, supervisor/janitor/TTL 어느 것도 배수·재배정·만료하지 않는다.
4. **cleanup은 큐를 비우지 않고 unregister한다** — `keeper_supervisor_cleanup_tombstone.ml:88` `Keeper_registry.unregister`가 durable pending/inflight 스냅샷을 그대로 남긴다. Phase-3 stale-paused prune(`keeper_supervisor.ml:877-908`)은 **meta 파일만** `Sys.remove`하고 큐 스냅샷 파일은 안 건드려, reap 시 배수 없이 유실된다.

이는 사용자 스펙("keeper는 무한히 살아있음", "하나 멈추면 다 멈추는 건 망가진 기능", "Silent Failure 명시적 구현")을 정면 위반한다.

### 1.1 죽음의 경로 (참고)

rondo는 restart-budget 소진(`keeper_supervisor.ml:759-783`, `BudgetNeverRevives` → `mark_dead`)으로 죽어 `Dead_tombstone`으로 latch됐다. `cleanup_dead_tombstone`이 **의도적으로** `auto_resume_after_sec=None`(`:61`)을 써서 auto-resume(`keeper_supervisor.ml:950`, `paused_meta_auto_resume_due`)을 원천 차단한다 — `Dead_tombstone` = "인간 리뷰 필요, 자동 재시작 금지"가 **설계 의도**다(operator-gated). 이 RFC는 그 게이트를 **바꾸지 않는다**(§4 Non-goals).

## 2. 설계 — supervisor를 죽은 keeper 큐의 fallback 소유자로

supervisor는 keeper liveness와 무관하게 자기 cadence로 돌며 이미 keeper를 순회한다(`to_mark_dead`/cleanup). 이걸 fallback 소유자로 만든다.

### 2.1 reap 지점에서 dead-letter 배수

두 reap 지점 각각에서, unregister/remove **직전이 아니라** 규정된 순서로 durable 큐를 typed append-only dead-letter sink로 배수하고 operator-attention lifecycle 이벤트를 emit한 뒤 persistence를 정리한다:

- `keeper_supervisor_cleanup_tombstone.ml` — reason `Dead_tombstone_reap`.
- `keeper_supervisor.ml` Phase-3 prune — reason `Paused_prune_reap`, drained depth를 `Paused_pruned` 이벤트에 실어보낸다.

새 모듈 `keeper_event_deadletter.ml(.mli)`: closed reason variant(`Dead_tombstone_reap | Paused_prune_reap`), SSOT 경로 상수, 매직넘버·문자열 이유 없음. counter가 아니라 **복구 가능한 typed record**(anti-telemetry-as-fix 충족).

### 2.2 correctness 요건 (adversarial 검증이 잡은 3 blocker + must-fix의 해소책 — 필수)

이 요건들을 지키지 않으면 **fix가 오히려 새 silent failure를 만든다**. 구현은 반드시:

1. **at-least-once, exactly-once 아님.** substrate가 at-least-once다(`keeper_event_queue_persistence.mli:101-106`: inflight를 pending 앞에 병합해 restart replay). dead-letter 키는 **idempotent**(post_id/stimulus id 기반)로, 재replay 시 중복이 무해하게 한다. "count in == count out" 같은 exactly-once 불변식을 **주장하지 않는다**.
2. **producer 레이스 차단.** enqueue는 등록된 entry에 liveness 없이 쓴다(`keeper_registry_event_queue.ml:98-108`). 따라서 dead-letter는 **durable 스냅샷에서, unregister 이후에** 읽는다(등록 해제 후엔 enqueue가 미등록 경로 = replay-persist로 가므로 dead-letter가 그 파일도 흡수). "drain snapshot → clear → unregister"의 비원자 창을 없앤다.
3. **inflight 포함.** live 스냅샷(`snapshot`, `:222-226`)은 pending만 준다. `load_snapshot_pair`(pending+inflight, `mli:101-106`)로 읽어 mid-turn에 lease된 inflight stimulus 유실을 막는다.
4. **prune에서 큐 persistence를 정리.** prune은 meta만 지운다(`keeper_supervisor.ml:877-879`). dead-letter 후 큐 스냅샷 파일도 정리해, 같은 이름 재등록(operator recreate) 시 재replay(이중처리)를 막는다.
5. **Eio.Cancel.Cancelled 보호.** 배수 I/O는 기존 finally-cleanup 가드(`keeper_supervisor.ml:914-921`) 안에 두어 취소가 재-raise되지 않게 한다(2026-05-05 cycle9 회귀 클래스).

### 2.3 왜 부활이 아니라 배수인가

pure resurrection(auto-revive)은 이 한 건은 풀지만 blind-producer와 head-of-line 클래스를 남겨, 다음 paused/dead keeper가 같은 블랙홀을 재생산한다. 또 `Dead_tombstone` auto-revive에 cap/cooldown을 붙이는 것은 CLAUDE.md의 워크어라운드 시그니처(cap-cooldown)라 거부된다. 배수 + operator-gated resume이 스펙("Pause only when truly broken" + operator review)을 지키는 root fix다.

### 2.4 status가 WHY를 말하게 (surfacing)

`keeper_reaction_ledger.ml`이 이미 계산하는 `durable_event_queue_is_stale`/`oldest_arrived_at`(`:650-655`)와 timed-out approval을 `masc_keeper_status`/`keeper_waiting_inventory` 출력에 소비한다. 지금은 신호만 계산하고 아무도 소비하지 않아, `next_human_action=resume_or_review`가 "왜"(09:29 pending + 600s approval_timeout)를 안 말한다.

## 3. 곁다리 실버그 (독립 수정 가능) — disposition "completed" 오표시

`runtime_agent.ml:149`가 status `"completed"`를 emit하는데 `keeper_turn_disposition.of_wire`(`:264-276`)의 closed mapping에 그 토큰이 없어 `Unknown_bad`로 떨어진다 → 정상 완료 turn이 `severity=bad`로 표시된다(rondo status의 `terminal_reason.code="completed", severity="bad"` 미스터리의 정체). 수정: `of_wire`에 `| "completed" -> Success` arm 추가(문자열 패치가 아니라 **알려진 토큰을 closed mapping에 등록**) + `runtime_agent`가 emit하는 모든 status 토큰이 `of_wire`에 존재함을 강제하는 property 테스트. 이 건은 §2와 독립적이라 먼저 머지 가능.

## 4. Non-goals (명시)

- **Dead_tombstone auto-revive 하지 않는다.** operator-gated가 설계 의도(`keeper_supervisor.ml:716-721`). 배수는 부활과 무관하게 유실만 막는다.
- **Issue B(gemma-4-E2B tool 오류)의 typed admission gate를 만들지 않는다.** adversarial 검증이 이를 **fleet-wide 부트스트랩 데드락**으로 반증했다: `tool_use_verified`가 rollout 시 전부 false면 tool-capable 기본모델(`ollama_cloud.deepseek-v4-flash`, `runtime.toml:13/129`)조차 거부해 모든 tool-요구 keeper 바인딩이 막힌다 — 지금보다 나쁨. 또한 rondo 죽음의 근본 원인이 아니다(마지막 turn 24089는 정상 완료, tool-parse 오류 무기록; restart-budget/liveness 축으로 죽음). Issue B는 latent hardening으로 별도 RFC(RFC-0022 계열)에서, 검증된 fleet에 `verified=true`를 먼저 seed하고 gate는 hard-refuse가 아니라 drop-tools+latch로 degrade하는 순서를 명시해 다룬다.
- HOL-block skip(`dequeue_when` un-ready front) 및 completed-but-bad 품질 failover는 ordering/lifecycle 시맨틱을 바꾸므로 RFC-0246에서 별도.

## 5. 완료 기준 / 테스트

- `cleanup_dead_tombstone`에 non-empty durable 큐(pending+inflight) → 모든 stimulus가 `Dead_tombstone_reap`로 dead-letter, persistence 정리, idempotent 키로 중복 무해, 유실 0. (at-least-once 명시)
- Phase-3 prune에 non-empty 큐 → `Paused_prune_reap` dead-letter + 큐 persistence 정리 → 같은 이름 재등록 시 재replay 0. 취소 during cleanup은 재-raise 안 함.
- 미등록 후 enqueue가 replay-persist로 간 stimulus도 dead-letter가 흡수(레이스 창 0).
- `masc_keeper_status`(paused Dead_tombstone, pending 1 + timed-out approval) → `pending_event_queue_depth>=1`, `oldest_arrived_at`, blocking `approval_timeout` 노출.
- disposition: `of_wire "completed" = Success`(non-bad), 그리고 `runtime_agent`가 emit 가능한 모든 토큰이 `of_wire`에 존재(property).

## 6. 즉시 완화 (코드 무관, operator)

rondo를 지금 풀려면: **먼저 runtime을 tool-capable 모델로 repoint한 뒤**(그대로 resume하면 gemma-4-E2B에 재바인딩되어 재사망) `masc_keeper_up rondo`(Operator_resume) — resume이 `paused`/`latched_reason`을 지우고 keepalive를 재기동, 첫 heartbeat가 `heartbeat_event_intake`→drain으로 밀린 stimulus를 배수한다(그 approval은 2일 전 timeout이라 ready). 재배수만 원하면 stimulus를 수동 dead-letter. 이 RFC가 머지되면 이 완화는 자동화된다.

## 7. 위험

- supervisor 변경은 잘못되면 **전 fleet 정지**다. dune 빌드는 CI라 로컬 컴파일 불가 → 변경은 inspection으로 type-correct해야 하고, reap 사이트의 Eio 취소 가드를 반드시 보존.
- multi-file(신규 dead_letter 모듈 + 2 supervisor 편집 + reaction_ledger surfacing). 각 caller 전수 확인 필요.
