# Recall relevance improvement

## 공통 헤더
- 날짜(ISO8601): 2026-10-02T19:15:01.566739+09:00
- 작성자: Codex
- 결정 ID: recall-short-query-40807
- 적용 대상: Keeper current/absorbed/history search and conditional memory lookup guidance
- 결정 상태: 추적 필요

## 근거 (Evidence)
- 항목: Live RC search returned unrelated memories; runtime uses whole-query substring tiers before ranking.
- 출처: issue #40807; lib/keeper/keeper_tool_memory_runtime.ml answering/search_history; local raw trace turn-1790921211668-1d6d-000000.jsonl seq3/4
- 확인일시: 2026-10-02T19:15:01.566739+09:00
- 신뢰도: High
- 제한조건: The lexical false positives are concrete; semantic freshness and adequate autonomous use are separate problems.

## 검증 (Verification)
- 1차: Original substring predicate matches RC inside source/SRC and CI inside city.
- 2차: Actual String_util source executes 20 assertions: short terms, punctuation, Korean suffixes, phrase endpoints and AND fallback. Added native current/history/all search fixture is unexecuted.
- 3차: Read-only leader snapshot revision2604:396 facts, RC substring candidates79, boundary candidates42. Source syntax and TOML parse/diff checks pass.
- 재현 결과: Short ASCII word-interior matches excluded; Korean suffixed acronyms remain retrievable. Candidate-count reduction is not a precision score or retrieval behavior measurement.

## 불확실성 (Uncertainty)
- 미확인 항목: Full native search/index fixtures, deployed exact-head runtime, recall decisions after new prompt guidance, semantic precision and freshness.
- 영향: No guarantee that all required memory is retrieved or old policy memories disappear.
- 추가 확인 필요: Native search regression then real relevant-task query→result→action traces, including source='absorbed' and changed-source revalidation.

## 적용범위 (Scope)
- 영향 받는 영역: Lexical search match predicates; Keeper continuity prompt instructions.
- 제약/배제: No mandatory search-per-turn gate, automatic memory selection injection, memory deletion, ranking redesign, live prompt override or server restart.
- 롤백 조건: Revert PR if native tests show missing intended short-term matches or harmful prompt behavior.
