---
rfc: "0123"
title: "Briefing last_event fabrication — option-typed write boundary, sunset read-side sentinel"
status: Draft
created: 2026-05-17
updated: 2026-05-17
author: vincent
supersedes: []
superseded_by: null
related: ["0042", "0077", "0088", "0110"]
implementation_prs: []
---

# RFC-0123: Briefing last_event fabrication — option-typed write boundary, sunset read-side sentinel

## §1 Problem (caller-context)

PR #15777 `feat(briefing-compactors): mark last_event provenance with typed source variant` 가 *fabrication metadata* 를 add. `lib/briefing_compactors/briefing_session_last_event_source.mli`:

```ocaml
type t =
  | Recent_event_latest
      (** [recent_events] was non-empty; [last_event] mirrors the final
          element.  Real data — caller may trust [event_type], [actor],
          [ts_iso] as observed. *)
  | Fabricated_no_recent_events
      (** [recent_events] was empty.  [last_event] is a sentinel record
          with [event_type="none"], [ts_iso="unknown"], [actor="unknown"],
          [task_title="no recent session events"].  Caller must NOT
          treat the fabricated fields as observations. *)
```

PR body 가 명시:

> "compact_session_json silently fabricates a last_event sentinel when recent_events is empty, and downstream consumers cannot distinguish it from a real observation."

PR #15806 follow-up:

> `feat(dashboard-briefing): Prometheus counter for last_event.source observability`

**Counter** 가 `fabricated_no_recent_events` 횟수 측정. 즉, *fabrication 비율을 측정해야 한다* 는 코드-안의-자백 — RFC-0110 (tool-pair atomicity) 의 `was_fabricated=true` 메타 패턴과 *정확히 같은 shape*.

### RFC-0110 와의 평행성

| 측면 | RFC-0110 (tool-pair atomicity) | RFC-0123 (briefing last_event) |
|---|---|---|
| Fabrication 함수 | `repair_dangling_tool_use_messages` | `compact_session_json` synthesises last_event |
| Metadata | `was_fabricated=true; fabrication_source="tool_pair_repair"` | `last_event.source = "fabricated_no_recent_events"` |
| Counter | `downgraded_tool_uses`, `downgraded_tool_results` | `keeper_metrics` Prometheus counter for source |
| Root | `ToolUse / ToolResult` 짝 atomicity 가 type 에 없음 | `last_event` 가 option 이 아닌 *항상 record* — empty case 표현 불가 |

**같은 family**: write-side 가 *empty 또는 invalid* 케이스를 type 으로 거부 못해서 read-side 가 fabricate. metadata + counter 로 *visibility* 만 추가, *fix* 안함.

### Why this needs an RFC

1. **RFC-0110 와 sibling family**: 같은 *Repair / Sanitize* 워크어라운드 시그니처. 통합 spec 으로 *fabrication boundary* 일반화 가능.
2. **PR #15777 의 typed variant 가 *Counter-as-Fix 시그니처***: CLAUDE.md §1 "make data loss visible to operators". 정확히 시그니처.
3. **`last_event` 의 root**: dashboard / operator handoff / debug dump 호출자가 `last_event : record` 가정. *empty session* 도 `last_event : record` 강제 → 강제로 fabricate.
4. **3+ caller 가 fabricated 와 real 분리 처리 필요**: dashboard mission briefing (`lib/dashboard/dashboard_mission_briefing.ml`), keeper metrics. 각 caller 가 `match source` 로 branch — RFC 가 *option type* 으로 단순화 가능.

근본 원인: **`compact_session_json` 의 return shape 가 *non-optional record* — empty case 가 type 으로 표현 안됨.**

## §2 Approach

3 layer:

**Layer A — Option-typed `last_event`**

`compact_session_json` 의 output schema 변경:

```ocaml
(* 현재 *)
type session_summary = {
  last_event : last_event_record;     (* 항상 record, fabricated 가능 *)
  last_event_source : Briefing_session_last_event_source.t;
  recent_events : event list;
  ...
}

(* 제안 *)
type session_summary = {
  last_event : last_event_record option;  (* None = empty, no fabrication *)
  recent_events : event list;
  ...
}
```

JSON 직렬화: `last_event = null` 또는 `last_event: { ... }` (object). `last_event.source` 필드 *제거* — variant 가 *option* 으로 collapsed.

**Layer B — Caller migration**

3 caller (dashboard mission briefing, keeper metrics, debug dump) 가 `match option` 처리:

```ocaml
(* 현재 *)
match summary.last_event_source with
| Recent_event_latest -> render_event summary.last_event
| Fabricated_no_recent_events -> render_empty_state ()

(* 제안 *)
match summary.last_event with
| Some event -> render_event event
| None -> render_empty_state ()
```

Display layer (UI) 가 *원하면* "no recent events" 라는 sentinel 표시 가능 — 다만 *데이터 layer* 는 honest. UI fabrication 과 data fabrication 분리.

**Layer C — Counter sunset**

`keeper_metrics` 의 `last_event_source` Prometheus counter — option 도입 후 *fabricated_no_recent_events* 카운트 = 0 보장. Counter 제거 또는 *Counter-as-Validator* 로 의미 변경 (RFC-0114 family).

## §3 Phasing

| Phase | Deliverable | Acceptance |
|---|---|---|
| P1 (this PR) | RFC body | Draft → main |
| P2 | `compact_session_json` 의 internal API 변경 — `option` 타입 반환. 직렬화 layer 가 `null` 또는 object 선택. JSON schema migration | dune build PASS, alcotest PASS for 5 scenarios (empty / single / multi / null-deserialize / legacy-deserialize) |
| P3 | 3 caller migration (`dashboard_mission_briefing`, keeper metrics, debug dump) — `match option` | PBT: empty session display 가 명시적 "no events" UI (not fabricated record) |
| P4 | JSON wire schema 결정 — null vs absent field. Backwards-compat with legacy reader. | dashboard FE TypeScript schema 갱신 |
| P5 | `last_event.source` 필드 deprecated. Counter `keeper_metrics.last_event_source{kind="fabricated"}` 4주 monitoring → 0 확인 | counter delta = 0 |
| P6 | `Briefing_session_last_event_source` 모듈 제거 + counter 제거 (또는 Counter-as-Validator 로 의미 변경) | LoC −80 추정 |

P2 가 핵심 — schema migration. P5 4주 soak 후 P6 cleanup.

## §4 Open questions

1. **Q1**: JSON wire schema — `last_event: null` vs `last_event: { event_type: null }` vs field absent? **잠정**: `last_event: null` (RFC-OAS-008 deserialize pattern) — caller side optional unwrap 명확.

2. **Q2**: Legacy reader (옛 dashboard FE 또는 외부 tool) 가 `last_event: null` 받으면 깨짐? **잠정**: P4 의 schema migration 가 *legacy fallback shim* 제공 — caller 가 명시적 opt-out 시 legacy record 반환.

3. **Q3**: dashboard FE 의 *display* 가 "no recent events" 표시 — *어떤 UI element*? 빈 panel vs explicit 메시지? **잠정**: P3 의 FE PR 가 명시적 empty-state component.

4. **Q4**: PR #15777 의 typed variant + #15806 의 counter — *이미 commit 됨*. 본 RFC 의 P5/P6 가 그 surface 제거 — *기존 dashboard 의 source filter* 깨뜨림? **잠정**: P4 의 wire migration 4 주 grace + dashboard PR 가 동시 update.

## §5 Non-goals

- **Other briefing surfaces**: `briefing_compactors.ml` 의 *다른* compact 함수 (e.g. compact_task_json) 는 별도 audit. 본 RFC 는 `last_event` 만.
- **JSONL log retention 정책**: RFC-0103 담당, 본 RFC 는 *in-memory schema* 만.
- **Mission briefing 의 *display ordering / grouping* 정책**: 별도 RFC.

## §6 Risk & rollback

- **Risk 1**: `option` 도입이 wire schema break — 외부 도구 (e.g. operator HTTP client) 가 `last_event` 항상 record 가정. → P4 의 4 주 grace + legacy shim.
- **Risk 2**: 3 caller migration 가 *partial* — 일부만 `match option` 처리, 나머지 legacy record. → P3 acceptance 가 *3 모두 migration* 강제.
- **Risk 3**: PR #15806 의 counter 가 *production 에서 0 이상 emit* — empty session 빈도가 미지. → P5 의 4 주 baseline 측정, 0 보장 안 되면 P6 cleanup 보류.
- **Risk 4**: RFC-0110 (tool-pair atomicity) 와 *경쟁 sprint*: 두 RFC 모두 *fabrication boundary* 처리, 같은 caller 변경 가능성. → P3 의 첫 commit 가 RFC-0110 progress 확인 + 동기화.

Rollback: P2 의 internal API 만 변경 시 schema 그대로 유지 가능 (Layer A 만). P3 caller migration 별도 revert 가능. P5 deprecated marker 만 추가, 실제 제거 P6 별도.

## §7 Acceptance

- [ ] P1: RFC body merge.
- [ ] P2: `compact_session_json` option 반환 + 5 scenario test.
- [ ] P3: 3 caller migration. Empty session UI 별도 component.
- [ ] P4: Wire schema migration. Legacy shim 4 주.
- [ ] P5: counter 4 주 monitoring, delta = 0.
- [ ] P6: `Briefing_session_last_event_source` 모듈 제거 + counter cleanup.

## §8 Number allocation note

Allocated as RFC-0123. Ledger advanced 0109 → 0124 (skip 0109-0122 due to inflight #15902 RFC-0109 + #15924/15927/15933/15937/15939/15944/15947/15957/15963/15967/15968/15971/15975 RFC-0110~0122 (iter-2..14 of this loop)). Per README policy "skipped numbers reserved against reuse — ledger is monotonic."
