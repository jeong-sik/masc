# Chat clock self-validation

## 공통 헤더
- 날짜(ISO8601): 2026-10-02T13:17:45.187134+09:00
- 작성자: Codex
- 결정 ID: chat-clock-40761-self-validation
- 적용 대상: chat log gutter clocks and parallel block placement
- 결정 상태: 추적 필요

## 근거 (Evidence)
- 항목: Four parallel blocks in the same insertion slot follow category/source order without sorting, even if their timeline clocks differ.
- 출처: bin/masc_tui_render_chat.ml merge_blocks and blocks construction; sort-expression-check.ml; sort-expression-result.txt
- 확인일시: 2026-10-02T13:17:45.187134+09:00
- 신뢰도: High
- 제한조건: Source counterexample; extraction executes only the renderer sorting expression with a minimal record, not the full TUI.

## 검증 (Verification)
- 1차: Dispatch clock differs from causal frontier; latest progress placement pairs with matching gutter after repair.
- 2차: Extracted exact sorting expression passes 28 assertions: every four-block permutation, equal-time stability, missing time, insertion precedence, reverse 128-message source order.
- 3차: Native frame fixtures added; touched sources syntax parse and diff check pass. Native fixtures are unexecuted.
- 재현 결과: Previously same-slot category/source order can show later blocks before earlier ones; now position first, then timeline time, stable equal-time order.

## 불확실성 (Uncertainty)
- 미확인 항목: Full native frame fixture and installed-binary/production screenshot; source order tie authority beyond retained data.
- 영향: No claim that each stretch of a grouped execution has its own event time or that screenshot exact requests were matched.
- 추가 확인 필요: Focused native TUI fixture and real before/after input frames on exact PR head.

## 적용범위 (Scope)
- 영향 받는 영역: Streamed block clocks and same-slot relative block order.
- 제약/배제: Preserves intra-block transcript order and causal insertion position; no provider or queue behavior changes.
- 롤백 조건: Revert PR if native TUI tests show broken causal placement or missing output.

## Reproduce extracted expression

Run `ocaml -noinit docs/evidence/2026-10-02-chat-clock/sort-expression-check.ml`.
The `sort` body is copied verbatim from the renderer's `let blocks` expression, with `in blocks` as its return. The minimal record carries only the two fields read by that expression and a fixture identity. This is expression-level executable evidence, not native compilation or TUI behavior proof.
