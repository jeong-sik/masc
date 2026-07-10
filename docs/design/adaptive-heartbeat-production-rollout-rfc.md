---
status: reference
last_verified: 2026-04-17
code_refs:
  - lib/keeper_registry/keeper_state_machine.ml
  - lib/keeper/keeper_config.ml
---

# Adaptive Heartbeat Production Rollout RFC

**Status**: Draft, production gate
**Date**: 2026-03-29
**Scope**: Canonical HTTP/file keeper path rollout, flag posture, recovery ownership, promotion and rollback
**One sentence**: Adaptive heartbeat를 canonical keeper path에 production 기본 경로로 올리기 위한 rollout 규칙, kill switch, promotion gate를 잠근다.

## Related Documents

- `./adaptive-heartbeat-scheduling-rfc.md`
- `./adaptive-heartbeat-observability-slo-spec.md`
- `./adaptive-heartbeat-validation-and-alert-wiring-spec.md`
- `./adaptive-heartbeat-grpc-and-phi-rollout-rfc.md`
- `./adaptive-heartbeat-phi-enforcement-rfc.md`
- `./adaptive-heartbeat-safety-harness-spec.md`
- `./error-handling-and-operations-spec.md`
- `../ADAPTIVE-HEARTBEAT-PRODUCTION-RUNBOOK.md`
- `../PERFORMANCE-SLO.md`
- `../MCP-READPATH-REVALIDATION-RUNBOOK.md`

## 1. Goal

이 문서는 implementation RFC가 아니라 production rollout policy다.

목표는 두 가지다:

- canonical HTTP/file keeper path에서 adaptive heartbeat를 **default-on** 으로 운영할 수 있도록 rollout 규칙을 잠근다.
- recovery ownership, rollback, dead-tombstone semantics를 운영자가 문서만 읽고 판단할 수 있게 만든다.

이 문서가 없으면 feature flag가 있어도 실제 운영에서 언제 promote / stop / rollback 해야 하는지 결정이 흔들린다.

## 2. Scope and Non-Goals

### In Scope

- HTTP/file keeper path
- keeper keepalive / supervisor / registry state rollout policy
- `work-as-heartbeat`, `self-preservation`, `Dead` tombstone의 production gate
- promotion / rollback / forward-fix rules

### Out of Scope

- gRPC heartbeat production rollout
- phi-accrual production enablement
- runtime scheduler rollout
- 코드 구현 상세 알고리즘 설명 자체

gRPC / phi-accrual은 `adaptive-heartbeat-grpc-and-phi-rollout-rfc.md` 에서 다룬다. 이 문서의 production sign-off는 canonical path에만 유효하다.

## 3. Runtime Contract

### 3.1 Required Flags and Defaults

초기 production posture는 `default-on with rollback` 이다. 단, emergency disable path는 반드시 있어야 한다.

| Flag | Default | Meaning | Rollback role |
|---|---|---|---|
| `MASC_KEEPER_ADAPTIVE_HEARTBEAT_ENABLED` | `true` | adaptive heartbeat master switch | emergency master disable |
| `MASC_KEEPER_WORK_AS_HEARTBEAT` | `true` | successful workspace heartbeat 기반 freshness skip | subsystem disable |
| `MASC_KEEPER_MAX_SILENCE_SEC` | `120` | freshness lease upper bound | tuning only |
| `MASC_KEEPER_SELF_PRESERVATION_ENABLED` | `true` | mass-failure suppression | subsystem disable |
| `MASC_KEEPER_SELF_PRESERVATION_RATIO` | `0.3` | suppression ratio threshold | tuning only |
| `MASC_KEEPER_SELF_PRESERVATION_MIN_CANDIDATES` | `2` | suppression absolute count threshold | tuning only |
| `MASC_KEEPER_DEAD_TTL_SEC` | `3600` | `Dead` tombstone retention window | cleanup tuning |

`MASC_KEEPER_ADAPTIVE_HEARTBEAT_ENABLED=false` 는 Phase 1/2 adaptive behavior를 끄는 emergency control이다. additive state model (`Crashed`, `Dead`)은 그대로 유지해도 무방하지만, adaptive skip / self-preservation / dead cleanup policy는 이 master flag 아래에 있어야 한다.

### 3.2 Keeper State Contract

Production operator surface는 아래 state를 canonical truth로 본다.

| State | Meaning | Restart owner | Reconcile target |
|---|---|---|---|
| `Running` | 정상 실행 중 | none | no |
| `Paused` | operator or workflow가 의도적으로 멈춤 | none | no |
| `Stopped` | 의도적 종료 또는 정상 종료 후 registry에서 정리 예정. Phase 2 이후 heartbeat failure self-stop은 여기에 오지 않는다 | none | yes, after unregister only |
| `Crashed` | 오류 종료, backoff/restart 대상. structured `heartbeat_consecutive_failures` self-stop 포함 | supervisor restart path | no |
| `Dead` | restart budget 소진, 재기동 금지 tombstone | none until TTL cleanup | no |

Migration note:

- Phase 2 implementation 이후 keepalive self-stop due to heartbeat failure는 `Stopped` 가 아니라 structured `Crashed` 로 노출되어야 한다.
- `Stopped` 는 manual stop, intentional stop, or clean terminal shutdown reserved state다.
- operator guide, dashboard, and harness assertions must treat `heartbeat_consecutive_failures` as a `Crashed` cohort.

### 3.3 Recovery Ownership Invariants

아래 규칙은 production invariant다.

- `reconcile_keepalive_keepers` 는 **registry entry가 없는 orphaned durable keeper만** 재기동한다.
- reconcile exclusion predicate는 `not is_running` 이 아니라 `not is_registered` 다.
- registered keeper의 recovery ownership은 state와 무관하게 supervisor가 가진다.
- `Crashed` keeper는 backoff / self-preservation gate를 반드시 통과해야 한다.
- `Dead` keeper는 TTL cleanup 전까지 절대 reconcile 대상이 아니다.
- `Dead` TTL cleanup은 `meta.paused=true` durable write 성공 후에만 unregister 한다. paused write가 실패하면 entry는 `Dead` tombstone으로 registry에 남아야 한다.

이 invariants 중 하나라도 깨지면 rollout을 stop 하고 rollback or forward-fix 판단으로 바로 전환한다.

## 4. Rollout Stages

### Stage 0: Baseline Lock

목적: adaptive heartbeat 이전 baseline 고정.

필수 조건:

- canonical path only: `MASC_GRPC_ENABLED=0`
- baseline server build / repo snapshot 고정
- `MASC_KEEPER_ADAPTIVE_HEARTBEAT_ENABLED=0`
- read-path, continuity, performance 결과를 artifact로 보관

Stage 0 산출물:

- read-path revalidation summary
- keeper checkpoint-validation receipt
- quick-bench 결과
- operator-visible keeper sample payload

Stage 0 artifact acceptance criteria:

- read-path harness 2회 연속 pass
- continuity harness 1회 이상 pass
- benchmark result is within current `PERFORMANCE-SLO.md`
- keeper sample payload contains the canonical state/ownership fields expected before the candidate rollout
- each artifact is timestamped and tied to the exact config posture used for baseline

### Stage 1: Candidate Canary

목적: adaptive heartbeat `default-on` 후보를 작은 범위에서 검증.

정책:

- one workspace or 1-3 durable keepers only
- adaptive flags는 production target defaults 그대로 사용
- gRPC remains disabled
- canary 동안 operator가 `Dead`, `Crashed`, `failure_reason`, `last_successful_heartbeat_age_sec` 를 직접 확인할 수 있어야 한다
- `failure_reason=heartbeat_consecutive_failures` 인 경우 `failure_streak_count` 가 같이 보여야 한다

Promotion gate:

- read-path revalidation 2회 연속 pass
- keeper continuity harness pass
- existing global PERFORMANCE-SLO 위반 없음
- zero unexpected `Dead` resurrection
- zero reconcile relaunch of registered keeper
- zero freshness skip after failed workspace heartbeat
- zero unplanned self-preservation trigger
- explicit proof that reconcile exclusion is keyed by `is_registered`

### Stage 2: Expanded Cohort Soak

목적: canonical path의 더 큰 비율에서 ownership / suppression semantics를 검증.

정책:

- representative durable keeper cohort
- rollout window 동안 config freeze
- operator-facing diagnostics field set freeze

Promotion gate:

- Stage 1 gate 유지
- dedicated safety harness defined in `adaptive-heartbeat-safety-harness-spec.md` passes for Stage 2 scenarios
- safety counter zero 유지
- baseline 대비 global API/SSE latency regression 25% 이하
- no alert burst that requires manual keeper surgery

### Stage 3: Full Production

목적: canonical HTTP/file keeper path 전체에 default-on.

허용 조건:

- Stage 2 gate 충족
- rollback rehearsal 완료
- runbook documented and reviewed
- `error-handling-and-operations-spec.md` 와 충돌 없음

## 5. Stop / Go Rules

| Condition | Action |
|---|---|
| read-path harness fail | stop promotion immediately |
| keeper continuity fail | stop promotion immediately |
| `Dead` resurrection observed | rollback immediately |
| registered `Crashed` or `Dead` keeper가 reconcile로 재기동 | rollback immediately |
| failed `Workspace.heartbeat_in_workspace` 이후 freshness skip 발생 | rollback immediately |
| unplanned self-preservation trigger | stop promotion and investigate |
| global MCP/REST/SSE SLO breach | stop promotion; rollback if linked to candidate |

`rollback immediately` 는 먼저 master switch로 adaptive behavior를 끄고, 그 뒤 forward-fix 가능 여부를 본다.

## 6. Rollback and Forward-Fix

### 6.1 Rollback Order

1. `MASC_KEEPER_ADAPTIVE_HEARTBEAT_ENABLED=false`
2. 필요하면 `MASC_KEEPER_WORK_AS_HEARTBEAT=false`
3. 필요하면 `MASC_KEEPER_SELF_PRESERVATION_ENABLED=false`
4. 그 다음에도 safety invariant가 깨지면 이전 release binary로 되돌린다

### 6.2 Forward-Fix Rule

다음 조건을 만족하면 forward-fix를 허용한다.

- recovery ownership invariant는 이미 유지된다
- `Dead` resurrection과 false freshness skip이 발생하지 않는다
- 문제는 observability, threshold, alert tuning 수준이다

아래 조건이면 forward-fix 금지, rollback 우선이다.

- registered crashed/dead keeper가 reconcile에 의해 다시 뜬다
- `Dead` tombstone이 operator 의도 없이 사라진다
- failed workspace heartbeat가 turn success로 가려진다

Decision rule:

- ownership invariant violation, false freshness skip, or dead resurrection이면 rollback first 다.
- field omission, alert routing bug, or threshold tuning 문제이지만 ownership invariant는 유지되는 경우에만 forward-fix 후보가 된다.
- operator가 5분 내에 violation class를 분류하지 못하면 rollback first 를 기본값으로 한다.

## 7. Exit Criteria

이 문서 기준으로 canonical path production sign-off는 아래가 모두 참일 때만 가능하다.

- rollout stage 0-3 artifact가 존재한다
- safety counters가 모두 zero다
- PERFORMANCE-SLO 절대 기준을 위반하지 않는다
- rollback rehearsal이 완료되었다
- runbook만으로 operator가 failure reason, keeper state, rollback path를 판단할 수 있다
- gRPC / phi-accrual은 명시적으로 production scope 밖으로 남아 있다

이 문서를 통과해도 gRPC heartbeat path는 production-ready가 아니다.
