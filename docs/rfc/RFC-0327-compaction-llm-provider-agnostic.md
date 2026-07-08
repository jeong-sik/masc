# RFC-0327: compaction LLM — provider-무관 structured output + 활성화/계측/가시화

## Status
Draft

## Context

compaction을 "LLM에 위임한다"는 것이 dashboard 어디에서도 증명되지 않는 현상을 진단했다. 진단 결과, **LLM compaction은 사실 현재 아무 keeper에서도 돌지 않는다**:

1. `keeper_compaction_llm_summarizer` 경로는 존재(RFC-0313-adjacent W2)하지만 **opt-in**이고, keeper 설정 어디서도 `compaction_strategy = Llm`이 켜져 있지 않다 → 모든 keeper가 deterministic extractive chain으로 compaction.
2. opt-in이 안 켜인 **근본 이유**는 provider 의존이다. 현재 경로는 `Keeper_structured_output_schema.apply_to_provider_config`로 **provider-native `response_format`(json_schema)** 를 주입한다. `runtime.toml:257`("librarian native-json_schema rejection root cause"), `runtime.toml:580`("실측 전이라 fail-closed 유지")가 말하듯, 현재 librarian runtime(`glm-coding.glm-5-turbo`)은 native json_schema를 안 지원한다. 그래서 `plan_schema_supported`가 false → `make`가 None → deterministic fallback → LLM compaction이 활성화될 수 없었다.
3. dashboard의 compaction 표시는 `compactions_ok`/`compaction_failed`(outcomes), 차트 포인트, debug 카운터, 별도 `compaction-snapshots` 패널로 **deterministic compaction**은 보이지만, "LLM이 했는가/어떤 모델이/성공 실패"는 어디에도 없다.

즉 "LLM 위임"이 빈말인 이유는 (a) provider schema 의존으로 활성화 자체가 막혀 있고, (b) 활성화되더라도 발생 계측/가시화가 없다.

## Principle

**provider 무관 structured output.** compaction plan을 provider-native json_schema에만 의존하지 않고, tool call 기반으로도 받는다. claude-code CLI(`~/me/workspace/yousleepwhen/claude-code`)가 쓰는 dual path 패턴을 이식한다:

- `modelSupportsStructuredOutputs(model)` → native `response_format`(json_schema) 사용.
- 미지원 → **StructuredOutput tool call fallback**: LLM이 tool call로 plan을 반환하면 Ajv 등으로 validation 후 사용, 실패 시 retry.

이것이 "provider와 무관"의 실체이며, 활성화 걸림돌(provider schema 미지원)을 제거한다.

## Changes (phased)

### B-0 — compaction plan 획득을 provider-무관으로 (백엔드, 선행)
- `keeper_compaction_llm_summarizer`: 현재 `apply_to_provider_config`(native) 경로만. **StructuredOutput tool call fallback** 경로 추가.
  - provider가 native json_schema 지원 → 현행 유지.
  - 미지원 → 요청에 StructuredOutput tool(compaction plan input schema)을 붙여 LLM이 tool call로 반환. validation(`parse_compaction_plan` 재사용) + retry(claude-code `error_max_structured_output_retries` 패턴).
- 참조 구현: `claude-code/src/tools/SyntheticOutputTool/SyntheticOutputTool.ts`(input passthrough + `call`에서 validation), `services/api/claude.ts:1583`(`modelSupportsStructuredOutputs` 분기), `QueryEngine.ts:331`(`registerStructuredOutputEnforcement`).

### B-1 — 활성화 (B-0 확보 후)
- keeper별 `compaction_strategy = Llm` opt-in. 단 **전 keeper 즉시 활성화가 아닌 소수 keeper부터**(B-2 검증 통과 조건부).

### B-2 — 품질 검증 (활성화 조건)
- 소수 keeper에서 deterministic vs LLM compaction A/B. 측정: 맥락 보존(요약 후 key fact 누락 여부), 토큰 절약, keeper 후속 턴 품질. 검증 통과 시에만 점진 확대. 실측 없는 전면 활성화는 거부(runtime.toml 주석이 이미 이 상태를 인지하고 보류한 것).

### B-3 — 발생 계측
- 메트릭: compaction 전략(deterministic/LLM)별 성공/실패/latency/사용 모델. 기존 `record_memory_consolidation_metrics`와 구분(memory bank consolidation ≠ context compaction).
- keeper dashboard snapshot에 LLM compaction 발생 필드 wire.

### B-4 — context rail 가시화
- `keeper-workspace-rail.ts` `ContextSection`에 compaction 증명 추가: 현재 전략(deterministic/LLM 명시), 최근 compaction(before/after tokens, trigger), gate pct, 발생 이력. "LLM 위임"이 사실로 드러나야 한다.

## Out of scope

- catalog/registered repo ID 제거 → RFC-0323(PR #23667).
- HITL chat 노출 → PR #23678.
- memory bank consolidation(librarian facts 정리)은 별개 계층. context compaction(LLM)과 metric을 섞지 않는다.

## Risks

- B-0 tool call fallback 품질: LLM이 tool call로 잘못된/빈 plan을 반환. validation + retry로 막되, deterministic fallback은 항상 보존(`make`가 None이면 deterministic으로).
- B-2 품질 미달 시 LLM compaction 활성화 보류 — 그 경우 dashboard는 "deterministic으로 운영 중"을 솔실히 표시(B-4).
- provider capability 판별(`modelSupportsStructuredOutputs` 대응)이 부정확하면 fallback이 과동작/미동작. capability probe 결과를 신뢰 가능한 catalog로.

## Verification

- B-0: 단위 테스트 — native 지원 provider + 미지원 provider 양쪽에서 유효 compaction plan 획득. retry/fallback 경로.
- B-2: A/B 측정 결과 문서화(맥락 보존 정량).
- B-3: 메트릭 노출 확인.
- B-4: context rail에서 전략/발생/증명 렌더링. keeper별 compaction이 deterministic인지 LLM인지 명시.

## 참조

- `~/me/workspace/yousleepwhen/claude-code/src/tools/SyntheticOutputTool/SyntheticOutputTool.ts`
- `~/me/workspace/yousleepwhen/claude-code/src/services/api/claude.ts:1583,2347`
- `~/me/workspace/yousleepwhen/claude-code/src/QueryEngine.ts:328-332,1004-1043`
- masc `lib/keeper/keeper_compaction_llm_summarizer.ml`, `lib/keeper/keeper_structured_output_schema.ml`
