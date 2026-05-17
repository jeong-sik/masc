---
rfc: "0106"
title: "Cancel-safe try-with discipline (Eio.Cancel.Cancelled propagation)"
status: Draft
created: 2026-05-17
updated: 2026-05-17
author: vincent
supersedes: []
superseded_by: null
related: ["0072", "0097", "0101"]
implementation_prs: []
---

# RFC-0106 — Cancel-safe try-with discipline

## 1. Context

Eio 의 fiber cancellation 은 `Eio.Cancel.Cancelled` 예외로 신호된다. 이 예외가 switch boundary 까지 *반드시* 도달해야 fiber tree 가 올바르게 unwind 한다. 일반 예외 (`exn`) 를 catch-all 로 잡는 `try ... with | exn -> ...` 또는 `try ... with exn -> ...` 패턴은 *Cancelled 도 같이 삼킨다*. masc-mcp 는 Eio.Fiber.fork / Switch.run 으로 fiber tree 를 광범위하게 사용하므로 이 silent swallow 는 *cancellation discipline 위반*이다.

기존 안전망:

- `scripts/lint-cancel-guard.sh` — `with\s+(_|exn)\s+->` regex + 3-line lookbehind 로 *single-arm* `try X with exn -> Y` 형태를 검출한다.
- `cancel-guard-ok` 코멘트 escape hatch.
- `Eio.Cancel.Cancelled _ as e -> raise e` arm 을 catch-all 직전에 명시.

## 2. Problem

iter 32 (PR #15887) 가 드러낸 gap:

- 기존 lint regex 는 `with\s+(_|exn)\s+->` 단일-arm 패턴만 매칭한다.
- *multi-arm* `try X with | A -> a | exn -> b` 형태는 lint 에서 *invisible*.
- `lib/keeper/keeper_post_turn.ml` 의 8 catch-all 중 7 사이트는 *수작업으로* `| Eio.Cancel.Cancelled _ as e -> raise e` 를 paired 했고, 1 사이트 (`on_compaction_started` callback, line 560) 만 unpaired. lint 가 검출하지 못해 우연히 누락된 사례.
- 단순 regex 확장 (`^\s*\|\s*(exn|_)\s+->`) 은 pattern-match arm 과 try-with arm 을 구분 못해 **3751 후보 / 4282 multi-arm catch** false-positive 폭발 (2026-05-17 evidence, `find lib -name '*.ml' | grep -nE '...'` + 3-line lookbehind).
- 결과: catch-all 추가/삭제가 자유로워서 새 코드가 같은 mistake 를 반복할 수 있다. iter 30 (#15883 bg_task drain), iter 32 (#15887 post_turn) 가 같은 root shape 의 *N-of-M* 신호.

## 3. Proposed approach

### 3.1 Helper combinator (SSOT)

`lib/cancel_safe/cancel_safe.{ml,mli}` (또는 기존 `lib/eio_compat/` 하위) 에:

```ocaml
(** Run [f ()] and re-raise [Eio.Cancel.Cancelled] verbatim. Any other
    exception flows to [on_exn] which is intended to record, log, or
    transform — never to be used to *suppress* cancellation. *)
val protect : on_exn:(exn -> 'a) -> (unit -> 'a) -> 'a

(** Like [protect] but [on_exn] returns unit and the outer call yields
    [unit]. Typical use: callback observers. *)
val observe : on_exn:(exn -> unit) -> (unit -> unit) -> unit
```

구현 한 줄 (verifiable):

```ocaml
let protect ~on_exn f =
  try f ()
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn -> on_exn exn
```

이 helper 가 *유일한* catch-all 추가 사이트가 되도록 codebase 전체를 점진적 마이그레이션한다.

### 3.2 ppxlib lint (optional Phase 2)

string regex 가 try-with scope 를 인식 못 하는 근본 한계 → ppxlib `Ast_pattern.pexp_try` 매칭으로 *try-with 노드* 에서만 catch-all 검사. Phase 2 RFC 후속.

### 3.3 Migration plan (phased, 사이트별 PR)

| Phase | 범위 | 산출 |
|---|---|---|
| **P0** (본 RFC body) | helper module 추가 + 1-site canary migration | `Cancel_safe.protect` + 1 사이트 (예: `keeper_post_turn.ml:560`) 사용 |
| **P1** | high-risk subsystem: keeper lifecycle, transport, sandbox, fd accountant | grep-driven PR ladder, 사이트별 typed `on_exn` |
| **P2** | observability / dashboard / governance 콜백 | best-effort 변환 |
| **P3** | ppxlib AST lint | 새 catch-all 추가가 `Cancel_safe.protect` 외부일 때 CI fail |
| **P4** | regex lint deprecation | `scripts/lint-cancel-guard.sh` 를 AST lint 가 superseding |

각 Phase 의 PR 은 *iter 33+* 가 아니라 *별도 RFC implementation PR* 로 묶는다 — atomic root-fix loop 와 분리.

## 4. Non-scope

- *Cancelled 외* 의 typed exception (예: `Eio.Io`, `Unix.Unix_error`) 분류는 본 RFC 범위 밖. 본 RFC 는 *cancellation propagation* 만 다룬다.
- 일반 OCaml `match | exn ->` (try-with 가 아닌 단순 match) 는 본 RFC 무관 — try-with 와 syntactic 구분 가능하다.
- `Fun.protect` finally 도 본 RFC 무관 — 그건 RFC `lint-fun-protect.sh` 가 별도로 다룬다.

## 5. Evidence

- iter 30 (#15883): `lib/process/bg_task.ml` drain 함수에서 `| exception _ -> true` 가 Cancelled 를 삼키던 silent path 를 typed split 으로 해결. 2026-05-17.
- iter 32 (#15887): `lib/keeper/keeper_post_turn.ml:560` `on_compaction_started` callback 의 catch-all 이 Cancelled 미paired 였음. lint 가 검출 못함. 2026-05-17.
- 기존 lint regex (`scripts/lint-cancel-guard.sh:17`): `with\s+(_|exn)\s+->` — multi-arm 형태 미커버.
- 사이트 분포 (2026-05-17 audit, false-positive 포함):
  - bare `| exn ->` 발생: ~50 사이트 (3-line lookbehind paired 검증).
  - multi-arm catch (`| (exn|_) ->`) 전체: 4282 lexical hit, 3751 unpaired (대부분 false positive — pattern-match arm).
- merlin / ppxlib 로 *진짜* try-with scope 만 분리하면 N 은 ~100-200 단위로 축소될 것으로 추정 (확정 측정은 P3 진입 시 수행).

## 6. Open questions

1. **Helper module 이름**: `Cancel_safe`, `Eio_safe_try`, `Try_cancel_safe` 중 선택. SSOT 명명은 ML community convention 따라 `Cancel_safe` 권장.
2. **`on_exn` signature**: `exn -> 'a` 가 default vs `exn -> [`Continue of 'a | `Reraise]` typed control 도입 여부. 후자는 typed but 사용성 저하. P0 는 simple 형태.
3. **Phase 1 우선순위**: keeper lifecycle 먼저 vs transport 먼저. Cancellation 발생 빈도가 *transport* 가 높다는 측정이 필요 — Eio metrics 미정비.
4. **regex lint vs AST lint 동시 운영 기간**: P3 AST lint 가 안정되기 전까지 regex lint 유지. 두 lint 가 conflict 가능성 (예: AST 가 paired 인정, regex 는 미인정) → 사용자 선택.

## 7. Anti-pattern self-check

- [x] **Not telemetry-as-fix** — Cancelled propagation 은 *behaviour 변경* (fiber tree unwind 회복). counter / log 추가가 아니다.
- [x] **Not string classifier** — `Eio.Cancel.Cancelled` typed constructor match, regex 가 아니다.
- [x] **Not N-of-M (within RFC)** — RFC 자체가 *systemic abstraction* 제안. 사이트별 PR ladder 는 RFC Phase 로 escalate, atomic-loop 가 아니라 explicit phased plan.
- [x] **No new `_ -> false` catch-all** — helper 는 `Cancelled` 만 reraise.
- [x] No magic number.
- [x] No test backdoor.
- [x] No N-times-typo fix.

## 8. Related

- **RFC-0072** keeper sub-FSM transitions typed — same shape of "typed split closes silent path" precedent.
- **RFC-0097** sandbox / container reuse — touches Eio fiber tree at sandbox boundary; cancellation discipline 충돌 가능.
- **RFC-0101** FD accountant — recent merge (#15881) wires Sandbox_exec at non-Docker spawn callsites; FD 회수가 cancellation path 의존성 ↑.
- **PR #15883** bg_task drain typed split (iter 30 precedent).
- **PR #15887** keeper_post_turn on_compaction_started Cancelled re-raise (iter 32 precedent, motivating bug).
- **`scripts/lint-cancel-guard.sh`** — current single-arm lint, to be superseded by AST lint in P3.
