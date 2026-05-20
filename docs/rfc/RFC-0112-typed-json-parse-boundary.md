---
rfc: "0112"
title: "Typed JSON parse boundary — eliminate silent-drop fallback across read sites"
status: Draft
created: 2026-05-17
updated: 2026-05-20
author: vincent
supersedes: []
superseded_by: null
related: ["0042", "0077", "0088", "0098"]
implementation_prs: [15933]
---

# RFC-0112: Typed JSON parse boundary — eliminate silent-drop fallback across read sites

## §1 Problem (caller-context)

지난 2 일간 *동일 시그니처* 의 fix PR 4 건이 머지됨:

| PR | Site | 패치 |
|---|---|---|
| #15820 | `mcp-ws` incoming frames | warn+counter on silent JSON parse drop |
| #15840 | `cascade-http-probe` | warn+counter on silent JSON parse drop |
| #15866 | `sidecar.schema_field_types` | warn+counter on silent JSON parse drop |
| #15781 | `keeper-memory-bank` load-history | emit warn+counter on swallowed load-history exceptions |

모두:
1. `Yojson.Safe.from_string` (또는 `from_file`) 호출이 예외 throw 시 `try ... with _ -> default` 패턴으로 *silent* 처리
2. fix = "에러 났다는 사실을 *측정* 하도록 counter + warn log 추가"
3. *어떤 데이터가 어떤 schema mismatch 로 drop 되었는지* 는 여전히 알 수 없음

`rg "Yojson.Safe.from_string|Yojson.Safe.from_file" lib/` 결과: **292 call site / 151 file** (2026-05-17 measured). 4 개 패치는 N-of-M 의 4/292 ≈ 1.4%. 같은 패턴이 새 read site 추가될 때마다 또 fix PR 발생.

### CLAUDE.md 위반 시그니처

본 PR 그룹은 CLAUDE.md `software-development.md` §"워크어라운드 거부 기준" 의 시그니처 §1 "Counter-as-Fix" 와 시그니처 §"Repair / Sanitize" 의 *조합*:

> **Counter-as-Fix**: PR이 silent failure를 *visible*로 만들지만 *fix*하지 않음.
> 신호: "make data loss visible to operators", "count drops"

각 PR body 가 그 신호를 직접 사용 — `warn+counter on silent JSON parse drop` 은 *count drops* 시그니처 자체.

게다가 4 PR 모두 **RFC-0088 (Counter-as-Fix → Result Propagation umbrella) 을 인용 안 함**. umbrella 가 존재하는데 enforce gate 가 없어서 N-of-M 흩뿌림.

### Root cause

`Yojson.Safe.from_string` 와 `from_file` 의 시그니처:

```ocaml
val from_string : string -> t  (* raises Yojson.Json_error on malformed *)
val from_file   : string -> t  (* raises Yojson.Json_error or Sys_error *)
```

즉, *예외 기반 실패 보고*. 호출자가 `try ... with _ -> default` 로 잡으면 silent drop 자동 발생. 타입 시그니처 자체가 *typed fallback* 을 권장 안함.

OCaml 의 type system 으로 강제할 수 있는데 (Result.t 반환) library convention 이 unwrap 형. caller 마다 개별 `try ... with` 로 처리 → 분산 + drift.

`lib/core/safe_ops.ml` 가 일부 typed wrapper 제공하나 (`Safe_ops.parse_json_string`) caller 0 - 1 건 — *adoption rate 0.3%*.

### Why this needs an RFC

1. **누적 메커니즘**: 새 read site (예: 새 MCP tool, 새 sidecar event) 추가 때마다 또 fix PR 필요. N-of-M 가 지속.
2. **데이터 손실 가시성 vs 실제 fix**: counter 추가는 *quantity* 가 visible. *quality* (어떤 schema 가 깨졌나, malformed UTF-8 vs missing key vs unexpected null) 는 invisible 그대로.
3. **CLAUDE.md merge-reject bar §1 직접 위반**: 본 PR 그룹의 머지가 그 bar 의 enforcement 실패 사례.
4. **RFC-0088 enforce gate 부재**: 0088 spec 만 있고 PR-level lint/check 없음.

근본 원인: **JSON parse boundary 가 typed `Result.t` 가 아닌 raise-based**. 그리고 typed wrapper (`Safe_ops.parse_json_string`) 가 있는데 adoption gate 없음.

## §2 Approach

3 layer:

**Layer A — Typed parse SSOT in core**

`lib/core/json_parse.ml(i)` 신설 (또는 `safe_ops.ml` 확장):

```ocaml
module Json_parse_error : sig
  type t =
    | Malformed_syntax of { byte_offset : int; reason : string }
    | Schema_mismatch of { expected : string; actual : string; path : string list }
    | Utf8_encoding of { byte_offset : int }
    | File_io of { path : string; reason : string }
  val to_string : t -> string
  val to_log_fields : t -> (string * Yojson.Safe.t) list
end

val of_string : string -> (Yojson.Safe.t, Json_parse_error.t) Result.t
val of_file : Eio.Fs.dir_ty Eio.Path.t -> (Yojson.Safe.t, Json_parse_error.t) Result.t
```

각 caller 는 `match Json_parse.of_string s with Ok j -> ... | Error err -> ...` 강제. Counter 가 필요하면 *호출자 결정* — 기본은 propagation.

**Layer B — Schema decoder typed**

`Json_parse.decode : (Yojson.Safe.t -> ('a, Json_parse_error.t) Result.t) -> string -> ('a, Json_parse_error.t) Result.t` — schema mismatch 도 같은 sum 으로 unified.

`ppx_deriving_yojson` 의 `_of_yojson` 함수가 `('a, string) Result.t` 반환 — 이 string error 를 `Schema_mismatch` 로 mapping 하는 adapter.

**Layer C — Adoption gate**

`scripts/lint-json-parse-raw.sh` (또는 dune 의 `(executables (mode...))` 안의 코드젠) 가 `lib/` 안 모든 `Yojson.Safe.from_string`, `Yojson.Safe.from_file` 호출을 grep. *grandfather list* (`scripts/lint-json-parse-raw.grandfather.txt`) 에 등록된 site 만 허용. 새 호출은 build fail.

Grandfather list 는 *수치 통제* 도구 — RFC-0098 PR-1 #15759 의 `anti-fake-audit.sh --production-scan` 패턴 재사용.

## §3 Phasing

| Phase | Deliverable | Acceptance |
|---|---|---|
| P1 (this PR) | RFC body | Draft → main |
| P2 | `lib/core/json_parse.ml(i)` typed API + 5 unit test (malformed / schema / utf8 / file / OK paths) | dune build PASS, alcotest PASS |
| P3 | `lint-json-parse-raw.sh` + grandfather list (initial: 292 site) | CI workflow runs, baseline grandfather count = 292 |
| P4 | High-traffic sites migration: 4 already-patched (#15820, #15840, #15866, #15781) + 10 more (configurable target) | grandfather count ≤ 278, counter drops ≥ 90% (sites no longer emit `warn+counter on silent JSON parse drop`) |
| P5 | Medium-traffic batch: 50 sites/PR until grandfather count ≤ 100 | LoC migration: ~50 sites × 5 LoC each = 250 LoC/PR |
| P6 | Tail sweep — remaining sites, grandfather list deleted, lint enforces zero raw `from_string`/`from_file` | grandfather count = 0 |

P3 가 핵심 — grandfather list 없으면 P4/P5/P6 가 측정 불가능.

## §4 Open questions

1. **Q1**: `from_string` 와 `from_file` 외에 `Yojson.Safe.from_channel` 도 같이 ban? 사용 빈도 측정 후 결정. **잠정**: `from_channel` 16 호출 — 같이 포함.

2. **Q2**: `ppx_deriving_yojson` 의 자동 derived `_of_yojson` 함수가 raise 하는 경우 (예: `[@@deriving yojson_strict]`)? Migration 시 strict mode 끄고 Result 변환 adapter. **잠정**: P4 의 site migration 시 case-by-case 결정.

3. **Q3**: Grandfather list 의 *expiration policy*? 1 년 후 자동 0 으로 reset 강제? **잠정**: 없음 (lint 가 새 site 0 보장하면 충분, tail sweep 은 명시적 PR 로).

4. **Q4**: `Json_parse_error.Schema_mismatch.path` 의 JSON path encoding (JSONPath vs dot.notation)? **잠정**: dot.notation (`$.user.email`) — JSONPath 의 일부.

## §5 Non-goals

- **Yojson 라이브러리 자체 변경** — upstream PR 가능성 있으나 본 RFC 는 internal API 만.
- **다른 serialization format** (msgpack, cbor) — 별도 RFC 가능, 본 RFC 는 JSON 만.
- **Schema 자체의 evolution** (예: backward-compat) — typed error 만, schema 변경 정책 별도.
- **Provider boundary parse** (예: Anthropic / OpenAI response) — 본 RFC 는 *internal* JSON read. provider response 는 `Agent_sdk.Types.message` 변환 layer 가 별도 책임.

## §6 Risk & rollback

- **Risk 1**: 292 site 마이그레이션이 *cycles 동안* 진행되며 부분 typed / 부분 raw 혼재. → grandfather list 가 baseline. CI 가 *증가* 만 block, 감소는 통계로 추적.
- **Risk 2**: Adapter 가 ppx-generated `_of_yojson` 와 type mismatch. → P2 unit test 가 5 typical schema 패턴 모두 cover. P4 첫 migration 에서 실 사례 발견 시 P2 backport.
- **Risk 3**: `Result.t` 도입이 caller 코드를 verbose 하게 만듦. → `Result.bind` chain + `let*` operator 패턴 권장 (RFC-0098 의 `Mcp_error_code` pattern 재사용).
- **Risk 4**: Tail sweep (P6) 가 시간 소요 — 1 년 단위 작업. → 명시적 acceptance가 *baseline count = 0* 가 아닌 *grandfather list 만 grow 안 하면 PASS*. P6 는 별도 RFC closeout 으로 처리.

Rollback: P3 의 lint 비활성 (`SKIP_JSON_PARSE_LINT=1`) 환경 변수. P2 typed API 는 backwards-compat — 기존 raw call 유지 가능.

## §7 Acceptance

- [ ] P1: RFC body merge.
- [ ] P2: `lib/core/json_parse.ml(i)` 타입 정의 + 5 unit test PASS.
- [ ] P3: `lint-json-parse-raw.sh` baseline = 292 site (grandfather list 매칭).
- [ ] P4: 4 기-패치 site (#15820/15840/15866/15781) + 10 추가 site = grandfather ≤ 278.
- [ ] P5: 50-site batches; intermediate 100 milestone hit.
- [ ] P6: grandfather count = 0, raw `from_string`/`from_file` 호출 = 0.

## §8 Number allocation note

Allocated as RFC-0112. Ledger advanced 0109 → 0113 (skip 0109/0110/0111 due to inflight #15902 RFC-0109 CDAL × GOAL + #15924 RFC-0110 tool-pair atomicity + #15927 RFC-0111 goal mint atomicity — last two from this loop's iter-2/3). Per README policy "skipped numbers reserved against reuse — ledger is monotonic."

Note: Main 의 RFC-0108 동시 점유 사고 (RFC-0108-atomic-jsonl-append.md + RFC-0108-pr-worktree-operation-safety-gates.md, 5분 차이 머지) 가 본 RFC iter-1 (RFC-0108 PR Safety Gates) 의 Gate-4 가 정확히 막아야 했던 시나리오. Follow-up cleanup PR 후보.
