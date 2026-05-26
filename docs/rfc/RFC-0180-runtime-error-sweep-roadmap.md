---
title: 24h Runtime ERROR 7-Pattern Sweep Roadmap
rfc: "0180"
status: Draft
created: 2026-05-26
updated: 2026-05-26
author: vincent
supersedes: []
superseded_by: null
related: ["0064", "0097", "0179"]
implementation_prs: ["18686"]
---

# RFC-0180 — 24h Runtime ERROR 7-Pattern Sweep Roadmap

Status: Draft · Roadmap, no PR-1 lib code yet
Related: RFC-0064 (LLM-native two-surface tool model), RFC-0097 (container reuse), RFC-0179 (ToolDescriptor ecosystem extension)

## 0. Problem framing

`<base-path>/.masc/logs/` 의 지난 24h (2026-05-25 ~ 2026-05-26) system log inventory:

| Level | 24h count | Notes |
|---|---|---|
| WARN | 79,833 | ~93% 가 keeper meta legacy unknown keys (work_discovery_*, github_identity) — config sweep 로 본 cycle 처단 완료 |
| ERROR | 571 | 7 distinct 패턴 + θ (이미 fix) |
| INFO | 45,848 | 정상 운영 |

ERROR 571 의 8 패턴 (θ = 본 cycle fix, 7 잔존):

| ID | 패턴 | 24h | Root code path |
|---|---|---|---|
| α | `tool_execute sandbox_close/missing_sandbox` | 18 | `lib/types/masc_error.ml:179` IoError wrapper, literal `"missing_sandbox_clone"` 외부 runtime (agent SDK) emit |
| β | `tool_execute executable=""` + 5-retry threshold-silence | 26 | `lib/keeper/agent_tool_execute_typed_input.ml:321,447-470` `check_exec` + retry threshold 5 |
| γ | `tool_execute cwd_not_directory: playground/*` | 11 | `lib/keeper/agent_tool_execute_path.ml:26-40` + `keeper_failure_circuit_breaker.ml:100` |
| δ | `cascade tier-group.glm-coding-with-spark exhausted` | 13 | `lib/keeper/keeper_turn_driver_try_cascade.ml:899` + `lib/cascade/provider_health.ml:88-106` |
| ε | retired PR-review helper reported closed PR state (ramarama) | 15 | `"pr_not_open"` literal 외부 MCP handler emit, board cache lag |
| ζ | `tool_execute gh not in dev_full allowlist` | 7 | `lib/keeper/dev_exec_allowlist.ml` + `agent_tool_execute_typed_input.ml:40-44` mode dispatch |
| η | `keeper_task_done anti-rationalization` | 6 | `lib/anti_rationalization.ml:504-600` — Issue #8688 이전 37/24h → 현재 6 = 정상 baseline |
| θ | autoboot masc-improver failed | 11 | ✅ 본 cycle fix (github_identity 제거) |

## 1. Sweep strategy

### Group 1: LLM-facing prompt 강화 (β, ζ, γ partial, ε partial) — config + 1 lib commit

- **β**: PR #18686 머지 — `tool_execute_description` 끝 COMMON REJECTIONS 절 추가
- **ζ/γ/ε partial**: `<base-path>/.masc/config/keepers/*.toml` (15 keeper) 의 instructions 끝에 *운영 hot-path 공통 규칙* footer — typed PR helper 우선 사용, `executable=""` 금지, playground cleanup 감지, PR closed graceful skip
- Workaround Sig: #5 positive (typed boundary 강화)

### Group 2: Sandbox typed boundary (α) — RFC 후속 PR-1

`lib/types/masc_error.ml:179` 의 `IoError of string` wrapper 가 *외부 runtime (agent SDK) string-wrapped errors* 를 통합. 그 안에 `missing_sandbox_clone` literal 이 *substring 분류 대상* — Workaround Sig #2 위험.

**Proposal**: typed variant 분리
```ocaml
type system_error =
  | Sandbox_missing_clone of { agent_name: string; sandbox_root: path }
  | Sandbox_closed of { reason: closed_reason; path: path }
  | IoError of string  (* fallback for unclassified — counter+warn *)
```

`closed_reason` 도 closed-sum (Sandbox lifecycle 의 명시 phases).

**Pre-flight check**: `tool_execute` 진입 시 *sandbox clone inventory* 확인 — `repos/` 디렉토리 존재 검증. 실패 시 typed error 즉시 emit (현 lazy emit 대비 stack 짧음).

**PR-1**: typed variant + 한 emit site (currently `IoError "missing_sandbox_clone: ..."`) 만 마이그레이션. PR-2 부터 caller 마이그레이션.

### Group 3: Eager provider reach validation (δ + boot-time fake reach check) — RFC 후속 PR-1

`lib/cascade/provider_health.ml:88-106` 의 `healthcheck.enabled=false` 시 *probe 생략* — boot log 의 13 candidate 모두 `not_applicable/skipped` (config-only validation). δ 의 ERROR 가 *첫 cascade 호출 시점* 표면화 — 늦은 발견.

**Proposal**: 
1. `provider_health` 에 *opt-in eager mode* (`MASC_PROVIDER_HEALTH_EAGER=true`) — Eio runtime 확보 후 *first keeper turn 직전* one-shot reach validation. Result.t 반환 — fail 시 boot 차단 (not silent skip).
2. `keeper_turn_driver_try_cascade.ml:899` 의 `runtime_candidate_label` 가 현재 literal `"runtime"` 반환 (Runtime Lens boundary 의 over-redaction). 내부 observability 는 *real model_id* 유지, 외부 surface 만 redact (memory: reference_runtime_lens_boundary_carve_out 정합).

**Workaround Sig 위험 점검**:
- #1 telemetry-as-fix 함정: counter/WARN 추가 *금지*. 본 PR 은 *Result.t 반환 + boot 차단* 으로 root-fix
- #2 string classifier: `runtime_candidate_label` 의 *typed model_id* 노출 — string 분류 제거
- → positive change

### Group 4: PR state typed awareness (ε lib part) — RFC 후속 PR

`"pr_not_open"` literal 의 외부 MCP handler emit. 두 path 가능:
1. board cache 의 *PR url state* 에 *TTL* 추가 — Workaround Sig #3 (cache/TTL) — *justification 필수*
2. PR-state command handling 의 *closed-state typed enforce* — Result.t with `Pr_not_open of {pr_num; closed_at}` — typed boundary

**권장**: 2 (typed). ramarama 의 *PR awareness* 가 명시 closed-state 신호 받으면 graceful skip 가능.

### Group 5: Playground lifecycle policy (γ) — config + lib light

paused keeper 의 sandbox cleanup race — `lib/keeper/keeper_lifecycle*.ml` 의 cleanup hook 에 *paused state 제외* 명시. 또는 *retired* 도입 — *retired* keeper 만 cleanup, *paused* 는 보존.

### Group 6: Monitoring only (η)

`anti_rationalization` review 6/24h = Issue #8688 이전 37/24h 대비 정상 baseline. Fix 불필요. 본 RFC 는 *monitoring statement* — 6/24h ± 50% 이탈 시 root re-investigation trigger.

## 2. Implementation phases

| Phase | Group | PR target | Risk |
|---|---|---|---|
| **PR-0** (본 RFC) | — | This RFC (Draft → Active on merge) | Low |
| **PR-1** | G1 β | #18686 (Draft, awaiting CI + Ready) | Low (description only) |
| **PR-2** | G1 ζ/γ/ε partial | config-only (별 repo or `<base-path>/.masc/`) | 본 cycle 완료 |
| **PR-3** | G2 α typed boundary | masc-mcp lib | Medium |
| **PR-4** | G5 γ playground policy | masc-mcp lib | Low |
| **PR-5** | G3 δ eager reach | masc-mcp lib (RFC discovery 후 별 RFC 가능) | Medium |
| **PR-6** | G4 ε typed PR awareness | masc-mcp lib | Medium |
| **monitor** | G6 η | no-op, dashboard alert 만 | None |

## 3. Workaround Sig 검증 (전체)

본 RFC 의 모든 PR 은 다음 5 시그니처 위반 점검 필수 (CLAUDE.md §Workaround Sig):

| PR | 시그니처 위험 | 검증 |
|---|---|---|
| β #18686 | #5 positive | ✅ — description 강화 |
| α PR-3 | #2 string classifier 위험 | typed variant 로 회피 |
| δ PR-5 | #1 telemetry-as-fix 위험 | Result.t + boot 차단 으로 회피 |
| ε PR-6 | #3 cache/TTL 함정 | typed closed-state enforce 로 회피 |
| γ PR-4 | #3 N-of-M 위험 (paused 만 분기) | unified lifecycle FSM 으로 회피 |
| ζ G1 | — | dev_full mode dispatch 분석 |
| η | — | no-op, monitoring only |

각 PR body 에 `bash ~/me/scripts/pr-rfc-check.sh --pr-body /tmp/pr-body.md` PASS 명시 + Workaround Sig 매칭 결과 필수.

## 4. Verification (각 PR 머지 후 24h)

| 패턴 | 현재 | 목표 | 측정 |
|---|---|---|---|
| α | 18 | ≤4 (-80%) | jq grep system_log_*.jsonl |
| β | 26 | ≤8 (-70%) | 동일 |
| γ | 11 | ≤6 (-50%) | 동일 |
| δ | 13 | 0 (-100%) | 동일 |
| ε | 15 | ≤3 (-80%) | 동일 |
| ζ | 7 | ≤1 (-90%) | 동일 |
| η | 6 | 6±3 baseline | 동일, ±50% 이탈 시 alarm |

## 5. Non-goals

- 본 RFC 는 *roadmap* — PR-3~6 의 *세부 design* 은 *별 RFC* 가능 (typed boundary RFC, eager reach RFC, typed PR awareness RFC)
- Workaround signature 가 시그니처 매칭 시 *별 RFC 작성 필수*. 본 RFC 는 *위험 식별* 까지
- η 의 anti-rationalization rule 추가/조정 *out of scope*

## 6. Related artifacts

- Plan file: `~/.claude/plans/golden-percolating-honey.md` (사용자 환경, RFC PR-0 의 detail 포함)
- 24h log inventory script: `jq -r --arg c "$CUTOFF" 'select(.ts >= $c and .level=="ERROR") | .message[:100]' system_log_*.jsonl | sort | uniq -c | sort -rn`
- Verification cron 후보: `~/me/scripts/audit-error-pattern-counts.sh` (미존재, PR-1 와 같이 추가 가능)

`RFC-WAIVED: docs-only RFC roadmap, no credential/identity/operator/sandbox/hooks/workflow subsystem touched.`
