---
rfc: "0126"
title: "Silent fallback discipline (typed split for option/result wildcard arms)"
status: Draft
created: 2026-05-17
updated: 2026-05-17
author: vincent
supersedes: []
superseded_by: null
related: ["0106", "0042", "0088"]
implementation_prs: []
---

# RFC-0126 — Silent fallback discipline

## 1. Context

`Float.of_string_opt` / `Yojson.from_string` / `option`-returning IO 를 wildcard `_ -> default` 또는 `Some _ when ... -> value | _ -> default` 패턴으로 받는 코드가 codebase 전반에 누적되어 있다. 이 패턴은 *언제 default 가 트리거되었는지*, *어떤 입력이 fallback 을 유발하는지* 모두 불가시화한다. operator 가 환경변수에 오타를 넣어도 (예: `MASC_KEEPER_LIST_CACHE_TTL_S=5s` 단위 suffix), runtime 은 silently 2.0s default 로 회귀하고 *어디에도 흔적이 남지 않는다*.

### 정량적 신호 (2026-05-17 단일일)

| 측정 | 값 |
|---|---|
| 같은-패턴 silent-path/observability PR 누적 (`.tmp/iteration-backlog.md`) | **33 iter** |
| backlog 내 "silent / visibility / parse-outcome / fallback / counter / swallowed" 키워드 라인 | **49** |
| 패턴 구분 클러스터 | A: wildcard arm split / B: Result.t 도입 / C: JSON parse 분리 / D: Cancelled re-raise (RFC-0106) / E: WARN→counter / F: env-var clamp |
| A+B+C 합산 (이 RFC 범위) | ~25 iter / 일 |

이 양은 **`Workaround Rejection Bar §3 — N-of-M Patch (abstraction 부재 admits)`** 의 정의에 정확히 들어맞는다. 같은 변환을 여러 사이트에서 따로 적용하는 것 자체가 *codemod 부재 + 컴파일 시점 강제 부재* 의 admit. AI 에이전트가 codebase 통계로 학습하므로, 신규 코드도 같은 *wildcard + silent default* 로 작성됨 → spiral.

## 2. Goal

1. **컴파일 시점 강제** — `option` / `(_, _) result` 를 받는 코드가 wildcard arm 으로 default 를 코일하는 패턴을 lint 로 차단. 신규 코드가 *합법 선례* 로 학습되지 않게.
2. **typed split SSOT** — `Some _ when ... -> v | _ -> default` 같은 압축 패턴을 `Some _ -> <reason1> | None -> <reason2>` 의 typed pair 로 풀고, 각 arm 이 closed-vocabulary reason 을 노출.
3. **누적된 ~25 iter 흡수** — 이 RFC 의 Phase 1 migration step 으로 이미 머지/in-flight PR 들을 재구성. 손실 없음.

## 3. Non-goals

- Cancelled-re-raise discipline (RFC-0106 의 영역).
- 외부 surface JSON-RPC error envelope (RFC-0098 의 영역).
- `Yojson.from_string` 같은 string→typed parse 의 외부 input 분류 (RFC-0042 의 영역).

## 4. Anti-pattern definition

다음 시그니처는 본 RFC 가 차단 대상으로 정의한다:

### 4.1 Wildcard fallback in option/result match

```ocaml
(* PROHIBITED *)
match Float.of_string_opt s with
| Some v when v >= 0.0 -> v
| _ -> default
```

위 패턴은 두 silent path 를 *같은 default* 로 압축한다: parse 실패 (`None`), 음수/NaN (`Some _` with guard fail). 운영자는 "왜 default 인지" 알 수 없다.

### 4.2 Sys_error swallow without typed boundary

```ocaml
(* PROHIBITED *)
let foo () =
  try expensive_io () with _ -> default_value
```

`Sys_error`, `End_of_file`, `Eio.Cancel.Cancelled` 등이 *모두 같은 default* 로 압축됨. RFC-0106 와 sibling 영역.

### 4.3 JSON parse drop without classifier

```ocaml
(* PROHIBITED *)
match Yojson.Safe.from_string body with
| exception _ -> drop ()
| json -> handle json
```

JSON syntax error 와 cancellation/IO 가 같은 drop 경로.

## 5. Discipline (mandatory)

### 5.1 Typed split

wildcard arm 은 다음 둘 중 하나로 좁힌다:

```ocaml
(* OPTION A: closed-vocabulary log+counter at each arm *)
match Float.of_string_opt s with
| Some v when v >= 0.0 -> v
| Some _ ->
    Log.X.warn "%s=%S negative or NaN" env trimmed;
    observe ~reason:"negative_or_nan";
    default
| None ->
    Log.X.warn "%s=%S not a float" env trimmed;
    observe ~reason:"invalid_float";
    default
```

```ocaml
(* OPTION B: surface Result.t boundary, caller decides *)
val parse : string -> (float, [`Invalid_float | `Negative_or_nan]) result
```

### 5.2 Exception typed catch

```ocaml
try expensive_io () with
| Sys_error msg ->
    Log.X.warn "io: %s" msg;
    observe ~reason:"sys_error";
    default
(* Cancelled propagates (RFC-0106 discipline) *)
```

### 5.3 Closed-vocabulary label

`observe` 의 reason label 은 *bounded set* 이어야 한다. dynamic Printexc.to_string 을 label 로 직접 쓰지 않는다. cardinality blowup 방지.

## 6. Phase plan

### Phase 0 — Discipline document (this RFC)

이 문서 자체. Draft 머지 후 reviewer/agent 가 *언제 split 이 강제되는지* 참조 가능.

### Phase 1 — Migration canary (already started)

다음 PR 들이 본 RFC 의 Phase 1 canary 로 흡수된다:

| PR | iter | 패턴 | 위치 |
|---|---|---|---|
| [#15954] | 42 | A | `tool_keeper.cache_ttl_seconds` |
| [#15955] | 43 | B | `bash_history.append` (Result.t) |
| [#15956] | 44 | E (gray-zone, monitoring-aggregate) | `keeper_runtime_config.load_and_apply` |

기존 머지된 iter 6/18/19/20/21/22/23/25/28/29/31 등도 retrospective 로 본 RFC §5 와 정합한다.

#### 6.1.a Already-resolved evidence (memory-compacting audit 2026-05-17 01:22 retrospective)

audit doc `.tmp/memory-compacting-analysis.html` 가 작성 시점(01:22) 에 미해결로 표시한 V 라벨 중 다수가 *그 후* 머지된 iter 들로 이미 fix 됨. 2026-05-17 저녁 시점 direct grep 결과:

| V | 위치 | audit 클레임 | 실제 상태 |
|---|---|---|---|
| V02 (CRIT) | `keeper_compact_audit.ml:323-336` | Pending Hashtbl silent overwrite | **FIX** — `Pending.stash` returns prior, `handle_event` line 397-408 emits `Pending_overwrite` counter |
| V03 (HIGH) | `keeper_compact_policy.ml:92-96` | tool_heavy 주석/코드 불일치 | **FIX** — line 152-159 bypass 정합, 주석/코드 align |
| V04 (HIGH) | `keeper_compact_policy.ml:145-154` | record_pre_compact try/catch 외부 | **FIX** — line 244-261 `Cancelled re-raise + warn + None` pattern (RFC-0106 정합) |
| V06 (HIGH) | `memory_jsonl.ml:100-113` | 50MB load_file 일괄 메모리 | **FIX** — `iter_lines` streaming (`input_line` per row, line 231-245) |
| V08 (MED) | `keeper_memory_llm_summary.ml:107-117` | 3-silent timeout/http/empty | **FIX** — `Keeper_memory_llm_summary_outcome.t` typed variant (Timed_out / Ok_summary / Empty_response / Http_error) |
| V11 (MED) | `keeper_post_turn.ml:511` | callback exception swallow | **FIX** — RFC-0106 P0 canary (iter 32+34, `Cancel_safe.observe` 적용) |

→ 6/9 V 라벨이 audit 시점 이후 iter 들로 흡수 완료. memory `feedback_workdir_grep_must_cross_check_origin_main` 정신 = audit doc 직접 grep 검증 의무의 정량 evidence (66.7% stale rate).

#### 6.1.b Phase 1 remaining backlog (audit-derived)

| V | 위치 | 클러스터 매핑 | RFC §5 권고 |
|---|---|---|---|
| V15 (LOW) | `memory_jsonl.ml:69-95 parse_line` | A (wildcard parse drop) + E (warn 있고 counter 부재) | §5.1 OPTION A — closed-vocab `{empty_line / no_key / not_assoc / json_parse_error}` reason label, counter 추가. **iter 48 (PR pending) 흡수.** |
| V16 (LOW) | `memory_jsonl.ml:120-219 long_term_backend` | B (Result.t asymmetry) | **OAS upstream 의존** — `Agent_sdk.Memory.long_term_backend` 타입이 OAS 정의. masc-mcp 단독 fix 불가. OAS-side sibling RFC 후보. |
| V09 (MED) | `keeper_compact_policy.ml compaction_decision` | H (type API drift) — *spiral 외* | RFC sub-issue: `Skipped_no_checkpoint` 를 wrapper variant 로 분리 또는 policy 내부 생성. invasive, 별도 RFC 후보. |

V09 는 본 RFC scope 밖 (silent fallback 아니라 type API drift). 별도 RFC issue 후보.

#### 6.1.b' Audit Phase 0/1 masc-side completeness (iter 49 closure)

`oas-internal-audit.html` 의 C1-C3 label, 그리고 V16, 위 표의 OAS upstream 의존 항목들을 모두 묶으면:

| label | 위치 | masc-mcp Phase 0/1 가능? | upstream block |
|---|---|---|---|
| C1 (pair-repair counter) | masc-side `keeper_compact_audit.ml` | 가능 — iter 24 PR #15792 머지 완료 | — |
| C2 (Event_bus subscribe per-subscriber policy/buffer) | masc-side `agent_sdk_metrics_bridge.ml:58-59` | **불가** | `Agent_sdk.Event_bus.subscribe` 시그니처가 per-subscriber `?policy/?buffer_size` 미노출 |
| C3 (retrieve contract typed) | masc-side `memory_jsonl.ml` 답습 | **불가** | `Agent_sdk.Memory.long_term_backend.retrieve : key → Yojson option` — `Result.t` 도입은 OAS 단에서 |
| V16 (retrieve/query Result.t) | masc-side `memory_jsonl.ml` 답습 | **불가** | C3 와 동일 upstream contract |

→ audit Phase 0/1 의 masc-side fix-able 라벨 (C1, V01-V15, V17) 은 **모두 처리 완료** (또는 §6.1.b 의 V09 같이 별도 RFC 후보). 남은 C2/C3/V16 은 OAS upstream PR + masc-mcp 후속 어댑테이션 2-step 시퀀스 필요. OAS-side sibling RFC 권고 (제목 예시: "RFC-OAS-XYZ: Event_bus per-subscriber backpressure override + Memory.long_term_backend Result.t boundary").

#### 6.1.c Non-spiral observability extension (cluster G)

| PR | iter | 패턴 | 위치 |
|---|---|---|---|
| (iter 46) | 46 | G (fiber contention) | `File_lock_eio.atomic_update*` CAS retries counter |
| (iter 48) | 48 | A∩E (RFC-0110 §5.1 A canary) | `Memory_jsonl.parse_line` 3 drop site typed reason counter |

cluster G 는 본 RFC §6.1 클러스터 (A-F) 의 *외부* — 기존 silent path 의 가시화가 아니라 *처음부터 가시화 없던 차원* 의 첫 surface 추가. spiral 누적 아님.

iter 48 은 cluster A (typed split) + E (WARN+counter mirror) 조합이지만 §6.1.b 명시 backlog 의 *RFC 완수 의무* 이므로 spiral 외 분류.

### Phase 2 — ppxlib AST lint

RFC-0106 §3.3 의 Phase 2 (`scripts/lint-cancel-guard.sh` ppxlib 확장) 와 sibling. AST visitor 가 다음을 검출:

- `Pexp_match` 내 `Ppat_construct (Some/None)` + `Ppat_any` 의 `_ -> <not-helper>` 패턴
- `try` 의 `with _ ->` / `with exn ->` catch-all (`Cancel_safe.protect` 호출 아님)

검출 시 lint 실패. 기존 코드는 `[@@silent_fallback_acknowledged "<RFC link>"]` annotation 으로 deferred.

### Phase 3 — codemod for residual sites

`rg -n "| _ -> .*default"` 등 으로 sweep, 자동 patch 후 사람 review.

### Phase 4 — Lint hard-fail in CI

`[@@silent_fallback_acknowledged ...]` 잔여 카운트 0 도달 시 lint 가 error level 로 승격.

## 7. Anti-pattern self-check (this RFC body)

| § | 확인 | 결과 |
|---|---|---|
| §1 (telemetry-as-fix) | RFC body 만 추가, 코드 변경 없음. Phase 1 canary PR 들이 *진짜 fix* (typed split) 임 | PASS |
| §3 (N-of-M) | RFC 자체가 N-of-M admit 을 *흡수* 하기 위한 abstraction. Phase 2/3 codemod 가 N 사이트 자동 처리 | PASS |
| §4 (catch-all 추가) | wildcard arm 을 *제거* 하는 게 핵심. catch-all 추가 아님 | PASS |
| §7 (codemod 누락) | Phase 3 explicit codemod step | PASS |

## 8. Open questions

1. `[@@silent_fallback_acknowledged]` attribute 가 RFC-0106 의 `[@@cancel_safe_acknowledged]` 와 통합되어야 하는가? — 두 RFC 가 같은 ppxlib visitor 를 공유할 수 있다.
2. Phase 2 lint 가 false-positive 가 많을 가능성 (예: `match ... with | _ -> ()` 가 legit `()` 사이드 이펙트 패턴) — `effects-only context` heuristic 필요.
3. iter 35/36/37/44 같은 *기존 WARN + 신규 counter* (E 클러스터) 가 본 RFC 의 §5.1 OPTION A 와 별개로 다뤄져야 하는가? — 별 RFC ("Observability surface decoupling — log vs counter") 로 분리 검토.

## 9. References

- RFC-0042 — Closed sum type for completion contract violations (sibling — string classifier 영역)
- RFC-0088 — Counter-as-Fix umbrella (sibling — workaround §1 영역)
- RFC-0106 — Cancel-safe try-with discipline (sibling — same ppxlib infrastructure)
- `~/me/instructions/software-development.md §AI 코드 생성 안티패턴` — anti-pattern §1 (하드코딩 산포), §2 (unknown → permissive default)
- `.tmp/iteration-backlog.md` — 33 iter / 단일일 정량 evidence

[#15954]: https://github.com/jeong-sik/masc-mcp/pull/15954
[#15955]: https://github.com/jeong-sik/masc-mcp/pull/15955
[#15956]: https://github.com/jeong-sik/masc-mcp/pull/15956
