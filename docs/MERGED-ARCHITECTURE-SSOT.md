# Merged Architecture SSOT

> **SUPERSEDED-BY**: `docs/spec/SPEC-INDEX.md` + `docs/spec/01-system-overview.md` (v2.138.0, 2026-03-23)

이 문서는 현재 `main`에 실제로 merged된 `masc-mcp` 구조를 한 번에 보는
아키텍처 SSOT다.

목표:

- 지금 무엇이 canonical path인지 고정
- 무엇이 substrate이고 무엇이 policy인지 분리
- 무엇이 merged되었지만 아직 실험 성격인지 명시

## One Sentence

현재 `masc-mcp`의 canonical spine은 `CPv2 command plane + native chain plane + optional search fabric + optional local64 runtime pool`이다.

## Canonical Paths

### 1. CPv2 direct

가장 중요한 기본 경로다.

- 대상: benchmark, swarm orchestration, managed operations
- 핵심 도구: `masc_unit_define`, `masc_operation_start`, `masc_dispatch_tick`,
  `masc_detachment_*`, `masc_observe_*`, `masc_policy_*`
- SSOT 문서: [COMMAND-PLANE-RUNBOOK.md](./COMMAND-PLANE-RUNBOOK.md)

### 2. Supervised Execution + Supervisor

기능 구현을 swarm으로 굴릴 때의 기본 경로다.

- 대상: planner / implementer / supervisor workflow
- 핵심 도구: command-plane execution surfaces, `masc_operator_*`
- operator-facing digest는 command-plane/search/microarch 신호를 번역해 노출하는 canonical intervention surface다.
- SSOT 문서:
  - [SWARM-DELIVERY-RUNBOOK.md](./SWARM-DELIVERY-RUNBOOK.md)
  - [SUPERVISOR-MODE.md](./SUPERVISOR-MODE.md)

### 3. Native chain plane

`command-plane` 안으로 흡수된 orchestration substrate다.

- 대상: chain-backed operation, goal-to-chain execution, chain summary/run surfaces
- 핵심 코드: `lib/chain_*`, `lib/tool_command_plane.ml`, `lib/command_plane_v2.ml`
- 핵심 표면:
  - operation launch 시 `orchestration_kind="chain_dsl"`
  - `masc_chain_snapshot`
  - `masc_chain_run_get`

## Layer Map

### Layer 1. Runtime substrate

- `local64` / `llama runtime pool`
- 역할: local llama shard discovery, assignment, capacity, cooldown, bench/status
- 대표 코드:
  - `lib/local_runtime_pool.ml`
  - `lib/tool_llama.ml`
  - `lib/team_session_engine_eio.ml`
- 이 레이어는 command-plane보다 아래다.

### Layer 2. Control substrate

- `CPv2 command plane`
- 역할: units, operations, detachments, policy decisions, traces, summary/snapshot
- 대표 코드:
  - `lib/command_plane_v2.ml`
  - `lib/tool_command_plane.ml`

### Layer 3. Orchestration substrate

- `native chain plane`
- 역할: multi-step chain execution, chain summary, run detail, preview/run overlay
- 대표 코드:
  - `lib/chain_*`
  - `lib/tool_command_plane.ml`

### Layer 4. Scheduling / policy

- `Search Fabric V1`
- 역할: dependency-aware best-first routing for `coding_task`, explicit `research_pipeline`
- 기본값: `best_first_v1`
- `legacy`는 explicit opt-out
- SSOT 문서: [SEARCH-FABRIC-V1.md](./SEARCH-FABRIC-V1.md)

### Layer 5. Implementation swarm

- `Supervised execution + Supervisor`
- 역할: 기능 슬라이스 구현, report/proof, operator intervention
- runtime substrate와 command-plane 위에서 동작한다.

## What Is Merged But Not Canonical

### SWARM-RISC

`SWARM-RISC` 관련 모듈은 main에 merged되어 있지만, 현재 canonical public usage surface는 아니다.

- 대표 코드:
  - `lib/risc_types.ml`
  - `lib/risc_pipeline.ml`
  - `lib/tool_risc.ml`
  - `lib/reservation_station.ml`
  - `lib/work_stealing.ml`
- 현재 해석:
  - 연구/설계 참고 모듈
  - reservation station, OoO, work-stealing 같은 개념의 실험실
  - `CPv2`를 대체하는 기본 경로로 보지 않는다.

즉 지금의 canonical story는 `RISC tool surface를 직접 쓰는 것`이 아니라,
그 안의 개념을 `CPv2`나 `search fabric`으로 번역해 가는 것이다.

## Public vs Experimental

| 영역 | 현재 상태 | 비고 |
|------|-----------|------|
| `CPv2 direct` | Canonical | 기본 swarm / benchmark 경로 |
| `Supervised execution + Supervisor` | Canonical | 기능 구현 경로 |
| `native chain plane` | Canonical substrate | command-plane 안으로 흡수됨 |
| `local64 runtime pool` | Canonical substrate | local llama path |
| `Search Fabric V1` | Mainline policy | 기본 `coding_task`, explicit `research_pipeline` |
| `SWARM-RISC` | Experimental / research | 개념 참고용 |
| removed `masc_swarm_*` public flow | Retired | CPv2로 수렴 |

## Current Direction

지금 이후의 기본 방향은 다음 순서다.

1. runtime substrate를 안정화한다.
   - local64 / pool / capacity / cooldown / observability
2. command-plane substrate를 확장한다.
   - chain-backed operation, summary-first read model, traces
3. scheduling policy를 실험한다.
   - `best_first_v1` 같은 opt-in routing
4. 연구 개념을 흡수한다.
   - `SWARM-RISC`의 reservation station / work-stealing 같은 개념을 필요한 범위만 번역

즉, 앞으로의 mainline 진화는 `CPv2 중심`이며, `RISC-first`가 아니다.

## Related Docs

- [README.md](../README.md)
- [QUICKSTART.md](./QUICKSTART.md)
- [COMMAND-PLANE-RUNBOOK.md](./COMMAND-PLANE-RUNBOOK.md)
- [SWARM-DELIVERY-RUNBOOK.md](./SWARM-DELIVERY-RUNBOOK.md)
- [SUPERVISOR-MODE.md](./SUPERVISOR-MODE.md)
- [SEARCH-FABRIC-V1.md](./SEARCH-FABRIC-V1.md)
