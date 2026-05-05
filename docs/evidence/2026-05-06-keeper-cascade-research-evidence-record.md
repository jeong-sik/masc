# Evidence Record — Keeper Cascade + Agent Architecture Reports

## 공통 헤더

- 날짜(ISO8601): `2026-05-06T01:12:41+09:00`
- 작성자: Codex for jeong-sik
- 결정 ID: `keeper-cascade-research-reality-check-2026-05-06`
- 적용 대상: `docs/audit/2026-05-06-keeper-cascade-research-reality-check.md`
- 결정 상태: 확정 (reports accepted as proposals; stale/policy-invalid items filtered)

## 근거 (Evidence)

- 항목: Keeper cascade completion and agent architecture reports are planning proposals, not current implementation truth.
- 출처: `/Users/dancer/Downloads/keeper_cascade_completion.agent.final.md`; `/Users/dancer/Downloads/agent_architecture_research_report.md`; `gh issue view`; `gh pr view`; direct repo scans at HEAD `1c9350f540`
- 확인일시: `2026-05-06T01:12:41+09:00`
- 신뢰도: High for local file/repo/GitHub state; Low for unrefreshed external-tool claims inside the 2025-06 research report
- 제한조건: External service claims were not refreshed from official docs; Qdrant recommendations are rejected by workspace policy.

| 항목 | 출처 (파일:줄 또는 명령) | 확인일시 | 신뢰도 | 비고 |
|---|---|---|---|---|
| Source report top 5 critical gaps | `/Users/dancer/Downloads/keeper_cascade_completion.agent.final.md:11-17` | 2026-05-06T01:12:41+09:00 | High | 직접 파일 read |
| Source report 22-week phase plan | `/Users/dancer/Downloads/keeper_cascade_completion.agent.final.md:23-30` | 2026-05-06T01:12:41+09:00 | High | 직접 파일 read |
| Source report P0/P1 seven-gap table | `/Users/dancer/Downloads/keeper_cascade_completion.agent.final.md:172-180` | 2026-05-06T01:12:41+09:00 | High | 직접 파일 read |
| Source report critical path | `/Users/dancer/Downloads/keeper_cascade_completion.agent.final.md:190-194` | 2026-05-06T01:12:41+09:00 | High | 직접 파일 read |
| Source report final success claim | `/Users/dancer/Downloads/keeper_cascade_completion.agent.final.md:917-926` | 2026-05-06T01:12:41+09:00 | High | 직접 파일 read |
| Research report date and topics | `/Users/dancer/Downloads/agent_architecture_research_report.md:1-4` | 2026-05-06T01:12:41+09:00 | High | 직접 파일 read |
| Research report concrete proposals | `/Users/dancer/Downloads/agent_architecture_research_report.md:26-31,52-57,80-85,108-114,126-130` | 2026-05-06T01:12:41+09:00 | High | 직접 파일 read |
| Qdrant recommendation exists in supplied reports | `rg -n "Qdrant\|qdrant" /Users/dancer/Downloads/*.md /Users/dancer/me/AGENTS.md docs/design/open-ended-generalist-agent-rfc.md` | 2026-05-06T01:12:41+09:00 | High | Report recommends Qdrant; repo/workspace policy rejects it |
| Workspace Qdrant retirement policy | `/Users/dancer/me/AGENTS.md:15-17`; `docs/design/open-ended-generalist-agent-rfc.md:200` | 2026-05-06T01:12:41+09:00 | High | Supabase pgvector only |
| Current inspected HEAD | `git rev-parse --short=10 HEAD` -> `1c9350f540`; `git log -1 --format='%H %s'` | 2026-05-06T01:12:41+09:00 | High | Worktree `audit/keeper-cascade-research-0506` |
| Current open issue and PR counts | `gh issue list --state open --limit 300 --json number --jq 'length'` -> 67; `gh pr list --state open --limit 100 --json number --jq 'length'` -> 22 | 2026-05-06T01:12:41+09:00 | High | Live GitHub |
| Seven P0/P1 issues remain open | `gh issue view 12888 11929 11927 9798 10395 10710 10719 --json state,title` | 2026-05-06T01:12:41+09:00 | High | Live GitHub |
| Report-cited WIP PRs are closed unmerged | `gh pr view 12543 12542 12474 12486 12520 12521 --json state,mergedAt,title` | 2026-05-06T01:12:41+09:00 | High | Live GitHub |
| #12888 formal/runtime slices merged | `gh pr view 13288 13299 --json state,mergedAt,title` | 2026-05-06T01:12:41+09:00 | High | Live GitHub |
| #12888 remaining acceptance evidence | `gh issue view 12888 --json comments` | 2026-05-06T01:12:41+09:00 | High | Issue owner comment lists live reproducer and latency evidence |
| Current TLA+ inventory | `find specs -name '*.tla'` -> 90 files | 2026-05-06T01:12:41+09:00 | High | Direct repo scan |
| `KeeperTurnSlot` and `CascadeResolver` specs exist | `ls specs/boundary/*CascadeResolver* specs/keeper-state-machine/*KeeperTurnSlot*` | 2026-05-06T01:12:41+09:00 | High | Direct repo scan |
| TLA check wires both specs | `rg -n "KeeperTurnSlot|CascadeResolver" scripts/tla-check.sh` | 2026-05-06T01:12:41+09:00 | High | Direct repo scan |
| #12888 evidence harness added | `scripts/keeper-turn-slot-evidence.sh` reads active keeper decision JSONL and emits slot wait, release phase, and normal latency status | 2026-05-06T01:19:58+09:00 | High | Does not force the live 174s reproducer |
| #12888 live decision-log evidence still incomplete | `scripts/keeper-turn-slot-evidence.sh --base-path /Users/dancer/me --window-min 1440 --min-normal-samples 1` -> recent keeper rows have normal latency samples but no `slot_release_at_phase` rows | 2026-05-06T01:19:58+09:00 | High | Confirms issue should remain open until forced retry evidence is captured |
| Live MASC runtime health | `curl -sS http://127.0.0.1:8935/health` -> commit `1feadb3c2d`, ready, 17 keepers, config error counts 0 | 2026-05-06T01:12:41+09:00 | Medium | Live process was behind inspected HEAD; not used as code-completion proof |

## 검증 (Verification)

- 1차: supplied report files were read directly with `sed`, `nl`, `rg`, and `wc -l`.
- 2차: current repo state was measured from a dedicated worktree at `1c9350f540`.
- 3차: current GitHub issue/PR states were fetched with `gh issue view`, `gh issue list`, `gh pr view`, and `gh pr list`.
- 4차: #12888 evidence harness was added, passed `bash -n`, and reported `INSUFFICIENT:no_slot_release_phase` against current live decision logs.
- 재현 결과: success for report-to-current-state audit. No implementation claim was accepted from the reports without current repo/GitHub evidence.

## 불확실성 (Uncertainty)

- 미확인 항목: Current official docs for LiteLLM, Temporal, Mem0/Letta, OpenRouter, RouteLLM, LangGraph, and related external systems.
- 영향: External integration choices could be outdated, costly, or incompatible if implemented from the supplied reports alone.
- 추가 확인 필요: Before any external integration PR, refresh official docs and create a separate evidence record for that exact tool/version/API.

- External tool claims in the 2025-06 research report were not refreshed from official docs. They are not used as implementation authority.
- #12888 remains open because the live forced-timeout reproducer and p50/p99 normal-turn regression evidence were not run in this audit.
- Live runtime was healthy but behind the inspected `main` HEAD, so it is useful operational context, not a replacement for repo tests.

## 적용범위 (Scope)

- 영향 받는 영역: keeper cascade reliability planning, TLA+ extension decisions, dashboard performance sequencing, memory architecture recommendations.
- 제약/배제:
  - Does not implement the 22-week roadmap.
  - Does not introduce Qdrant.
  - Does not adopt LiteLLM/Temporal/Mem0 without a fresh official-doc/current-cost verification pass.
- 롤백 조건:
  - If any referenced GitHub issue/PR state changes, rerun the issue/PR commands and update the audit before using it as planning input.
  - If Qdrant policy changes in `/Users/dancer/me/AGENTS.md`, revisit memory recommendations; until then, Supabase pgvector remains the only vector DB target.
