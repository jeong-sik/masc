# Adaptive Heartbeat and Cascade Scheduling RFC

**Status**: Draft
**Date**: 2026-03-29
**Scope**: Keeper keepalive, Keeper supervisor, Keeper registry, Room resilience, Cascade inference
**Tracking**: [#3635](https://github.com/jeong-sik/masc-mcp/issues/3635)
**One sentence**: 키퍼 하트비트를 work-as-heartbeat 기반 적응형으로 전환하고, restart 경로에 mass-failure 억제를 추가하며, cascade 레벨 스케줄링 방향을 제시한다.

## Related Documents

- `./contract-driven-agent-loop-rfc.md`
- `./oas-masc-state-boundary.md`
- `../SUPERVISOR-MODE.md`
- `../COMMAND-PLANE-RUNBOOK.md`

## Readiness Snapshot

- Phase 0 (Measurement): `Go` — config SSOT 정비 + per-stage profiling
- Phase 1 (Work-as-Heartbeat): `Go with caveats` — Phase 0 측정 결과에 따라 scope 조정
- Phase 2 (Restart Resilience): `Go` — self-preservation은 supervisor 경로만 수정
- Phase 2b (Phi Accrual): `No-Go` — gRPC heartbeat가 production에서 활성화된 후에만 착수
- Phase 3 (Cascade Scheduler): `No-Go` — Phase 0-2 baseline 2주 이상 확보 후 별도 RFC

## 1. Problem Statement

### 1.1 두 경로의 구분 (필수 전제)

Keeper liveness에는 두 개의 독립 경로가 있다. RFC의 모든 제안은 이 구분을 전제한다.

**Path A: Keeper Restart Cycle (supervisor 경로)**

```
keepalive fiber 실패 (presence sync 등)
  → consecutive_failures >= 5 (keeper_keepalive.ml:147)
  → Atomic.set stop true (self-stop)
  → Supervisor: Promise.peek done_p = `Crashed (keeper_supervisor.ml:123)
  → backoff_delay(restart_count): 10s → 20s → 40s → 80s → 160s → 300s
  → max_restarts 도달 시 "dead" 선언 (keeper_supervisor.ml:128)
```

Storm 조건: underlying cause(filesystem 장애, room directory 손상 등)가 지속되면 재기동된 keeper가 즉시 동일 실패를 반복한다. N개 keeper가 동시에 같은 원인으로 self-stop하면 supervisor가 N개를 동시에 restart 시도한다. 현재 backoff는 per-keeper이므로 mass simultaneous failure를 감지/억제하는 메커니즘이 없다.

**Path B: Room Zombie Cleanup (room_gc 경로)**

```
agent JSON의 last_seen ISO timestamp
  → now - last_seen > threshold (resilience.ml:46)
  → threshold: 300s (agent), 3600s (keeper) — 하드코딩 (resilience.ml:5, 60)
  → room_gc.ml:61: cleanup_zombies → stale agent file 삭제
```

이 경로는 keeper restart와 무관하다. Room에서 오래된 agent JSON 파일을 정리하는 hygiene 작업이다.

**Config SSOT 문제**: `resilience.ml`의 300.0/3600.0이 하드코딩되어 있고, `env_config_runtime.ml`의 env var surface와 연결되지 않음. 이 불일치가 Phase 0에서 먼저 정비되어야 한다.

### 1.2 Heartbeat_smart ↔ Keeper Loop 단절

`heartbeat_smart.ml`은 busy_skip + idle_multiplier를 구현하지만, `tool_heartbeat.ml` (MCP tool 경유 agent heartbeat)에서만 사용된다.

`keeper_keepalive.ml`의 30s loop는 이 로직을 적용하지 않는다. Unified turn을 막 완료한 keeper도 30초 후 무조건 full presence sync를 실행한다. Turn 완료 자체가 liveness 증거인데 인정하지 않는다.

이 단절이 코드로 확인된 유일한 구조적 비효율이다.

### 1.3 가설 (측정 필요)

다음은 per-stage profiling 전까지 가설이다:

- 30s loop에서 `ensure_keeper_room_presence`가 지배적 I/O 비용인지?
- `collect_board_events`, `maybe_tick_from_keepalive` 비용은 무시 가능한지?
- Room scope가 현재 single room (All == Current, keeper_coordination.ml:41-45)이므로 multi-room fan-out 비용은 0인지?

Phase 0에서 측정한다.

### 1.4 Unified Turn 중 Max Silence

Keepalive fiber는 단일 fiber다. `run_unified_turn` 호출(keeper_keepalive.ml:348) 중에는 loop가 blocking되어 presence sync나 lease 갱신이 불가능하다. 현재 실질적 max silence는 LLM inference timeout (~100s, Cloudflare constraint)이지만, 이 값이 zombie detection이나 supervisor sweep에 명시적으로 연결되어 있지 않다.

## 2. Non-Goals

- Eio runtime을 다른 concurrency 모델로 교체하지 않는다.
- Fiber memory 최적화 (50 keeper = ~200KB, LLM context 5GB 대비 무의미).
- 범용 workflow engine을 만들지 않는다 (CDAL RFC 범위).
- Room zombie cleanup(Path B) 알고리즘을 이 RFC에서 교체하지 않는다.
- Multi-domain scaling (single domain에서 50 keeper 운영에 충분).

## 3. Current State

### 3.1 Keepalive Loop (keeper_keepalive.ml:110-416)

30s + 20% jitter 주기로 다음을 순차 실행:

| Stage | Code | Cadence | I/O |
|-------|------|---------|-----|
| Room presence sync | `ensure_keeper_room_presence` (keeper_coordination.ml:47) | Every 30s | File read + write (single room) |
| Snapshot collection | JSONL append + SSE broadcast + OAS event | Every `snapshot_interval_sec` (300s) | File write + HTTP |
| Board event scan | `collect_board_events` (keeper_world_observation.ml) | Every 30s | Directory scan |
| Unified turn | `run_unified_turn` (conditional) | Proactive gate | LLM inference (blocking) |
| Recurring tasks | `dispatch_due` | Every 30s | Conditional broadcast |
| Improve loop tick | `maybe_tick_from_keepalive` | Every 30s | Unknown (needs measurement) |

### 3.2 Supervisor (keeper_supervisor.ml:114-169)

- Sweep interval: 30s (configurable via `KeeperSupervisor.sweep_interval_sec`)
- Detection: `Eio.Promise.peek entry.done_p`
- Restart: exponential backoff 10s→300s, max 5 restarts
- Reconciliation: durable keepers auto-recover on sweep

### 3.3 In-Process vs Network Failure Detection

| Detection Method | Layer | Latency | Used For |
|-----------------|-------|---------|----------|
| `Promise.peek done_p` | In-process | Instant (cooperative yield) | Fiber crash/stop |
| Room `last_seen` threshold | Filesystem | Fixed 300s/3600s | Stale agent file cleanup |
| gRPC HeartbeatAck | Network | Configurable | Remote keeper health (optional) |

### 3.4 Smart Heartbeat (heartbeat_smart.ml)

```ocaml
type config = {
  base_interval_s: float;     (* 30.0 *)
  idle_multiplier: float;     (* 3.0 *)
  busy_skip: bool;            (* true *)
  idle_threshold_s: float;    (* 300.0 *)
}
```

현재 `tool_heartbeat.ml:38`에서만 사용. `keeper_keepalive.ml`에 미적용.

## 4. Design

### Phase 0: Measurement and Config SSOT (1주)

**Objective**: 가설 검증 + config 하드코딩 정비.

**Step 0.1: Per-stage profiling**

`keeper_keepalive.ml` loop의 각 stage에 타이머 계측을 추가한다.

```ocaml
(* 예시: 각 stage를 Timer.with_timing으로 감싸기 *)
let presence_ms = Timer.measure (fun () -> ensure_keeper_room_presence ...) in
let board_ms = Timer.measure (fun () -> collect_board_events ...) in
(* ... *)
Metrics.record ~presence_ms ~board_ms ~snapshot_ms ~turn_ms ~recurring_ms ~improve_ms
```

측정값을 기존 metrics JSONL에 추가한다. 최소 1주간 수집 후 분석.

**Step 0.2: Config SSOT 정비**

`resilience.ml`의 하드코딩을 env_config로 연결:

```ocaml
(* Before *)
let default_zombie_threshold = 300.0

(* After *)
let default_zombie_threshold =
  Env_config.Zombie.agent_threshold_sec  (* default 300.0 *)
```

| File | Change |
|------|--------|
| `lib/room/resilience.ml:5,60` | 하드코딩 → `Env_config.Zombie.*` 참조 |
| `lib/config/env_config_runtime.ml` | `MASC_ZOMBIE_AGENT_THRESHOLD_SEC`, `MASC_ZOMBIE_KEEPER_THRESHOLD_SEC` 추가 |

### Phase 1: Work-as-Heartbeat (2-3주, LOW risk)

**Objective**: Keeper loop에 Heartbeat_smart 패턴 적용. Turn 완료를 liveness 증거로 인정.

**Mechanical Definition (기계적 정의)**:

| 속성 | 값 |
|------|-----|
| Lease owner | Keepalive fiber (유일한 writer) |
| Renew point (a) | `ensure_keeper_room_presence` 시작 (기존) |
| Renew point (b) | `run_unified_turn` 완료 직후 (신규) |
| Max silence budget | `MASC_KEEPER_MAX_SILENCE_SEC` (default 120s) |
| Turn 중 갱신 | 불가 (fiber blocking). max silence = max turn duration |
| Supervisor 인식 | `last_turn_completion_ts` < MAX_SILENCE_SEC이면 alive 취급 |
| False zombie 방지 | Turn 중 presence failure는 consecutive count에서 제외 |

**Implementation**:

| Step | File | Change |
|------|------|--------|
| 1.1 | `lib/keeper/keeper_registry.ml` | `last_turn_completion_ts : float` 필드 추가 |
| 1.2 | `lib/keeper/keeper_unified_turn.ml` | Turn 완료 후: (a) `last_turn_completion_ts` 갱신, (b) `Room_gc.heartbeat_in_room` 호출 |
| 1.3 | `lib/keeper/keeper_keepalive.ml:126` | `now - last_turn_completion_ts < keepalive_interval_sec`이면 presence sync skip |
| 1.4 | `lib/keeper/keeper_keepalive.ml:147` | Self-stop 기준: turn 중이면 consecutive failure 카운트 제외 |
| 1.5 | `lib/keeper/keeper_supervisor.ml:123` | `last_turn_completion_ts` < MAX_SILENCE_SEC이면 alive 취급 (Promise 판정 보완) |
| 1.6 | `lib/config/env_config_keeper.ml` | `MASC_KEEPER_WORK_AS_HEARTBEAT` (bool, default true), `MASC_KEEPER_MAX_SILENCE_SEC` (int, default 120) |
| 1.7 | `test/test_work_as_heartbeat.ml` | Turn 완료가 presence sync를 대체하는지 + turn 중 false zombie 방지 검증 |

**Feature flag**: `MASC_KEEPER_WORK_AS_HEARTBEAT=false`로 기존 동작 즉시 복원 가능.

### Phase 2: Restart Resilience — Self-Preservation (3-4주, MEDIUM risk)

**Objective**: Path A (supervisor restart)에 mass failure 감지 + 억제 추가.

**Self-Preservation Rule**:

```
sweep_and_recover에서:
  restart_candidates = len(to_restart)
  total_running = len(entries)
  ratio = restart_candidates / total_running

  if ratio > SELF_PRESERVATION_RATIO (default 0.3):
    log "self-preservation: %.0f%% keepers need restart, likely infra issue"
    publish OAS event "keeper_self_preservation_triggered"
    skip all restarts this cycle
    next cycle: re-evaluate (suppression은 1 cycle만)
```

| Step | File | Change |
|------|------|--------|
| 2.1 | `lib/keeper/keeper_supervisor.ml:140` | restart 실행 전 비율 검사 추가 |
| 2.2 | `lib/keeper/keeper_supervisor.ml` | self-preservation event 발행 |
| 2.3 | `lib/config/env_config_keeper.ml` | `MASC_KEEPER_SELF_PRESERVATION_RATIO` (float, default 0.3) |
| 2.4 | `test/test_self_preservation.ml` | 30%+ 동시 crash 시 restart 억제 검증 |

### Phase 2b: Phi Accrual — gRPC Only (선행조건: gRPC 활성화)

**Scope 제한**: Phi accrual은 gRPC heartbeat stream(keeper_keepalive.ml:458-552)에서만 적용한다.

| Detection Need | Method | Change |
|---------------|--------|--------|
| In-process fiber death | Promise.peek (기존) | 변경 없음 |
| Room file staleness | Fixed threshold (Phase 0에서 configurable) | 변경 없음 |
| Network heartbeat loss | **Phi Accrual (신규)** | gRPC ack 도착 간격 기반 |

**Shadow Mode 요구사항**:
- 2주간 phi 값 로그만 기록, 판정은 기존 방식 유지
- Confusion matrix: TP/FP/TN/FN 집계
- 수용 기준: FP < 1%, FN < 5%
- Kill switch: `MASC_PHI_ACCRUAL_ENABLED=false`
- False-positive audit: phi >= threshold인데 keeper가 실제 alive인 건수 추적

| Step | File | Change |
|------|------|--------|
| 2b.1 | **NEW** `lib/keeper/phi_accrual.ml` | Sliding window + normal CDF phi 계산 |
| 2b.2 | `lib/keeper/keeper_keepalive.ml:493` | gRPC ack 수신 시 `Phi_accrual.record` 호출 |
| 2b.3 | Shadow mode 로깅 | phi 값 + 실제 상태 병기 |
| 2b.4 | `test/test_phi_accrual.ml` | 순수 단위 테스트 |

### Phase 3: Cascade Scheduler (별도 RFC)

이 RFC에서는 방향만 기술한다. 상세 설계는 Phase 0-2 baseline 2주 이상 확보 후 별도 RFC로 작성한다.

**Direction**:

1. **Priority queue**: Reactive(user message, @mention) > Proactive(idle warmup) > Background(improve loop)
   - 근거: Agent.xpu (arXiv:2506.24045) — priority preemption으로 91%+ reactive latency 감소
2. **Task DAG analysis**: 같은 room의 keeper 간 dependency 분석 (Independent / Sequential / Pipeline)
   - 근거: arXiv:2504.07347 — interconnected agent network에서는 work-conserving만으로 불충분
3. **Collaboration mode routing**: MasRouter (arXiv:2502.11133) 패턴 — model 선택과 collaboration mode를 동시 결정
4. **Cache-aware scheduling**: Helium (arXiv:2603.16104) 패턴 — same-room keeper 간 context prefix 공유

Phase 3 착수 조건:
- Phase 0 측정 데이터에서 cascade 레벨 비효율이 확인됨
- Phase 1+2 배포 후 2주 이상 baseline 확보
- Cascade scheduler 별도 RFC 작성 + 리뷰

## 5. Boundary Health

| Phase | Risk | Boundary Crossing | Mitigation |
|-------|------|-------------------|-----------|
| Phase 0 | LOW | None (config + instrumentation) | 기존 동작 변경 없음 |
| Phase 1 | LOW | keeper_keepalive ↔ keeper_registry (new field) | Feature flag로 즉시 복원 |
| Phase 2 | MEDIUM | keeper_supervisor 내부 수정 | 1 cycle 억제만 (30s), 다음 cycle에서 재평가 |
| Phase 2b | MEDIUM | gRPC heartbeat ↔ phi detector (new module) | Shadow mode + kill switch |
| Phase 3 | HIGH | cascade ↔ keeper (new scheduler layer) | 별도 RFC로 분리 |

**가장 큰 위험**: Phase 1에서 `last_turn_completion_ts` 기반 presence skip이 downstream consumer(dashboard, SSE, 다른 agent)가 기대하는 `last_seen` 갱신을 누락시킬 수 있음. Step 1.2에서 turn 완료 시 `heartbeat_in_room`을 명시적으로 호출하여 방지.

## 6. Implementation Checklist

- [ ] Phase 0.1: Per-stage timer 계측 (keeper_keepalive.ml)
- [ ] Phase 0.2: Config SSOT (resilience.ml 하드코딩 → env_config)
- [ ] Phase 0: 1주 측정 + 결과 기록
- [ ] Phase 1.1: `last_turn_completion_ts` registry field
- [ ] Phase 1.2: Unified turn 완료 시 timestamp 갱신 + room heartbeat
- [ ] Phase 1.3: Presence sync conditional skip
- [ ] Phase 1.4: Self-stop에서 turn-in-progress 예외
- [ ] Phase 1.5: Supervisor에서 `last_turn_completion_ts` alive 인정
- [ ] Phase 1.6: Config (feature flag + max silence)
- [ ] Phase 1.7: Tests
- [ ] Phase 2.1-2.4: Self-preservation in supervisor
- [ ] Phase 2b (gRPC 활성화 후): Phi accrual + shadow mode

## 7. Labeling Protocol

| Label | Value |
|-------|-------|
| `area:` | `keeper` |
| `target:` | `next` |
| `type:` | `enhancement` |
| `promise:` | `ops visibility` |

Phase별 이슈 분리 시:
- Phase 0: `[Heartbeat] Per-stage profiling + config SSOT`
- Phase 1: `[Heartbeat] Work-as-heartbeat for keeper keepalive`
- Phase 2: `[Heartbeat] Self-preservation in supervisor restart`
- Phase 2b: `[Heartbeat] Phi accrual for gRPC heartbeat`
- Phase 3: 별도 RFC + 별도 issue

## Research References

### Academic Papers

| Paper | Key Insight | Phase |
|-------|-------------|-------|
| arXiv:2504.07347 (Li, Dai, Peng) | Work-conserving scheduling은 독립 agent에 충분하지만, interconnected agent network에서는 DAG-aware 필요 | P3 |
| arXiv:2506.24045 (Agent.xpu) | Priority preemption + slack piggybacking. Reactive > Proactive. 91%+ latency 감소 | P3 |
| arXiv:2507.06520 (Gradientsys) | Centralized scheduler + hybrid sync/async + capacity-aware dispatch | P3 |
| arXiv:2502.11133 (MasRouter, ACL 2025) | Collaboration mode + role + model routing. 52% overhead 감소 | P3 |
| arXiv:2603.16104 (Helium, 2026-03) | Cache-aware agentic scheduling. 1.56x speedup via KV cache reuse | P3 |
| arXiv:2603.13605 (Orla, Harvard) | Request execution과 workflow policy 분리 | P3 |
| PLDI 2021 (Retrofitting Effect Handlers) | Eio fiber overhead ~1%. Fibers 1.67-4.29x faster than Lwt | All |

### Industry / Production Systems

| System | Pattern | Relevance |
|--------|---------|-----------|
| K8s KEP-589 | Lease(10s) + Status(5min) 분리. 80% write 감소 at 5k nodes | P1 lease/sync 분리 참조 |
| Cassandra/Akka | Phi Accrual Failure Detector. phi=8 → 99.9999% confidence | P2b |
| Netflix Eureka | Self-preservation: >15% simultaneous miss → suppress eviction | P2 |
| Uber Ringpop (SWIM) | O(1) per-node message cost, O(log N) propagation | Scale 참조 |
| OpenClaw | Per-agent heartbeat + orchestration batching + Lobster workflow | P1 패턴 참조 |
| Tokio cooperative yield | 128 ops budget/tick. 3x tail latency improvement | Eio fiber 스케줄링 참조 |

### Key Numbers

| Metric | Value | Source |
|--------|-------|--------|
| Eio fiber per keeper | ~2-4KB | PLDI 2021 |
| 50 keepers total fiber memory | ~200KB (vs 5GB LLM context) | Benchmark |
| K8s lease vs status write reduction | 80% | KEP-589, 5k nodes |
| Phi=8 false positive rate | 0.0001% | Cassandra default |
| Agent.xpu reactive latency reduction | 91%+ | arXiv:2506.24045 |
| MasRouter overhead reduction | 52% on HumanEval | ACL 2025 |
