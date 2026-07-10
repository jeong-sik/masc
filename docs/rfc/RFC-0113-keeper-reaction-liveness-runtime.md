---
rfc: "0113"
title: "KeeperReactionLiveness L1–L5 runtime — phased OCaml mirror of TLA+ design ground"
status: Implemented
created: 2026-05-17
updated: 2026-05-22
author: vincent
supersedes: []
superseded_by: null
related: ["0002", "0003", "0020", "0042", "0072"]
implementation_prs: [15937]
---

# RFC-0113: KeeperReactionLiveness L1–L5 runtime — phased OCaml mirror of TLA+ design ground

## §1 Problem (caller-context)

`specs/keeper-state-machine/KeeperReactionLiveness.tla` (이하 KRL) 가 5 개 liveness 보장 (L1–L5) 을 *design ground* 로 정의함. 본문 첫 단락 (line 11-37) 가 명시:

> This spec is a DESIGN GROUND, not a description of running code.
> iter 58 #14898 audit confirmed via rg across lib/keeper/*.ml that the KRL reaction/receipt FSM (L1-L5 leads-to claims) has NO matching runtime: verifier_reaction, receipt_issued, task_state are truly absent everywhere.

`docs/tla-audit/krl-l1-reaction-spec-implementation-gap-2026-05-12.md` 의 gap matrix:

| 인용 entry point | 실재 여부 | 비고 |
|---|---|---|
| `lib/keeper/keeper_event_queue.ml` | ✅ 91 LOC | stimulus queue plumbing only, no receipt FSM |
| `lib/keeper/keeper_unified_turn.ml` | ✅ 3037 LOC | terminal_reason machinery, no verification_state/goal_phase/task_state |
| `lib/keeper/goal_store.ml` | ❌ MISSING | `lib/goal/goal_store.{ml,mli}` exists at different path |
| `lib/keeper/keeper_task_dispatch.ml` | ❌ MISSING | no file |
| `lib/keeper/keeper_board_observer.ml` | ❌ MISSING | no file |

**결과**: 5 concept (stimulus / verification / goal_phase / task_state / board_cursor) 중 *어떤 것도 spec 의 per-stimulus receipt FSM 형태로 implement 되어 있지 않다*. 부분 데이터 형태만 인접 모듈에 산재.

### 진행중 implementation (RFC 없이)

최근 4 PR 이 KRL L1 (`BoardEnqueueLeadsToReceipt`) 부분 구현을 시작:

| PR | Module | 변경 |
|---|---|---|
| #15783 | `keeper_reaction_ledger.ml(i)` ADD | 285 LoC 새 모듈, JSONL durable receipt store |
| #15821 | `keeper_reaction_ledger` | surface reaction ledger health |
| #15889 | `keeper_reaction_ledger` + `board_dispatch` | sweep cursor-covered reaction stimuli (126 LoC 증가) |
| #15905 | dashboard normalizers | surface reaction ledger cursor sweeps UI |

총 ~500 LoC across 4 PRs in 4 days, *RFC 부재 상태로 진행*.

### Anti-pattern 시그니처 잠재

`lib/keeper/keeper_reaction_ledger.mli` 의 typed variant:

```ocaml
type stimulus_kind =
  | Board_signal
  | Bootstrap
  | Alive_but_stuck_recovery
  | Unknown of string                  (* (1) *)

type reaction_kind =
  | Turn_started
  | Execution_receipt
  | Terminal_reason
  | Cursor_ack
  | Operator_escalation
  | Unknown_reaction of string         (* (2) *)
```

(1) 과 (2) 의 `Unknown of string` catch-all 은 **AGENT-LLM-A.md `software-development.md` §"AI 코드 생성 안티패턴" §2 "Unknown → Permissive Default"** 시그니처:

> 알 수 없는 입력을 에러 대신 "편리한 기본값" 으로 매핑.
> **규칙**: unknown 입력은 `Error`/`None`/`Unknown` 변형으로 처리. `option`을 `Some default` 로 압축하지 않는다.

`Unknown of string` 자체는 위 룰의 "Unknown variant 처리" 형태지만, *어떤 새 case 가 들어와도 컴파일러가 누락 감지 안함* — RFC-0042 close-sum 정신 위배. 새 stimulus / reaction kind 가 spec 에 추가될 때마다 `Unknown` 으로 fall through.

### Why this needs an RFC

1. **5 PR 진행 후 RFC 작성 — 정확한 *retroactive umbrella* 시점**: AGENT-LLM-A.md `pre_workflow.md` §"진입 장벽" — "복잡한 비즈니스 로직: 상태 다이어그램/의사코드/테스트 케이스 먼저 작성".
2. **TLA+ spec 과 runtime 의 정합성 검증 부재**: 현재 L1 partial 구현이 spec 의 L1 invariant 와 자동 cross-check 안됨. spec 이 update 되어도 runtime 가 catch 안함.
3. **MASC task-134 가 tracking owner** 인데 RFC 없음 — task 가 *what to build* 만, *why this shape* 안 다룸.
4. **5 mirror entry point 중 3 missing** — module 신설 순서를 RFC 가 commit 해야 N-of-M 막음 (각 entry point 가 별도 PR 로 hand-build 되면 catch-all 누적).

근본 원인: **TLA+ spec → OCaml runtime 의 *bidirectional contract* 를 RFC 가 박혀있지 않음**. AGENT-LLM-A.md `software-development.md` §"TLA+ Bug Model" 패턴이 spec invariant 와 buggy.cfg 양쪽 통과를 요구하는데, 본 spec 은 그 패턴 (KRL + KRL-buggy.cfg) 을 *이미 갖춤* — 다만 runtime side 가 비어있음.

## §2 Approach

3 layer:

**Layer A — Runtime contract module (`lib/keeper/keeper_reaction_contract.ml(i)`)**

L1–L5 각각을 typed invariant 함수로 표현:

```ocaml
module Keeper_reaction_contract : sig
  (** L1: A board/event stimulus must produce explicit receipt OR typed
      terminal reason. *)
  val verify_l1_board_enqueue_leads_to_receipt :
    stimulus_id:string -> base_path:string -> keeper_name:string ->
    (Receipt_or_terminal.t, [ `Pending of duration | `Silent_drop ]) Result.t

  (** L2: verification request → verifier reaction OR timeout-escalation. *)
  val verify_l2_verification_leads_to_reaction :
    verification_id:string -> ... -> ... Result.t

  (* L3, L4, L5 similarly. *)
end
```

이 모듈은 *spec invariant 의 runtime test point*. dashboard / janitor / replay tooling 이 호출해 spec 정합성 확인.

**Layer B — Mirror module skeletons**

KRL preamble 의 missing 3 entry point 를 typed skeleton 으로 생성:

- `lib/keeper/keeper_task_dispatch.ml` — task transition FSM (L4 mirror)
- `lib/keeper/keeper_board_observer.ml` — board cursor + ack FSM (L5 mirror)
- `lib/goal/goal_store.ml` (cited path 정정 또는 alias) — goal phase FSM (L3 mirror)

각 skeleton 은 spec 의 state machine 을 closed sum 으로 1:1 mirror. 처음에는 *plumbing-only* — production 호출자 없음. P3 부터 wiring.

**Layer C — Catch-all sunset**

`stimulus_kind.Unknown of string` 과 `reaction_kind.Unknown_reaction of string` 제거. P2 에서 KRL spec 의 가능한 모든 case 를 closed sum 으로 enumerate. 새 case 추가 시 spec PR + RFC update + runtime PR 가 같은 sprint.

## §3 Phasing

| Phase | Deliverable | Acceptance |
|---|---|---|
| P1 (this PR) | RFC body | Draft → main |
| P2 | `Keeper_reaction_contract.t` interface + L1 verifier 함수 + 3 unit test (board enqueue → receipt success / terminal_reason success / silent_drop fail) | dune build PASS, alcotest PASS |
| P3 | L1 wiring: `keeper_reaction_ledger` 가 L1 invariant 만족 확인 후 commit. Silent drop 시 `Result.Error \`Silent_drop` → operator-visible escalation. | PBT (`test_pbt_l1_board_receipt.ml`) PASS both clean + buggy paths. |
| P4 | L2/L3/L4/L5 verifier + 3 missing module skeleton (typed plumbing). | KRL.tla / KRL-buggy.tla TLC PASS, runtime cross-check tool 통과. |
| P5 | `Unknown of string` / `Unknown_reaction of string` 제거. KRL spec 의 closed sum 과 1:1 정합. | `rg "Unknown of string" lib/keeper/keeper_reaction_ledger" = 0` |
| P6 | Dashboard 가 L1-L5 invariant 위반 시 alert + operator action item 표시 | Dashboard PBT: L4 violation 시 task action-item row 표시 |

P3 가 핵심 — 첫 L 의 spec 정합성 보장. P6 는 L1-L5 위반이 *operator-visible* 됨을 보장 (silent drop 차단).

## §4 Open questions

1. **Q1**: L1–L5 의 timeout 정의가 spec 에 *unbounded eventually* 으로만 표현됨. Runtime 에서는 어떤 cap 사용? **잠정**: P3 의 L1 wiring 에서 `MASC_KRL_L1_TIMEOUT_SEC` env (default 300 = 5 min) — *Cap 시그니처 잠재* 지만 spec 에 명시되지 않은 boundary 가 reality 에 필요. Timeout 의미와 owner를 별도 follow-up에서 분리한다.

2. **Q2**: spec citation 의 missing 3 path (`lib/keeper/goal_store.ml` 등) 정정 vs alias? `lib/goal/goal_store.ml` 가 실재 — spec 본문 수정 가능. **잠정**: spec 본문 수정 — `lib/keeper/` → `lib/goal/` (P4 의 spec update commit 으로).

3. **Q3**: `Operator_escalation` reaction_kind 가 L1-L5 모두 의 "escape hatch" 인데, 어떤 *concrete operator-visible 표현* 으로? dashboard alert + telemetry counter? **잠정**: P6 의 dashboard work 에서 정의. Slack 통합은 별도.

4. **Q4**: `keeper_reaction_ledger` 의 JSONL store schema 가 future-proof 인지? P5 의 `Unknown` 제거가 schema migration 필요? **잠정**: JSONL row 에 `record_kind` + `kind` 두 필드 모두 string — version 1 만 유지, schema migration RFC 별도.

## §5 Non-goals

- **새 liveness claim 추가** (L6+) — 본 RFC 는 L1-L5 spec 의 *runtime 거울 만들기*. 새 claim 은 spec PR 가 선행.
- **KRL spec 외 다른 spec** (KAL/KTC/KAQ/KSM 등) 의 runtime mirror — 별도 RFC.
- **Verifier keeper 의 verification 정책** (어떤 task 를 어떤 keeper 가 verify) — 본 RFC 는 L2 의 *reaction 발생* 만 보장, *누가 react 하는지* 의 policy 는 별도.

## §6 Risk & rollback

- **Risk 1**: TLA+ spec 과 OCaml closed-sum 의 *drift* — spec update 시 runtime 자동 catch 없음. → P4 의 dune build 에 spec parser + `Keeper_reaction_contract` 모듈 enumerate 비교 lint 추가.
- **Risk 2**: L1-L5 verifier 가 *false positive* (스펙 만족 케이스를 violation 보고) → false-positive rate 1%+ 시 P3 rollback + spec 본문 invariant 재정의.
- **Risk 3**: P5 의 `Unknown` 제거가 *legacy disk JSONL row* 와 type mismatch — old row 의 `kind` field 가 새 closed sum 에 없는 string. → P5 의 yojson decoder 가 unknown string 만나면 *runtime warning + skip row* (RFC-0098 deprecated path label 차용).
- **Risk 4**: 3 missing module 신설 (P4) 이 cycle dependency 유발 — `keeper_task_dispatch`, `keeper_board_observer`, `goal_store` 가 keeper 와 goal 간 양방향 참조 가능. → P4 의 첫 commit 이 dependency graph 분석, 필요 시 `_intf.ml` interface module + dependency inversion.

Rollback: 각 Phase 별 PR. P3 wiring revert → P2 typed API 만 남음 (해롭지 않음). P5 `Unknown` 제거 revert → P2-P4 무영향.

## §7 Acceptance

- [ ] P1: RFC body merge.
- [ ] P2: `Keeper_reaction_contract.t` interface + L1 verifier + 3 unit test PASS.
- [ ] P3: L1 wiring. `keeper_reaction_ledger` 의 silent drop 0 (PBT PASS).
- [ ] P4: L2-L5 verifier + 3 missing module skeleton 추가. KRL TLC + KRL-buggy TLC PASS.
- [ ] P5: `Unknown of string` / `Unknown_reaction of string` 제거. Closed sum 1:1 정합.
- [ ] P6: Dashboard L1-L5 violation 표시 + telemetry counter.

## §8 Number allocation note

Allocated as RFC-0113. Ledger advanced 0109 → 0114 (skip 0109/0110/0111/0112 due to inflight #15902 RFC-0109 CDAL × GOAL + #15924 RFC-0110 tool-pair atomicity (iter-2) + #15927 RFC-0111 goal mint atomicity (iter-3) + #15933 RFC-0112 typed JSON parse boundary (iter-4)). Per README policy "skipped numbers reserved against reuse — ledger is monotonic."
