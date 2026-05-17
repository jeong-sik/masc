---
rfc: "0110"
title: "Tool-pair atomicity at write boundary — sunset compaction repair fabrication"
status: Draft
created: 2026-05-17
updated: 2026-05-17
author: vincent
supersedes: []
superseded_by: null
related: ["0042", "0077", "0088"]
implementation_prs: []
---

# RFC-0110: Tool-pair atomicity at write boundary — sunset compaction repair fabrication

## §1 Problem (caller-context)

`lib/keeper/keeper_context_core.ml:499-643` 의 `repair_dangling_tool_use_messages_with_stats` 와 `repair_orphan_tool_result_messages_with_stats` 는 메시지 히스토리에서 짝-잃은 `ToolUse` 와 `ToolResult` block 을 plain-text 로 **downgrade** 한다. PR #15888 `fix(compaction): tag pair-repair fabricated messages` 가 그 결과물에 `was_fabricated=true` 와 `fabrication_source="tool_pair_repair"` 메타데이터를 부착했다. 즉, **시스템이 이미 자기 데이터의 fabrication 비율을 측정해야 한다고 인지** 했다.

호출 사이트 4개 (`keeper_post_turn.ml:576,919` + `keeper_rollover.ml:266` + 명시적 opt-out `:783,838,867,196`):

```
post_turn:576  repair_orphan_tool_result_messages    # 자동 호출 (default)
post_turn:783  sanitize_oas_checkpoint ~repair_orphans:false   # 명시적 opt-out
post_turn:838  ~repair_orphans:false                            # 명시적 opt-out
post_turn:867  ~repair_orphans:false                            # 명시적 opt-out
post_turn:919  repair_orphan_tool_result_messages    # 자동 호출
rollover:196   ~repair_orphans:false                 # 명시적 opt-out
rollover:266   repair_orphan_tool_result_messages    # 자동 호출
```

`~repair_orphans:false` opt-out 의 존재 자체가 "repair 는 destructive" 라는 *코드 안의 자백* 이다. 어떤 path 에서는 repair 를 끄고, 어떤 path 에서는 켠다 — 호출자가 각자 판단. SSOT 없음.

### 패턴 분류

CLAUDE.md `software-development.md` 의 워크어라운드 시그니처 §"Repair / Sanitize":

> **Repair / Sanitize**: signals "UTF-8 repair", "JSON normalize on read". Root: Protocol boundary enforce (validate at write, reject on read).

본 케이스는 *Tool-call/tool-result pair atomicity* 를 write boundary 에서 보장하지 못한 결과를 read boundary 에서 sanitize 하는 정확한 사례. Write-time 에 (a) ToolUse 가 emit 되면 짝 ToolResult 가 같은 message 안 또는 다음 N message 안에 무조건 도착하거나, (b) 안 도착하면 ToolUse 자체를 commit 하지 않는 atomicity 가 깨졌다. 그 결과:

- compaction 시점에 dangling/orphan 발견
- repair = plain-text downgrade (fabrication)
- downstream consumer 가 `was_fabricated=true` 로 fabrication 인지

### Why this needs an RFC

1. **재발 메커니즘**: write-side atomicity 없으면 같은 root 가 반복 발생. 새 tool dispatch path 추가 시 (e.g. RFC-0100 streaming) 또 같은 repair 경로 통과.
2. **메트릭 vs fix**: PR #15888 의 `was_fabricated` 메타 + `downgraded_tool_uses`/`downgraded_tool_results` counter 는 **CLAUDE.md "Counter-as-Fix" 시그니처 §1**. visible 하지만 fix 가 아님.
3. **fabrication 책임 분산**: 4 call site 마다 `~repair_orphans` 인자 판단을 caller 에게 떠넘김. atomicity 가 boundary type 에 박혀있지 않음.
4. **RFC-0088 / RFC-0077 / RFC-0042 와 연속**: RFC-0042 closed-sum, RFC-0077 write-side silent failure, RFC-0088 counter-as-fix umbrella — 본 RFC 는 같은 family 의 *tool-pair* surface.

근본 원인: **`Agent_sdk.Types.message` 가 `ToolUse` 와 `ToolResult` 의 짝 atomicity 를 타입으로 표현 안 한다.** ToolUse 도 ToolResult 도 그냥 `content_block` variant 일 뿐, 짝 관계는 *런타임 runtime convention*.

## §2 Approach

3 layer:

**Layer A — Phantom-typed paired ID**

`Tool_call_id.t` 를 phantom-typed 로 분리: `Tool_call_id.pending` (ToolUse 발화 후, 짝 도착 전) vs `Tool_call_id.resolved` (짝 도착 후). Conversation history 는 `Pending_ids: Tool_call_id.pending list` 를 함께 carry — 모든 `pending` 가 resolve 되어야 history 가 *closed* 상태로 persist.

```ocaml
module Tool_call_id : sig
  type 'phase t  (* phantom *)
  type pending = [ `Pending ]
  type resolved = [ `Resolved ]
  val emit : string -> pending t
  val resolve : pending t -> resolved t
  val to_string : _ t -> string
end
```

**Layer B — Closed history boundary**

`Conversation_history.t` 에 `Closed | Open of { pending : Tool_call_id.pending t list }` constructor 추가. `commit` 함수가 `Closed` history 만 받음. `Open` history 는 in-memory only — disk persist 거부.

```ocaml
val commit : Closed Conversation_history.t -> unit
val close : Open Conversation_history.t -> (Closed Conversation_history.t, Open Conversation_history.t * Tool_call_id.pending t list) Result.t
```

`close` 가 `Error (still_open, pending_ids)` 반환하면 caller 가 *fabrication* 대신 *backpressure* 또는 *abort* 선택.

**Layer C — Repair sunset**

`repair_dangling_tool_use_messages` 와 `repair_orphan_tool_result_messages` 는 *legacy-history adapter* 로 좁힘. 본 RFC merge 후 새 코드 작성은 `commit (close history)` 만 사용. legacy adapter 는 P3 에서 `[@@deprecated]` 부착, P4 에서 hit counter 0 확인 후 제거.

## §3 Phasing

| Phase | Deliverable | Acceptance |
|---|---|---|
| P1 (this PR) | RFC body | Draft → main |
| P2 | `Tool_call_id` phantom type + `Conversation_history` Open/Closed variant | Type 만, 호출 자리 없음. `dune build @check` PASS. |
| P3 | `commit` boundary 강제 — 4 callsite (`keeper_post_turn:576,919` + `keeper_rollover:266`) 가 `close` 후 `commit`. fabrication 발생 시 `Result.Error` 반환. | Compaction PBT (`test_pbt_context_overflow.ml`) 가 fabricated path 시도 시 PASS, no-fabrication path 시도 시 PASS. |
| P4 | repair_dangling/repair_orphan `[@@deprecated]` + telemetry 4주 → fabrication 0 확인 | `was_fabricated=true` 메타 4주 카운트 = 0 |
| P5 | repair function 제거 + opt-out flag `~repair_orphans` 제거 | LoC −150 추정 |

P3 가 핵심 — fabrication 대신 Result.Error 반환 시 caller (post_turn / rollover) 가 어떤 정책 (retry / abort / human-attention) 을 취할지가 follow-up 결정. RFC-0088 의 `Result.t propagation` 패턴과 정렬.

## §4 Open questions

1. **Q1**: P3 에서 fabrication 대신 Result.Error 반환 시 default policy? (a) retry — tool dispatch 재실행, (b) abort — turn drop, (c) human-attention — keeper pause. **잠정**: (b) abort. (a) 는 tool side-effect 중복 위험, (c) 는 사용자 개입 비용. abort 시 telemetry `keeper_turn_aborted_pair_atomicity_total` counter.

2. **Q2**: legacy history (이미 disk 에 fabricated metadata 박힌 메시지) 처리? P5 에서 한번에 sweep + downgrade tag 제거 vs 영구 leave. **잠정**: 영구 leave (history 는 immutable, 단지 새 코드가 fabricate 안할 뿐).

3. **Q3**: `~repair_orphans:false` opt-out call site (4 개) 가 이미 알고 abort 처리 중인지 verify. 만약 그렇다면 P3 이전에도 `~repair_orphans:false` 기본값 전환 가능. **잠정**: P2 사전 작업으로 4 callsite audit.

## §5 Non-goals

- **메시지 외 source 의 fabrication** (예: cascade transport, oas event) — 본 RFC 는 `Agent_sdk.Types.message` 안의 tool-pair 만.
- **fabrication 메타데이터 schema 변경** — PR #15888 의 `was_fabricated` / `fabrication_source` / `masc.tool_pair_repair` 메타 schema 는 유지. P5 에서 신규 fabrication 만 0 으로.
- **Provider-side tool API 변경** — Anthropic / OpenAI / GLM 의 tool API contract 는 unchanged. atomicity 는 *내부 history 모델* 의 invariant.

## §6 Risk & rollback

- **Risk 1**: P3 에서 turn abort 가 사용자 체감 fail 증가. → telemetry 4주 monitoring, abort 비율 > 1% 시 P3 rollback + Q1 의 (a) retry 정책 재검토.
- **Risk 2**: phantom type 도입이 컴파일 break 광범위. → P2 는 *type 만 추가*, 호출 자리 변경 zero. P3 가 부분 변경.
- **Risk 3**: legacy adapter 제거 (P5) 가 옛 disk-state load 시 break. → P5 전 1-week soak 에서 disk replay test.

Rollback: P3/P4/P5 각 PR 별 single-feature commit, revert 1 commit 으로 가능. P2 type 추가는 backwards-compat.

## §7 Acceptance

- [ ] P1: RFC body merge.
- [ ] P2: `Tool_call_id.t` phantom + `Conversation_history` Open/Closed variant 정의, 호출 자리 0.
- [ ] P3: 4 callsite (post_turn:576/919, rollover:266, + 1 of the `:false` opt-outs) 가 `close+commit` 패턴 채택. fabrication count drop 측정 가능.
- [ ] P4: `[@@deprecated]` 부착 후 4주간 `was_fabricated=true` 신규 emit 0.
- [ ] P5: legacy repair function + `~repair_orphans` flag 삭제. LoC −150.

## §8 Number allocation note

Allocated as RFC-0110 (not 0108) due to ledger collision: parallel inflight PRs #15901 (RFC-0108 atomic JSONL append — superseded-by-merge by RFC-0107 #15906 but still open) and #15921 (RFC-0108 PR safety gates — same author, this iteration). Ledger advanced 0108 → 0111 (skip 0109 also taken by inflight #15902 CDAL × GOAL). Per README policy "skipped numbers reserved against reuse — ledger is monotonic."
