# Tool Parameter Hallucination: Harness-Level Solutions

**Date**: 2026-04-15
**Author**: Vincent (with research synthesis)
**Status**: Research report — actionable recommendations
**Scope**: MASC keeper tool calling, generalizable to all tool use

---

## 1. Problem Statement

keeper들이 `keeper_github` 호출 시 존재하지 않는 PR/issue 번호를 생성(hallucinate)한다.
cheolsu(GLM-5-turbo): 87 연속 실패. nick0cave: repo slug도 지어냄.
poe: 같은 번호(#7036) 3회 반복 시도.

**이것은 GitHub만의 문제가 아니다.** Tool parameter hallucination은 모든 tool use에서 발생하는 구조적 문제다.

---

## 2. 연구 근거

### 2.1 Samchon/AutoBe: Function Calling Harness (6.75% → 100%)

**Source**: [Qwen Meetup: Function Calling Harness](https://dev.to/samchon/qwen-meetup-function-calling-harness-from-675-to-100-3830)

핵심 발견:
- **Schema = 새로운 프롬프트**: 프롬프트로 "X하지 마"는 Pink Elephant Problem. Schema로 불가능한 값을 물리적으로 제거해야 함.
- **Self-Healing Loop**: Write → Validate → Diagnose → Correct → Retry. "틀렸다"가 아니라 **정확히 어디서 어떤 타입이 기대되었는지** 명시.
- **Model Neutrality**: 동일 harness → 모든 모델 적용. 성능 차이는 retry count로만 나타남.
- **Small Model as QA**: 3B 모델이 시스템 취약점을 가장 잘 폭로.

**MASC 현황**: Rank 1-3 구현 완료 (type coercion, self-healing loop, 2-stage tool selector).
**Gap**: **entity-level validation (실존 여부 검증)은 Samchon 범위 밖** — Samchon은 type/format 검증이지, 값의 의미론적 정확성(semantic correctness) 검증은 다루지 않음.

### 2.2 DS-IA Framework: Three-Level Cascade Verifier (ICLR 2025 계열)

**Source**: [Proactive Rejection and Grounded Execution](https://arxiv.org/abs/2603.16207)

IoT 환경에서의 tool parameter grounding — 우리 문제와 구조적으로 동일:

| DS-IA Layer | IoT 적용 | MASC keeper_github 매핑 |
|-------------|----------|------------------------|
| **VR: Spatial Topology** | 방(room)이 존재하는가? | **repo slug** 존재하는가? |
| **VD: Entity Alignment** | 해당 방에 해당 장치가 있는가? | 해당 repo에 **PR/issue 번호**가 있는가? |
| **VC: Affordance Verification** | 장치가 요청된 기능을 지원하는가? | PR에 대해 merge/close 등 **해당 작업**이 가능한가? |

핵심 설계 원칙:
- **Stage 1 = Semantic Firewall**: 실행 전에 환경 스냅샷(현재 상태)과 대조.
- **결정론적 cascade**: 각 layer는 순수 lookup. LLM 재추론 불필요.
- **Fail-fast**: 첫 번째 검증 실패 시 즉시 rejection + 유효 대안 제시.
- **State-Aware Disambiguation**: 모호한 참조를 현재 상태에서 자동 해소 (예: "the lamp" → OFF 상태인 유일한 lamp).

### 2.3 Dify Pre-Execution Policy Enforcement (2026)

**Source**: [dify#34021](https://github.com/langgenius/dify/issues/34021)

OWASP LLM Top 10 (2025) + OWASP Agentic Top 10 (2026) 기반:
- `pre_invoke(tool_name, tool_parameters, user_context) → allow | deny | require_approval`
- LLM reasoning과 독립 (prompt injection bypass 방지).
- **Tool invocation context 전체에 접근** — parameter 개별 검증 가능.

### 2.4 HaluGate: Token-Level Detection (vLLM, 2025)

**Source**: [vLLM Blog — HaluGate](https://vllm.ai/blog/halugate)

- 2-stage pipeline: Sentinel(분류) → Detector(토큰별 검증) → Explainer(NLI).
- **한계**: context가 없으면 검증 불가 — extrinsic hallucination만 감지.
- **Tool parameter에 직접 적용 불가**: 우리 문제는 생성된 파라미터가 현실과 일치하는지 여부. HaluGate는 response 텍스트의 faithfulness 검증.

### 2.5 Anthropic Tool Use Best Practices (2026)

**Source**: [Anthropic — Implement Tool Use](https://platform.claude.com/docs/en/agents-and-tools/tool-use/implement-tool-use)

- `strict: true` + JSON Schema → 구조적 유효성 보장.
- `enum` 제약 → 가능한 값 집합 제한.
- `input_examples` → 형식 grounding.
- **한계**: enum은 **정적(static)** — PR 번호처럼 동적으로 변하는 entity에 적용 불가.

### 2.6 ConAgent: Iterative Calibration (IterCali)

- Grounding → Execution → Observing 3단계 분리.
- 도구 실행 전 "monitoring tool"로 도구 상태 확인.
- 실패 피드백으로 자가 보정 (calibration).

### 2.7 Production 2026 Playbook 합의점

[AgenticCareers](https://agenticcareers.co/blog/tool-use-function-calling-developer-guide), [Prompt Engineering Guide](https://www.promptingguide.ai/agents/function-calling):

- Schema validation 필수 (Pydantic/Zod/Typia).
- Parameter error → retry 금지, structured feedback로 self-correction.
- Transient failure(network) → retry with backoff.
- Error message에 "Expected format" 명시.

---

## 3. 문제 분류: 정적 vs 동적 Parameter Validation

| 구분 | 정적 (Static) | 동적 (Dynamic) |
|------|-------------|---------------|
| **검증 시점** | 컴파일/등록 시 | 실행 직전 |
| **대상** | type, format, enum, required | **entity 존재 여부**, 권한, 상태 |
| **예시** | `unit: "celsius" \| "fahrenheit"` | `pr_number: 7141 (exists?)` |
| **도구** | JSON Schema, Typia, strict:true | **Cache + API lookup** |
| **업계 솔루션** | Samchon harness, Anthropic strict | DS-IA Cascade, ConAgent, 자체 구현 필요 |

**Samchon harness가 해결하는 것**: 정적 검증 (type mismatch, format error, missing field).
**Samchon harness가 해결하지 못하는 것**: 동적 검증 (존재하지 않는 entity 참조).

**keeper_github 문제는 동적 검증 영역이다.** PR #7141 (번호 존재 검증)이 이 영역이다.

---

## 4. 현재 구현 매핑 (MASC keeper_github)

### 구현된 것 (하드코딩 포함)

| Layer | 파일 | 메커니즘 | 분류 |
|-------|------|---------|------|
| **Static Schema** | OAS `tool_input_validation.ml` | type coercion, format check | 정적/결정론적 |
| **Self-Healing** | OAS `tool_middleware.ml` | heal_tool_call (max 3 retry) | 정적/결정론적 루프 |
| **Tool Selection** | OAS `tool_selector.ml` | BM25 + LLM rerank | 정적/비결정론적 |
| **Entity Cache** | `keeper_gh_cache.ml` | in-memory PR/issue 번호 캐시 (TTL 120s) | **동적/결정론적** |
| **Number Gate** | `keeper_exec_github.ml:344-427` | extract → validate → reject/pass | **동적/결정론적** |
| **Post-exec Hint** | `keeper_exec_github.ml:542` | `gh_not_found_hint` | **동적/결정론적** |
| **Escalation** | `keeper_exec_github.ml:386-401` | `record_rejection` + 반복 시 톤 강화 | **동적/프롬프트 의존** |

### 구현되지 않은 것

| Gap | DS-IA 대응 | 현재 상태 |
|-----|-----------|----------|
| **VR: Repo slug validation** | Spatial Topology | 형식만 검증 (`owner/repo` 패턴), 실존 여부 미검증 |
| **VC: Affordance check** | Affordance Verification | 미구현 (예: merged PR에 merge 시도) |
| **Cross-tool entity grounding** | - | keeper_github에만 적용, 다른 도구(board, task)는 없음 |
| **Convergence metric** | - | 게이트 작동 후 몇 턴 만에 올바른 번호를 선택하는지 미측정 |

---

## 5. 하드코딩 분석: 무엇이 하드코딩이고 무엇이 아닌가

### 하드코딩인 것 (제거 대상)

1. **`gh_pr_number_subcmds` 리스트** (line 75-78): `["view"; "close"; ...]` — 하드코딩된 subcommand 목록.
   - 개선: `gh` CLI의 help output 파싱 또는 외부 config.
   - 현실: gh CLI subcommand는 거의 변하지 않음. 실질적 위험 낮음.

2. **`max_gh_output_bytes = 8192`** (line 137): 매직 넘버.
   - 개선: config에서 로드.
   - 현실: 65KB 응답이 context overflow를 일으킨 실측값 기반. 문서화되어 있으면 허용 가능.

3. **`TTL 120s`** (keeper_gh_cache.ml): 캐시 만료 시간.
   - 개선: config에서 로드.
   - 현실: gh API rate limit 안전 범위 내. 실측 기반.

4. **`take 20 valids`** (line 372): 거부 응답에 포함할 최대 유효 번호 수.
   - 개선: config에서 로드.
   - 현실: context window 내 합리적 크기. 하지만 arbitrary.

### 하드코딩이 아닌 것 (구조적으로 올바른 것)

1. **3-token strict parser** (`extract_gh_target_number`): `"pr" :: sub :: num_str :: _` 패턴.
   - 이것은 sound partial function. 하드코딩이 아니라 **구문 규칙**.
   - 확실한 입력만 Some, 나머지 None. 올바른 Det/NonDet 경계.

2. **Gate 응답 포맷**: `"WRONG NUMBER (not a repo problem)"`.
   - 이것은 LLM-readable feedback. 하드코딩이 아니라 **프로토콜**.
   - 단, gate-response-llm-readable feedback memory에 따른 의도적 설계.

3. **Cache fetch via REST API**: `gh api repos/.../pulls?state=all`.
   - qa-king의 권고에 따른 선택. GraphQL 회피는 의도적.

---

## 6. 일반화 제안: Tool Parameter Grounding Framework

현재 keeper_github에만 적용된 패턴을 **모든 tool에 적용 가능한 프레임워크**로:

### 6.1 Three-Level Cascade (DS-IA 매핑)

```
[VR] Namespace Validation → [VD] Entity Validation → [VC] Affordance Check
        ↓                          ↓                         ↓
  "repo exists?"            "PR #N exists?"           "PR #N is mergeable?"
  "board exists?"           "post #N exists?"         "post is not archived?"
  "room exists?"            "agent exists?"           "agent is online?"
```

### 6.2 구현 위치: OAS vs MASC

| 위치 | 장점 | 단점 |
|------|-----|------|
| **OAS (tool_middleware)** | 모든 agent에 적용, 범용, Samchon 패턴과 합류 | tool-specific lookup 로직 필요, OAS가 domain 지식을 가짐 |
| **MASC (keeper_exec_*.ml)** | domain-specific 검증 자연스러움, 현재 구현 위치 | 다른 tool에 확산 시 복붙 |
| **MCP pre_invoke hook** | Dify 패턴, 설정 기반, 플러그인화 | MASC에 MCP hook 인프라 추가 필요 |

**권장**: 현재 MASC-level 유지 (domain-specific), OAS에는 **추상 인터페이스**만 제공.

```ocaml
(* OAS 추상 인터페이스 *)
type grounding_result =
  | Grounded               (* entity 확인됨 *)
  | Not_found of string list  (* 유효 대안 목록 *)
  | Unknown                (* 확인 불가, fail-open *)

type entity_grounder = {
  validate : tool_name:string -> params:Yojson.Safe.t -> grounding_result;
}
```

MASC 측에서 keeper_github, keeper_board 등 tool별 grounder를 등록.

### 6.3 하드코딩 제거 경로

| 현재 | 개선 | 우선순위 |
|------|------|---------|
| `gh_pr_number_subcmds` 하드코딩 | `.masc/tool_schemas/keeper_github.toml`에 선언 | Low (거의 안 변함) |
| `TTL 120s` 하드코딩 | `config/keeper_gh_cache.toml` | Medium |
| `take 20` 하드코딩 | config | Low (arbitrary이지만 안전) |
| `"WRONG NUMBER"` 메시지 | template 파일 | Low (프로토콜이지 하드코딩 아님) |
| **`keeper_github` 전용 gate** | **범용 entity_grounder 인터페이스** | **High — 다른 tool로 확장 시** |

---

## 7. 다음 단계 (우선순위순)

### P0: 누락된 테스트 작성 (지금)
- `record_rejection`, `is_repeat` 경로: 0 test coverage. MANIFEST 위반.
- 코드는 이미 production에서 동작 중이지만 검증 없음.

### P1: Config 추출 (하드코딩 제거)
- `TTL`, `max_valid_numbers`, `max_gh_output_bytes` → TOML config.
- 동작 변경 없음, 하드코딩만 config으로 이동.

### P2: Repo slug 실존 검증 추가 (DS-IA VR layer)
- nick0cave가 `anyang-keepers/masc-mcp` (존재 안 함)을 시도.
- `gh api repos/{owner}/{repo}` 호출 + cache.
- L1(번호 검증)과 독립적인 진짜 새 레이어.

### P3: Convergence metric 추가
- gate 작동 → 몇 턴 후 올바른 번호 선택? (Samchon의 "retry count로만 측정")
- `keeper_tool_call_log`에 `grounding_rejected` 이벤트 기록.

### P4: 범용 entity_grounder 인터페이스 (OAS 영역)
- 다른 tool(board, task, agent)에 같은 패턴 적용 시.
- 현재는 keeper_github만이므로 시기상조.

---

## 8. 결론

| 관점 | 판단 |
|------|------|
| L1 (cache validation gate) | 올바르다. DS-IA의 Entity Alignment과 동일 패턴. 실측 9회 작동. |
| L2 (post-exec gh_not_found_hint) | 올바르다. L1 cache miss 시 fallback. 독립 레이어. |
| L3 (context injection) | **불필요하다.** L1이 같은 실패를 이미 잡고, valid_numbers를 이미 반환. 중복. |
| Escalation (record_rejection) | **프롬프트 엔지니어링이다.** 하네스가 아님. 테스트 없음. 효과 미측정. |
| 하드코딩 | TTL, max numbers는 config 추출 가치 있음. subcommand 목록과 메시지 포맷은 프로토콜. |
| 일반화 | **지금은 시기상조.** keeper_github 1개 tool에만 문제 발생. 2번째 tool에서 같은 문제 시 추상화. |

**핵심**: Samchon harness (정적 검증)는 이미 구현됨. keeper_github 문제는 **동적 entity grounding** — 업계에서도 아직 표준 솔루션이 없는 영역. DS-IA framework의 cascade verifier가 가장 가까운 참조 구현이며, 우리의 L1 cache gate가 이 패턴과 정확히 일치한다.

---

## Sources

- [Samchon/Typia: Function Calling Harness](https://dev.to/samchon/qwen-meetup-function-calling-harness-from-675-to-100-3830)
- [Typia Blog: Function Calling Harness](https://typia.io/blog/function-calling-harness/)
- [DS-IA: Proactive Rejection and Grounded Execution (arXiv 2603.16207)](https://arxiv.org/abs/2603.16207)
- [Dify: Pre-execution policy enforcement (dify#34021)](https://github.com/langgenius/dify/issues/34021)
- [vLLM HaluGate: Token-Level Hallucination Detection](https://vllm.ai/blog/halugate)
- [Anthropic: Implement Tool Use](https://platform.claude.com/docs/en/agents-and-tools/tool-use/implement-tool-use)
- [Prompt Engineering Guide: Function Calling](https://www.promptingguide.ai/agents/function-calling)
- [Tool Use and Function Calling: Developer Guide 2026](https://agenticcareers.co/blog/tool-use-function-calling-developer-guide)
- [LLM-Based Agents for Tool Learning Survey (Springer 2025)](https://link.springer.com/article/10.1007/s41019-025-00296-9)
