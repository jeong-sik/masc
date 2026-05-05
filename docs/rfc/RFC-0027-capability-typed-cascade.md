# RFC-0027: Capability-typed cascade catalog

> **Status**: Draft
> **Authors**: jeong-sik
> **Created**: 2026-05-05
> **Related RFCs**: RFC-0026 (work-conserving keeper admission) — orthogonal
> **Plan**: `~/me/planning/claude-plans/inherited-toasting-moon.md` (Phase 1)

## 1. Summary

Cascade catalog는 현재 capability-blind. `glm_coding_plan_only.fallback = big_three` 같은 fallback chain이 keeper-bound runtime MCP HTTP header를 carry 못하는 provider (gemini_cli / codex_cli) 다수를 포함해도 startup-time 검증이 없다. 결과: runtime에서 `no_tool_capable_provider` 사고가 발생할 때까지 silent.

본 RFC는 cascade catalog에 **declarative capability profile**을 도입하여 mismatch를 startup-time 정적 검증으로 변환한다.

## 2. Motivation

### 2.1 사고 사례 (2026-05-05)

3 keeper (`sangsu`, `masc-improver`, `glm-coding-plan`)가 stuck. cascade `glm_coding_plan_only` (model = `glm-coding:auto`)의 fallback이 `big_three`인데, big_three의 `gemini_cli:auto` (7 variants) + `codex_cli:gpt-5.3-codex-spark`가 모두 `Runtime_mcp_http_headers_required` rejection. 통과한 claude_code/glm-coding/kimi가 있어도 turn semaphore 별도 사고로 막힘.

### 2.2 Root cause

- Cascade fallback chain은 capability를 인지하지 않음
- Provider별 capability는 `Provider_tool_support.capabilities` record에 5 fields로 이미 표현 가능하지만, cascade 측에서 "어떤 cascade는 어떤 capability를 요구한다"는 declarative 정보 없음
- Validator (`cascade_catalog_validator.ml`)는 spec/strategy/cycle은 검사하지만 capability mismatch는 검사 안 함

### 2.3 비목표 (out of scope)

- Runtime fairness / token bucket / admission scheduling — RFC-0026의 책임
- CLI runtime의 runtime-MCP HTTP header carry 기능 추가 — gemini-cli upstream 이슈 (#3470)
- Provider capability 추론 로직 변경 — `Provider_tool_support.capabilities_of_config`가 SSOT 유지

## 3. Design

### 3.1 Capability profile registry (PR #1, this document)

새 모듈 `lib/cascade/cascade_capability_profile.{ml,mli}`. 명명 profile 4개:

| Profile | Inline tools | Inline tool_choice | Runtime MCP tools | Runtime MCP events | Runtime MCP HTTP headers |
|---|---|---|---|---|---|
| `tool_strict` | optional | optional | required | required | required |
| `inline_tools` | required | required | optional | optional | optional |
| `lite` | optional | optional | required | required | optional |
| `local` | optional | optional | optional | optional | optional |

**`tool_strict`는 inline tools를 require하지 않음**: CLI runtime (claude_code, kimi_cli)이 keeper-bound MCP를 carry하는 path가 runtime MCP이고, inline은 사용 안 함. 사고 사례의 3 keeper가 정확히 이 path를 요구.

**`required`** = profile은 satisfied 되려면 provider가 그 capability를 만족해야 함.
**`optional`** = profile이 그 capability를 요구 안 함 (provider 만족 여부 무관).

각 profile의 의미:
- **`tool_strict`**: keeper-bound runtime MCP를 carry 가능한 provider만. 사고 사례의 3 keeper가 필요한 lane. 실제 후보: `claude_code`, `kimi_cli`, HTTP-based (`glm-coding`, `anthropic`, `openrouter`).
- **`inline_tools`**: Direct API only — inline tools + tool_choice 만족. CLI runtime은 거의 fail. HTTP/Direct API (`anthropic`, `glm`, `openrouter`, `kimi-api`, `codex-api`)에 적합.
- **`lite`**: runtime MCP는 carry 가능하되 HTTP header까지는 요구 안 함. `gemini_cli`도 통과 (static config만 있어도 OK).
- **`local`**: 어떤 provider도 통과. fallback 마지막 단계 (`local_recovery` 같은 ollama-only profile).

### 3.2 Provider satisfaction check

```ocaml
val provider_satisfies_profile :
  profile -> Provider_tool_support.capabilities -> bool
(** [provider_satisfies_profile p caps] is [true] iff every [required] field
    of [p]'s capability requirement is set on [caps]. *)
```

이 함수는 PR #2 (cascade.toml schema) + PR #3 (validator lint)에서 사용된다.

### 3.3 PR scope (this PR — PR #1)

본 PR은 **registry only** — schema 변경/validator 변경/실제 enforcement 없음. 후속 PR이 이 registry를 consume.

| 신규 | 용도 |
|---|---|
| `lib/cascade/cascade_capability_profile.mli` | Public API |
| `lib/cascade/cascade_capability_profile.ml` | Implementation |
| `test/test_cascade_capability_profile.ml` | Unit tests |

### 3.4 후속 PR 개요

| PR | 책임 |
|---|---|
| #2 | `cascade.toml` schema에 `required_capability_profile = "tool_strict"` 옵션 필드 추가. omit = legacy. |
| #3 | `cascade_catalog_validator.ml`에 capability mismatch lint. `MASC_CAPABILITY_LINT={off,warn,error}`. cross-cascade fallback resolver capability propagation. |
| #4 | `__safe_lane` system profile (모든 capability 만족) 추가 + last-resort fallback target. |
| #9 | Dual-track CLI+API entry parser (gemini_cli primary → gemini-api secondary). |

## 4. Compatibility / migration

- 본 PR은 **순수 추가** — 기존 동작 변경 없음
- 후속 PR #2~#4도 모두 backward-compatible: `required_capability_profile` 필드 omit = legacy behavior
- env `MASC_CAPABILITY_LINT` default `warn` (rollout 후 `error`)

## 5. Verification

- Unit tests: 각 profile의 capability 매트릭스가 정확한지
- Roundtrip: `profile_to_string` ∘ `profile_of_string` = identity
- Coverage: `provider_satisfies_profile` truth table (4 profiles × 2^5 capability combos = 128 cases, 또는 representative cases)

## 6. Risks

| Risk | Mitigation |
|---|---|
| Profile 분류가 너무 거칠어 실제 사고 못 막음 | 후속 PR #3 validator의 lint level 단계 (`warn`→`error`) + 운영 로그 분석 |
| 새 profile 추가 시 forward-compatibility | `profile` variant은 closed sum — 신규 추가 시 명시적 PR 필요. 의도적 trade-off (parser fallthrough가 silent fail보다 안전) |
| RFC-0026과 schema 충돌 | PR #2가 `[admission.*]` blocks을 건드리지 않음 — 스키마 분리 명확 |

## 7. Memory rule 준수

- `feedback_no-string-matching-classification`: profile classification은 `Provider_tool_support.capabilities` record 기반, string matching 없음
- `feedback_periodic_scanner_must_transition_state_after_acting`: 본 PR은 scanner 변경 없음 (schema only)
- `feedback_masc_mcp_draft_guard_blocks_agent_ready`: agent-authored PR Draft 유지
