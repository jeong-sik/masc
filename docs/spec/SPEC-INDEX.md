---
status: reference
last_verified: 2026-05-17
code_refs:
  - docs/spec/
  - dune-project
---

# MASC Specification Index

> Supersedes: `docs/SPEC.md`, `docs/MERGED-ARCHITECTURE-SSOT.md`
> Status: Living draft
> Last Updated: 2026-07-03
> Snapshot baseline: `dune-project` version `0.20.0`

MASC (Multi-Agent Shared Context)는 OCaml 5.x / Eio 기반 MCP 서버로, 여러 Keeper/MCP client가 동일 workspace에서 작업할 때 필요한 조율과 관찰성을 제공한다. Workspace 기반 세션 관리, Task 할당, Heartbeat 모니터링, Keeper turn, dashboard/operator read visibility를 제공하며, MCP JSON-RPC 프로토콜을 통해 주요 AI IDE/CLI와 통합된다. Retired orchestration surfaces and internal references remain only as migration context.

## Snapshot Metadata

The version line above is current as of the last doc touch. The size/count rows
below are an older inventory snapshot and should be recalculated before being
used as evidence.

| 항목 | 값 |
|------|-----|
| Release baseline | 0.19.54 |
| Language | OCaml 5.x (Eio-native, effect-based concurrency) |
| LOC (lib, `.ml` + `.mli`) | ~248K |
| LOC (test, `.ml` + `.mli`) | ~155K |
| OCaml modules under `lib/` (`.ml`) | 713 |
| `.mli` interfaces under `lib/` | 401 |
| MCP tool modules (`tool_*.ml`) | 109 |
| Test files (`test/*.ml`) | 449 |
| Executables | 9 public (`masc`, `masc-stdio`, `masc-cost`, `masc-compaction-audit`, `masc-keeper-feature-proof`, `masc-trace`, `masc-tui`, `cdal-label`, `masc-worker-run`) + 6 internal (`public_tool_manifest`, `env_knob_catalog`, `trace_to_tla`, `poc_shell_ir_gen`, `gen_shell_ir_walkers`, `gen_tool_descriptors`) |

숫자는 2026-04-23 repo snapshot 기준. `rg --files lib/ test/ bin/` 및 `wc -l`로 재계산. 최신 truth는 다시 계산해야 한다.

## Layer Diagram

```mermaid
graph TB
    L6["Layer 6: Integration<br/>OAS bridge, research loop"]
    L5["Layer 5: Surface<br/>dashboard, operator, TUI, web"]
    L4["Layer 4: Protocol<br/>MCP server, HTTP transport, gRPC, SSE"]
    L3["Layer 3: Engine<br/>chain, keeper, swarm"]
    L2["Layer 2: Domain<br/>workspace, board"]
    L1["Layer 1: Storage<br/>backend, dated_jsonl, memory"]
    L0["Layer 0: Primitives<br/>types, core, log, time_compat, fs_compat"]

    L6 --> L5
    L5 --> L4
    L4 --> L3
    L3 --> L2
    L2 --> L1
    L1 --> L0
```

## Specification Files

| File | Title | Description | Status |
|------|-------|-------------|--------|
| `00-glossary.md` | Glossary | 용어 정의, 약어 목록 | Draft |
| `01-system-overview.md` | System Overview | 문제 정의, 배포 모델, 기술 스택, sub-library 의존성 | Draft |
| `02-types-and-invariants.md` | Types and Invariants | 핵심 타입 정의, 상태 전이, 불변식 | Draft |
| `03-workspace-state collaboration.md` | Workspace State | Workspace 생명주기, session 관리, agent join/leave | Draft |
| `04-turn-lifecycle.md` | Turn Lifecycle | Keeper turn 시작/종료, heartbeat/polling/waiting, direct msg, FSM, receipt | Draft |
| `05-keeper-agent.md` | Keeper Engine | 자율 에이전트 루프, succession, context 관리 | Draft |
| `06-command-plane.md` | Command Plane v2 | Internal command-plane reference and migration context | Historical |
| `09-server-transport.md` | Server and Transport | HTTP transport, SSE, JSON-RPC dispatch, routing | Draft |
| `10-dashboard.md` | Dashboard | Web UI, API endpoints, SSE real-time updates | Draft |
| `11-board.md` | Board System | Posts, comments, votes, filesystem/JSONL backend | Draft |
| `12-memory-systems.md` | Memory Systems | Masc.Memory.t, memory bank, institution, procedural, context budget | Draft |
| `13-oas-integration.md` | OAS Integration | OAS Agent SDK bridge, runtime config, verifier, event bus, boundary rules | Draft |
| `14-configuration.md` | Configuration | env, profile, prompt, runtime 설정 | Draft |
| `15-testing.md` | Testing | 검증 계층, contract suites, fixture/manual 분리 | Draft |
| `16-root-cause-rubric.md` | Root-Cause Rubric | 7-category taxonomy (SSOT/TEL/BND/SIL/VAR/STR/DET) for issue triage and Keeper benchmark | Reference |
| `17-keeper-behavioral-regime.md` | Keeper Behavioral Regime | 7th FSM axis rules, `tool_aggregate` semantics, snapshot invariants | Reference |
| `18-log-severity-taxonomy.md` | Log Severity Taxonomy | 4-level contract for `Log.{debug,info,warn,error}` callsites + anti-pattern catalog + lint rules | Reference |
| `A-existing-doc-index.md` | Existing Doc Index | 현재 문서 inventory와 cleanup ledger | Draft |
| `B-migration-targets.md` | Migration Targets | OAS 이관 대상 모듈, deprecation 일정 | Draft |
| `C-implementation-status.md` | Implementation Status | 구현 상태와 coverage snapshot | Draft |

## Active Design Documents

`06-command-plane.md`는 retained code/inventory를 설명하는 internal reference다. Supported front-door contract나 새 caller onboarding SSOT로 읽지 않는다.

이 spec suite 외에 `docs/design/`와 `docs/rfc/`에 위치한 활성 설계 문서들:

| Document | Description | Related Spec |
|----------|-------------|--------------|
| `docs/ADR-002-DASHBOARD-OPERATOR-CONTROL-SURFACE.md` | Dashboard operator control surface and review queue UX | `10-dashboard.md` |
| `docs/design/checkpoint-truth-and-replay-rfc.md` | Checkpoint truth hierarchy, replay semantics, side-effect boundary | `13-oas-integration.md` |
| `docs/KEEPER-STATE-OWNERSHIP.md` | Keeper lane, checkpoint, domain state, and receipt ownership | `05-keeper-agent.md`, `13-oas-integration.md` |
| `docs/design/check-evaluation-spec.md` | Deterministic check evaluation for contract verification | `15-testing.md` |
| `docs/design/contract-driven-agent-loop-rfc.md` | Contract-driven agent loop (CDAL) framework | `05-keeper-agent.md` |

## Conventions

### Document Structure

각 spec 파일은 아래 섹션을 따른다:
1. Problem Statement
2. Non-Goals
3. Module Inventory (table)
4. Key Types (OCaml signatures)
5. State Machines (Mermaid)
6. Invariants (INV-{SUBSYSTEM}-NNN)
7. Failure Modes
8. Dependencies (upstream/downstream)
9. Open Questions

### Invariant Naming

`INV-{SUBSYSTEM}-{NNN}` 형식을 사용한다.

| Prefix | Subsystem |
|--------|-----------|
| `INV-WORKSPACE` | Workspace lifecycle |
| `INV-TASK` | Task state machine |
| `INV-KPR` | Keeper engine |
| `INV-CHAIN` | Chain execution |
| `INV-CP` | Command Plane |
| `INV-SRV` | Server/transport |
| `INV-DASH` | Dashboard |
| `INV-BRD` | Board |
| `INV-CSC` | Runtime |
| `INV-MEM` | Memory |
| `INV-OAS` | OAS Integration |

### Cross-Reference Format

- Spec 간: `./NN-filename.md#section-anchor`
- 코드: `lib/<module_name>.ml:L123`
- Invariant: `INV-WORKSPACE-001`
- 외부 문서: `docs/<document-name>.md`

### Supersession

이 spec suite가 최종 진실 원본(SSOT)이다.

| 이전 문서 | 상태 |
|----------|------|
| `docs/SPEC.md` | Historical snapshot. 이 suite로 대체. |
| `docs/MERGED-ARCHITECTURE-SSOT.md` | Layer map과 canonical paths는 `01-system-overview.md`로 이관. |
| `docs/GLOSSARY.md` | `00-glossary.md`로 통합. |
| `docs/keeper-turn-lifecycle.md` | `04-turn-lifecycle.md`로 이관. 기존 문서는 historical diagram/tooling notes로 유지. |
