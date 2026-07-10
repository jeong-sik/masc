# RFC-0297: Keeper lifecycle gate consistency & observability

**Status**: Draft
**Date**: 2026-06-29
**Scope**: `masc` keeper autoboot/reactive/proactive/autonomous 게이트, config SSOT, orphan stimulus 관측, FSM 결정 SSOT
**One sentence**: keeper lifecycle의 reactive/proactive/autonomous 게이트가 코드에 존재하지 않아 silent ignore되고, 운영 config가 git에 영속되지 않아 재발하며, orphan stimulus가 30분 no-op spin하는 허점을 closed-variant 게이트 + config SSOT + 관측 강제로 닫는 설계 RFC.

## Related Documents

- `~/me/memory/reference-masc-autoboot-excluded-silent-proactive-death.md` (06-26)
- `~/me/memory/reference-masc-keeper-orphan-stimulus-persistence-20260627.md` (06-27)
- RFC-0250 (keeper idle crash)
- `lib/server/server_bootstrap_loops.ml`, `lib/keeper_runtime/keeper_runtime_config.ml`, `lib/config/env_config_keeper.ml`, `lib/keeper/keeper_heartbeat_loop.ml`, `lib/keeper/keeper_supervisor.ml`

## Status Note

이 문서는 구현 승인 전 합의용 RFC다. 승인 전 코드 변경 없음.

## Context

2026-06-29 적대적 메커니즘 조사(Workflow 5-dimension)가 keeper lifecycle 전체에서 **29개 허점(P0 3, P1 11, recurring 14)**을 발견했다. recurring 14는 메모리 사례(06-26 autoboot excluded silent, 06-27 orphan stimulus spin, 06-28 `declarative_autoboot_disabled` 재발)와 일치 — 재발이 단일 버그가 아니라 **메커니즘 허점**에서 온다는 확증이다.

## Problem (P0)

### P0-1: reactive/proactive/autonomous `enabled` 게이트가 코드에 없다 (silent ignore)
- `lib/keeper_runtime/keeper_runtime_config.ml`의 `key_to_env` 테이블이 reactive/proactive/autonomous의 `enabled` 키를 매핑하지 않는다(autonomous는 `fairness_cooldown_sec`/`max_idle_turns`, reactive는 `max_idle_turns`, proactive는 `min_interval_sec`만).
- runtime.toml 최상단 주석 "Unknown TOML keys are silently ignored" — `[proactive] enabled = false`를 써도 조용히 버려진다.
- 즉 global kill switch가 **코드에 존재하지 않**; keeper가 alive하면 loop는 항상 on. 운영자가 "proactive를 껐다"는 의도가 silent하게 무력화된다.
- short-circuit(메모리 06-26 일치): reactive trigger(mention/board event/scope message/event-queue)가 하나라도 있으면 `keeper_cycle_decision`이 `meta.proactive.enabled`/`meta.autoboot_enabled` 게이트 검사를 건너뛰고 곧바로 Run Reactive를 반환한다.

### P0-2: orphan bootstrap stimulus no-op spin 30분 alarm 없음 (recurring)
- orphan bootstrap stimulus가 event-queue에서 requeue 반복(`lib/keeper/keeper_heartbeat_loop.ml:418-433`). `consumed_stimuli_turn_completed=false`일 때 `requeue_front` + `ack_inflight` 매 cycle 반복.
- 매 턴 info 로그만, "같은 post_id가 N턴째 재진입" threshold alert가 없다.
- `stale_run` threshold(1800s = 30분, `lib/config/env_config_runtime.ml:406`) 전까지 keeper가 'busy'로 보이지만 실제 진전 없음. `pending_stimulus_count`(`lib/keeper/keeper_reaction_ledger.ml:740/1037`)는 노출되나 threshold breach alert가 없다.
- 메모리 06-27(keeper Play→멈춤)과 동일 경로.

### P0-3: 운영 config(.masc/config)가 .gitignore → fresh deploy 회귀 (recurring)
- `<base-path>/.masc/config/`가 `.gitignore`(L23)로 git 추적 제외.
- fresh deploy/clone/base_path 재설정 순간 git 템플릿(masc repo `config/keepers/*.toml`, `autoboot_enabled=false`)으로 회귀한다.
- 06-26 fix(autoboot_enabled=true)가 06-28 재발한 근본 — live override가 git 어디에도 기록되지 않아 재생성되면 날아간다. 비교: `workspace/.../masc/config/keepers/base.toml:11 = false` vs `<base-path>/.masc/config/keepers/base.toml = true`.

## Problem (P1, 주요)

- **Phase 3.5 auto-resume declarative 게이트 우회**(`lib/keeper/keeper_supervisor.ml:822`): paused + declarative-false keeper가 resume 시도 → 거짓 telemetry(`AutoResumedTotal` / `Operator_resume`). `paused_meta_auto_resume_due`가 declarative gate를 검사 안 함. 반면 `auto_recoverable_paused_keeper_names`(`keeper_runtime.ml:213-218`)는 gate 적용 — 두 경로 divergence = FSM anti-pattern(CLAUDE.md §4).
- **bootable keeper 0개 시 alarm 없음**(`server_bootstrap_loops.ml:822`): INFO만, retry 게이트 `booted_count < total`이 `total=0`이면 `0<0` skip. fleet-wide 오구성(전 keeper declarative-false / paused / global off 착각)이 silent.
- **`[autonomous]`/`[reactive]` `concurrency`/`semaphore_wait_timeout_sec` dead config**(소비처 0) — 운영자가 "reactive 동시성 4 제한"이라 믿고 설정해도 효과 없음.

## Proposal

### Design principle
keeper lifecycle 결정(boot/reactive/proactive/autonomous/pause/resume)을 **closed-variant 게이트 + 단일 SSOT 판정 함수 + 관측 강제**로 통일한다. silent ignore / short-circuit / non-persistent override를 제거한다. CLAUDE.md "no Silent Failure" + "make illegal states unrepresentable"에 정렬.

### Phase 1: closed-variant gate (P0-1)
- `keeper_runtime_config.ml` 매핑에 `reactive.enabled` / `proactive.enabled` / `autonomous.enabled` → 전용 env(`MASC_REACTIVE_ENABLED` / `MASC_PROACTIVE_ENABLED` / `MASC_AUTONOMOUS_ENABLED`) 추가.
- closed sum `keeper_lifecycle_gate = Reactive | Proactive | Autonomous | Bootstrap` + 단일 판정 함수 `Keeper_lifecycle.gate_enabled : gate -> config -> meta -> bool`.
- TOML 파서를 known-key 화이트리스트로 전환 — unknown key 시 WARN(silent ignore 폐지).
- short-circuit 폐지: `keeper_cycle_decision`이 reactive trigger 평가 **전**에 `gate_enabled Proactive`/`Autonomous`를 검사(순서 명시 + 주석으로 실행 경로).
- 기본값 true로 점진 전환(기존 "항상 on" 동작 유지), opt-in false.

### Phase 2: orphan stimulus observability + TTL (P0-2)
- event-queue depth + per-stimulus requeue count → Otel counter(`masc_keeper_stimulus_orphan_spin_total`) + WARN("같은 post_id가 N턴 연속 requeue").
- `pending_stimulus_count > 임계값` 시 `fleet_safety` status를 degraded로 격상.
- orphan bootstrap stimulus(boot 시점 1회)에 TTL 기반 자동 만료(requeue N회 후 drop + metric). 근본 fix는 stale threshold 단축이 아니라 spin 자체 차단.

### Phase 3: config SSOT (P0-3)
- 운영 runtime.toml/keeper.toml을 git-tracked SSOT로 승격(`config/live/` 분리 + `.gitignore` 예외) 또는 declarative 값(`autoboot_enabled`/`proactive_enabled`)을 operator manifests로 git 영속화 + base_path derive symlink/복사.
- bootstrap regenerate 경로가 live 값을 템플릿으로 덮어쓰지 못하게 차단.
- deploy/base_path 변경 migration 스크립트 포함.

### Phase 4: FSM decision SSOT (P1)
- auto-resume / bootable / pause 게이트를 단일 SSOT 함수(`Keeper_lifecycle.boot_decision / resume_decision : state -> config -> meta -> decision`)로. 양 caller(supervisor Phase 3.5, `keeper_runtime` auto_recoverable)가 호출. divergence 제거.
- `bootable 0 + configured > 0` 시 WARN + board/Slack 알람. exclusion 이유 카운트를 Otel metric(`autoboot_excluded_total{reason}`)으로.
- dead config(`[autonomous]`/`[reactive]` concurrency/semaphore_wait_timeout) 제거 또는 소비 연결.

## Alternatives / Tradeoffs

- **전체 closed-variant 대신 per-keeper meta만 유지**: global kill switch 계속 부재 → P0-1 미해결. 기각.
- **config SSOT 없이 operator 문서화만**: 재발 회피 불가(06-26→06-28이 증명). 기각.
- **orphan TTL 대신 stale threshold 단축(1800s→N)만**: symptom 완화일 뿐 spin 자체 안 없음. 보조 수단으로만.
- **Phase 1 default true 전환이 기존 "항상 on" 깨뜨릴 위험**: 점진적 도입(default true + 명시 false만 효과)으로 완화. 게이트 도입 자체가 관측(value 노출)을 수반하므로 rollback 가시성 확보.

## Risks

- Phase 1 gate 도입 시 기존 "keeper alive = 항상 on" 동작 깨짐 → 점진적(default true + opt-in false).
- Phase 3 config SSOT 전환 시 deploy 파이프라인/base_path 변경. migration 필요.
- orphan TTL이 legitimate 장기 stimulus를 잘못 drop 가능 → TTL + requeue count 이중 게이트로 완화.
- FSM SSOT(Phase 4)가 supervisor/runtime 양쪽 시그니처 변경 → caller 전수 업데이트.

## Out of scope

- keeper persona/identity 변경.
- proactive LLM 비용 최적화(backoff cadence) — PR #22588 별도.
- keeper memory consolidation.

## Phases (구현 순서)

| Phase | 대상 | 의존 | TLA+ |
|-------|------|------|------|
| 1 | closed-variant gate + unknown key warn | — | gate 전이 모델 |
| 2 | orphan stimulus metric + TTL | — | — |
| 3 | config SSOT migration | 1 (gate 값 영속화) | — |
| 4 | FSM decision SSOT + dead config | 1 | FSM 전이 매트릭스 |

각 phase는 별도 PR. Phase 1/4는 TLA+ spec으로 safety property 검증(CLAUDE.md §TLA+ Bug Model).

## Verification (phase별)

- Phase 1: gate_enabled가 closed match로 모든 gate 검사; unknown TOML key WARN; short-circuit 제거 테스트(reactive trigger 있어도 proactive gate false면 턴 안 함).
- Phase 2: orphan stimulus N회 requeue 시 metric/alert; TTL 만료 후 drop.
- Phase 3: fresh deploy 시 live config 유지(git); bootstrap regenerate가 덮어쓰지 않음.
- Phase 4: auto-resume/bootable 양 caller가 동일 decision; bootable 0 시 알람.

## References (조사 근거)

- Workflow `masc-keeper-lifecycle-mechanism-audit`(2026-06-29): 5 area, 29 gap, P0 3, P1 11, recurring 14.
- `lib/keeper_runtime/keeper_runtime_config.ml:6`(주석), `:15-19/:29-30`(매핑).
- `lib/keeper/keeper_heartbeat_loop.ml:418-433`, `lib/keeper/keeper_supervisor.ml:822`, `lib/server/server_bootstrap_loops.ml:822`.
- `.gitignore:23`, runtime.toml "Unknown TOML keys silently ignored".
