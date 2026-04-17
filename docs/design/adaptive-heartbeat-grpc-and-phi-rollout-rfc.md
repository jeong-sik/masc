---
status: reference
last_verified: 2026-04-17
code_refs:
  - lib/keeper/heartbeat_smart.ml
  - lib/keeper/keeper_state_machine.ml
  - lib/keeper/keeper_config.ml
---

# Adaptive Heartbeat gRPC and Phi Rollout RFC

**Status**: Draft, follow-up production gate
**Date**: 2026-03-29
**Scope**: Keeper gRPC heartbeat enablement, phi-accrual shadow mode, transport-health/operator prerequisites
**One sentence**: Canonical HTTP/file adaptive heartbeat가 안정화된 뒤 gRPC heartbeat와 phi-accrual을 어떤 순서와 제약으로 production scope에 넣을지 잠근다.

## Related Documents

- `./adaptive-heartbeat-scheduling-rfc.md`
- `./adaptive-heartbeat-production-rollout-rfc.md`
- `./adaptive-heartbeat-observability-slo-spec.md`
- `./adaptive-heartbeat-validation-and-alert-wiring-spec.md`
- `./adaptive-heartbeat-phi-enforcement-rfc.md`
- `./adaptive-heartbeat-safety-harness-spec.md`
- `../ADAPTIVE-HEARTBEAT-PRODUCTION-RUNBOOK.md`
- `../TRANSPORT-PRACTICAL-PLAYBOOK.md`
- `../spec/09-server-transport.md`

## 1. Goal

이 문서는 canonical HTTP/file keeper path rollout 이후의 follow-up RFC다.

목표는 세 가지다:

- gRPC heartbeat를 기존 adaptive heartbeat safety model과 충돌 없이 production에 올리는 조건을 정의한다.
- phi-accrual을 바로 enforcement 하지 않고 shadow mode, advisory mode, enforcement candidate를 분리한다.
- local room heartbeat와 gRPC heartbeat의 ownership boundary를 문서로 고정한다.

## 2. Current State

현재 코드와 문서 기준 상태:

- gRPC transport는 서버에 이미 존재한다. `MASC_GRPC_ENABLED` 와 `MASC_AGENT_TRANSPORT=grpc` 로 path 선택이 가능하다.
- keeper는 optional gRPC heartbeat fiber를 띄울 수 있다. 이 fiber는 bidirectional `Heartbeat` stream으로 ping/ack를 주고받고, server directive를 처리한다.
- `transport-health` 는 `grpc.active_streams`, `grpc.subscribers`, `grpc.heartbeat_avg_seconds` 를 이미 노출한다.
- canonical production bundle은 gRPC heartbeat와 phi-accrual을 명시적으로 scope 밖으로 둔다.

즉, transport는 존재하지만 production contract는 아직 잠겨 있지 않다.

## 3. Production Boundary

### 3.1 Invariants

다음은 gRPC/Phi follow-up에서도 깨지면 안 되는 invariant다.

- room-level freshness lease의 SSOT는 여전히 successful `Room.heartbeat_in_room` 이다.
- gRPC ack 성공은 `last_successful_heartbeat_ts` 를 갱신하지 않는다.
- gRPC ack 성공은 room presence `consecutive_failures` 를 reset하지 않는다.
- `Crashed`, `Dead`, restart budget, self-preservation ownership은 supervisor/local keepalive path가 가진다.
- gRPC heartbeat loss만으로 keeper를 `Crashed` 나 `Dead` 로 전이하지 않는다. 첫 production rollout에서는 advisory only 다.

### 3.2 Non-Goals

- local room heartbeat를 gRPC heartbeat로 대체하지 않는다.
- phi-accrual을 첫 rollout부터 restart gate로 쓰지 않는다.
- gRPC ack latency를 room/filesystem health proxy로 쓰지 않는다.
- cascade scheduler rollout을 이 문서에서 다루지 않는다.

## 4. Why Canonical Path Must Land First

gRPC heartbeat는 transport-layer signal이고, canonical adaptive heartbeat가 다루는 주 문제는 room/filesystem presence ownership이다.

이 순서를 뒤집으면 다음 혼합이 생긴다.

- room I/O 장애가 gRPC ack success로 가려질 수 있다
- network jitter가 local keeper restart pressure로 잘못 번역될 수 있다
- phi false positive가 supervisor recovery와 섞여 root cause가 흐려진다

따라서 선행 조건은 명확하다:

- canonical HTTP/file adaptive heartbeat Stage 0-3 완료
- safety counters zero 유지
- rollback rehearsal 완료

이 조건 전에는 gRPC/Phi production rollout을 시작하지 않는다.

## 5. Rollout Ladder

### G0: Baseline With gRPC Disabled

목적: canonical path baseline과 분리.

Rules:

- `MASC_GRPC_ENABLED=0`
- canonical adaptive heartbeat rollout bundle artifact 재사용
- gRPC/Phi 관련 keeper field는 비어 있거나 미노출이어도 무방

### G1: gRPC Transport Canary, No Phi

목적: gRPC heartbeat fiber와 transport-health visibility를 확인한다.

Rules:

- 서버는 `MASC_GRPC_ENABLED=1`
- 대상 keeper cohort만 `MASC_AGENT_TRANSPORT=grpc`
- room heartbeat는 계속 켜 둔다
- gRPC heartbeat loss는 operator warning만 만들고 recovery ownership에는 관여하지 않는다

Required evidence:

- `transport-health.grpc.listening=true`
- `transport-health.grpc.active_streams > 0`
- `transport-health.grpc.heartbeat_avg_seconds` 가 안정적으로 갱신
- keeper surface에 `grpc_connected` 와 `last_grpc_ack_age_sec` 가 보임

Stop conditions:

- gRPC transport enable 이후 canonical safety counter가 증가
- gRPC fiber failure가 keeper restart ownership을 교란
- transport-health는 healthy인데 keeper surface가 stale

### G2: gRPC Heartbeat Production Candidate, Advisory Only

목적: gRPC heartbeat를 production operator surface에 포함한다.

Rules:

- G1 조건 유지
- operator surface에 아래 필드를 추가한다:
  - `grpc_connected`
  - `last_grpc_ack_age_sec`
  - `grpc_reconnect_attempts`
  - `grpc_directive_count_recent`
- gRPC failure는 `failure_reason` primary source가 아니다. 필요하면 `transport_diagnostic` 로만 노출한다.

Promotion gate:

- canonical path safety counters zero 유지
- gRPC path added after enabling does not breach `PERFORMANCE-SLO.md`
- repeated gRPC disconnects do not change local `Crashed/Dead` ownership semantics

### G3: Phi Shadow Mode

목적: phi-accrual을 network loss detector로만 관찰한다.

Rules:

- `MASC_KEEPER_PHI_ENABLED=1`
- `MASC_KEEPER_PHI_MODE=shadow`
- phi 값은 gRPC ack inter-arrival 기반으로만 계산
- phi 값은 logs/operator surface에 기록하지만 sweep/restart/self-preservation은 기존 방식 유지

Required runtime fields:

- `phi_value`
- `phi_threshold`
- `phi_shadow_decision`
- `last_grpc_ack_age_sec`
- `grpc_connected`

Required observation window:

- 최소 14일
- representative keeper cohort
- induced disconnect test 포함

Required analysis:

- false positive count
- false negative count
- precision / recall or equivalent confusion matrix
- dominant false positive scenarios summary

Stop conditions:

- phi shadow values are unavailable for a running gRPC keeper
- operator cannot explain why a high phi value occurred
- gRPC ack gaps correlate with normal load but phi threshold still bursts

### G4: Phi Advisory Mode

목적: phi를 operator warning으로만 사용한다.

Rules:

- `MASC_KEEPER_PHI_MODE=advisory`
- phi threshold crossing은 alert or dashboard badge만 낸다
- keeper state machine, restart budget, self-preservation logic는 unchanged

Promotion gate:

- G3 14-day shadow window complete
- no unresolved false-positive class remains
- advisory alerts are actionable and not noisy

### G5: Phi Enforcement Candidate

이 단계는 **이 RFC의 승인 범위를 넘는다**.

phi가 restart, suppression, or keeper state transition에 관여하려면 별도 enforcement RFC가 필요하다. 현재 follow-up 문서는 [adaptive-heartbeat-phi-enforcement-rfc.md](/Users/dancer/me/workspace/yousleepwhen/masc-mcp/.worktrees/feature/adaptive-heartbeat-scheduling-rfc/docs/design/adaptive-heartbeat-phi-enforcement-rfc.md) 를 canonical source로 본다. 그 RFC 없이는 production에서 advisory-only를 넘지 않는다.

## 6. Runtime Contract

### 6.1 Flags

| Flag | Default for G0-G2 | Meaning |
|---|---|---|
| `MASC_GRPC_ENABLED` | `0` in canonical baseline, `1` in G1+ | server gRPC transport enable |
| `MASC_AGENT_TRANSPORT` | `local` or default | keeper/client transport selection |
| `MASC_KEEPER_PHI_ENABLED` | `0` until G3 | enable phi module |
| `MASC_KEEPER_PHI_MODE` | `off` | `off`, `shadow`, `advisory` |
| `MASC_KEEPER_PHI_THRESHOLD` | implementation-defined | shadow/advisory threshold |

### 6.2 Field Contract

gRPC/Phi rollout에서는 아래 field를 operator-visible surface에 추가해야 한다.

| Field | Meaning | First required stage |
|---|---|---|
| `grpc_connected` | gRPC heartbeat stream health | G1 |
| `last_grpc_ack_age_sec` | age of last ack | G1 |
| `grpc_reconnect_attempts` | reconnect pressure | G2 |
| `grpc_directive_count_recent` | directive activity visibility | G2 |
| `phi_value` | current accrual score | G3 |
| `phi_threshold` | configured threshold | G3 |
| `phi_shadow_decision` | shadow/advisory classification | G3 |

## 7. Validation Requirements

Before any gRPC/Phi promotion:

- `transport-health` and keeper health surfaces must agree on whether gRPC is connected
- read-path revalidation must still pass with gRPC enabled
- continuity validation must still prove room presence continuity
- a disconnected gRPC stream must not refresh room freshness lease
- a disconnected gRPC stream must not reset local room heartbeat failure streak

Before phi advisory:

- shadow mode 14-day evidence exists
- false-positive audit exists
- manual disconnect and reconnect scenarios are reproducible in harness or scripted operator test

Before phi enforcement:

- [adaptive-heartbeat-safety-harness-spec.md](/Users/dancer/me/workspace/yousleepwhen/masc-mcp/.worktrees/feature/adaptive-heartbeat-scheduling-rfc/docs/design/adaptive-heartbeat-safety-harness-spec.md) 의 `phi_enforced` scenario가 pass 해야 한다

## 8. Alerts and Ownership

Alert policy:

- `warn`: repeated gRPC reconnect loop without room heartbeat failure
- `warn`: phi threshold crossing in advisory mode
- `critical`: gRPC/Phi path changes canonical safety counters or hides local room failures

Ownership split:

- transport owner: gRPC stream health, latency, reconnects
- keeper runtime owner: room freshness lease, state machine, restart ownership
- rollout owner: stage G0-G4 promotion decision

## 9. Exit Criteria

This RFC is satisfied only when:

- canonical adaptive heartbeat production rollout is already complete
- gRPC heartbeat is visible in operator surfaces without becoming the room-health SSOT
- phi runs in shadow mode for 14 days with analyzable evidence
- advisory-only rollout completes without canonical safety counter regressions
- no document or implementation claims phi enforcement is production-ready without a separate RFC
