# Keeper task-query optimization evidence

## 공통 헤더

- 날짜(ISO8601): 2026-10-02T03:41:33+09:00
- 작성자: Codex
- 결정 ID: keeper-task-query-20261002
- 적용 대상: keeper_tasks_list, task compact projection
- 결정 상태: 추적 필요
- Evidence: local raw trace, compiled production modules, source reviews
- Timestamp: 2026-10-02T03:41:33+09:00
- Confidence: High for observed bytes and executed assertions; production impact unmeasured
- Delta: remove repeated discovery rows and completion receipts from compact results; add explicit selection before pagination.

## 근거 (Evidence)

- 항목: targeted task retrieval and compact payloads
- 출처: recorded raw trace; production OCaml sources; commands below
- 확인일시: 2026-10-02T03:41:33+09:00
- 신뢰도: High
- 제한조건: local replay and source checks; no deployed model comparison

The operator's trace is local and is not published with this report:
`<base-path>/.masc/keepers/e-masc-the-leader/raw-traces/turn-1790878508498-31db-000068.jsonl`.
SHA-256: `fa41d5d72b3e447a60c664a88217b5fa7d98228847a2969ac75baa99de7413f5`.
The recorded interval begins 2026-10-01 18:15:09 UTC and ends 18:19:07 UTC.

| Measurement | Before | After | Provenance |
| --- | ---: | ---: | --- |
| Task list response bytes across 11 pages | 130913 | 111205 | Offline response projection, not provider replay |
| Distinct ordered Task rows | 530 | 530 | Same captured snapshot arrays |
| Extra discovery rows | 100 | 10 | First-page window retained; continuation windows removed |
| One completed compact row, 4096-byte receipt | 4364 | 257 | Actual production serializer; synthetic completed fixture |
| Exact-ID selection over captured rows | 530 input rows | 2 requested rows | Actual production query module; known-ID lookup only |

Projection byte counts use compact UTF-8 JSON serialization with unchanged
captured fields except `new_tasks` and `new_tasks_count` on continuation pages.
The production revision digest has the same length but will be recomputed.
No claim that the model would discover its desired IDs without other work.

## 검증 (Verification)

- 1차: source review of both implementation commits passed
- 2차: relevant production and endpoint test objects compiled
- 3차: production query/cursor/serializer fixture executable passed
- 재현 결과: payload/query assertions passed; full endpoint execution blocked by base issue #40650

1. `opam exec --switch=5.5.1 -- scripts/dune-local.sh build lib/.masc.objs/byte/masc__Keeper_tool_task_runtime.cmo lib/.masc.objs/byte/masc__Keeper_tasks_list_query.cmo lib/.masc.objs/byte/masc__Keeper_tasks_list_cursor.cmo test/.test_keeper_task_outcomes.eobjs/byte/dune__exe__Test_keeper_task_outcomes.cmo` — PASS.
2. `opam exec --switch=5.5.1 -- scripts/dune-local.sh build scripts/benchmarks/keeper-task-query-replay/probe.exe` and `_build/default/scripts/benchmarks/keeper-task-query-replay/probe.exe RAW_TRACE.jsonl` — production-module replay. The Dune harness copies the production query/cursor sources and links the production domain serializer, without replacing dependencies with stubs. Assertions check exact-ID selection, combined Goal/performer/text predicates, rejected malformed inputs, cursor filter mismatch, and completion notes retained only in full output.
3. Full focused endpoint executable build failed on unchanged base `75d3e6716d`: `lane_addon_subscription.For_testing.handle` has an interface label-order mismatch. Tracked in [#40650](https://github.com/jeong-sik/masc/issues/40650). The new endpoint tests compile but have NOT executed; they cover complete page traversal, 101 completed-task rows, selection and Goal-registry corruption.
4. Independent source reviews: PASS for `b131d2bdb0ee0038503821d1c3208a420d10da67` (payload change) and `7004bd73d830350df97fe1e4e099518d76853379` (query delta). Source review is not runtime proof or a GitHub approval.

## 불확실성 (Uncertainty)

- 미확인 항목: deployed Keeper behavior, end-to-end test execution, model A/B
- 영향: measured bytes do not establish task quality, latency or billing improvement
- 추가 확인 필요: repair #40650, execute endpoint tests, then compare live task outcomes

No deployment, live Keeper turn, model A/B experiment, token-cost reduction,
or end-to-end speedup is claimed. The replay retains the endpoint's production
query/serialization code but does not exercise the endpoint's I/O assembly;
the compiled endpoint tests still need the base build repaired. There is no
new updated-at filter: task creation/state-transition timestamps would not
prove the last edit time. Artifact extraction and TUI outcome correlation
were diagnosed earlier but are not implemented by these two PRs.

## 적용범위 (Scope)

- 영향 받는 영역: task query and compact task response
- 제약/배제: no runtime config change or deployment
- 롤백 조건: missing task rows or incorrect conditional reads; revert stack top first

Bottom PR [#40654](https://github.com/jeong-sik/masc/pull/40654) changes compact
payloads and the first-page discovery window; stacked PR
[#40655](https://github.com/jeong-sik/masc/pull/40655) adds explicit selection.
Existing lifecycle defaults remain: `include_done=true` includes completed
Tasks; `status=cancelled` is needed for cancelled Tasks. Goal read errors are
errors, not empty selections. No runtime files or scheduler policy changed.

Rollback: revert the query PR before its payload parent. New opaque cursors
are tied to the selection contract; restart pagination after a version change.

## Design references

- https://www.anthropic.com/engineering/writing-tools-for-agents (2025-09-11)
- https://www.anthropic.com/engineering/code-execution-with-mcp (2025-11-04)

Official engineering sources read 2026-10-02 KST. Used for response sizing,
explicit filters, and processing intermediate results outside model context.
Their reported savings are not used as MASC performance estimates.
