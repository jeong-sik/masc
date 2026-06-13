---
rfc: "0189"
title: "Typed Tool_result.result variant — eliminating boolean blindness in tool dispatch"
status: Draft
created: 2026-05-26
updated: 2026-05-26
author: vincent
supersedes: []
superseded_by: null
related: ["0062", "0044", "0077", "0088", "0179"]
implementation_prs: []
---

# RFC-0189 — Typed `Tool_result.result` variant

## 0. tl;dr

`Tool_result.t` is a structured record with `success : bool` and
`failure_class : tool_failure_class option`. That shape makes four
illegal states representable that the compiler cannot rule out, and
forces 285 call sites to thread a substring/JSON classifier
(`classify_from_structured_failure_message`, anti-pattern §2) to recover
information the type system should have carried.

This RFC introduces `(success_payload, failure_payload) Stdlib.Result.t`
as the new SSOT. PR-1a (companion to this RFC) lands the new surface +
converters with **zero call-site changes**. PR-1b migrates the 285
constructor sites category-by-category. PR-2 drops the legacy record and
the substring classifier.

## 1. Problem

### 1.1 Illegal states representable

The legacy record:

```ocaml
type t =
  { success : bool
  ; data : Yojson.Safe.t
  ; message : string
  ; tool_name : string
  ; duration_ms : float
  ; failure_class : tool_failure_class option
  }
```

permits four configurations the type system cannot rule out:

| # | Configuration | Why illegal |
|---|---|---|
| 1 | `{success=true; failure_class=Some _}` | success-with-failure contradiction |
| 2 | `{success=false; failure_class=None}` | silent failure; caller has no typed reason |
| 3 | caller does `if r.success then ... else ...` | boolean blindness — message body must be parsed to recover class |
| 4 | `error ?failure_class:tool_failure_class option ...` | option-of-option in API surface |

Each is `software-development.md` §AI 코드 생성 안티패턴 §2
(string/substring classifier) — typed sum type was already in the
codebase (`tool_failure_class`), but the *shape* of `t` forced callers
back into stringly-typed reasoning.

### 1.2 Substring classifier in the failure path

`lib/tool_types/tool_result.ml:64-74`:

```ocaml
let classify_from_structured_failure_message message =
  try
    match Yojson.Safe.from_string message with
    | `Assoc fields ->
      (match List.assoc_opt "failure_class" fields with
       | Some (`String value) -> tool_failure_class_of_string value
       | _ -> None)
    | _ -> None
  with
  | Yojson.Json_error _ -> None
;;
```

This is the *exact* pattern RFC-0062 §3.2 said it would remove
("Phase 1 `classify_from_dispatch_failure` string fallback has been
removed"). It is still here. Cause: the record permits `failure_class =
None`, so `error` must guess on the caller's behalf.

### 1.3 Blast radius

Constructor distribution (`rg "Tool_result\.(ok|error|of_exn|quick_)" lib/`):

| File | Calls |
|------|------:|
| `tool_board_handlers.ml` | 26 |
| `tool_task_handlers.ml` | 19 |
| `tool_plan.ml` | 19 |
| `tool_library.ml` | 18 |
| `tool_run.ml` | 16 |
| `tool_board_post.ml` | 16 |
| `mcp_server_eio_execute.ml` | 16 |
| `tool_task.ml` | 14 |
| `tool_types/tool_args.ml` | 13 |
| `mcp_tool_runtime.ml` | 13 |
| ... (remaining) | 115 |
| **Total** | **285** |

Field accessors (`.success / .message / Tool_result.{...`) appear at
**407 sites across 64 files** — the accessor-side surface is wider and
will be migrated in PR-1b clusters.

## 2. Non-goals

- New typed sum types parallel to `Read_drop_reason.t` (RFC-0044) or
  `Write_failure_reason.t` (RFC-0077). Reuse the existing
  `tool_failure_class`.
- Per-tool typed input/output payloads (success_payload.data,
  failure_payload.data stay `Yojson.Safe.t` for now). RFC-0179 descriptor
  migration is the natural vehicle for that "Full ambition" step
  (deferred 6-month track).
- Cross-process wire format changes. The legacy `to_json` projection
  stays identical so MCP consumers see no change.
- Changing `tool_failure_class` (4-variant closed sum already shipped via
  RFC-0062).

## 3. Design

### 3.1 New surface (added in PR-1a)

```ocaml
type success_payload =
  { data : Yojson.Safe.t
  ; tool_name : string
  ; duration_ms : float
  }

type failure_payload =
  { class_ : tool_failure_class    (* REQUIRED, not option *)
  ; message : string
  ; data : Yojson.Safe.t
  ; tool_name : string
  ; duration_ms : float
  }

type result = (success_payload, failure_payload) Stdlib.Result.t

val make_ok      : tool_name:string -> start_time:float -> ?data:Yojson.Safe.t -> unit -> result
val make_err     : tool_name:string -> class_:tool_failure_class -> start_time:float -> ?data:Yojson.Safe.t -> string -> result
val make_err_of_exn : ?class_:tool_failure_class -> tool_name:string -> start_time:float -> exn -> result

val to_legacy : result -> t
val of_legacy : t -> result   (* coerces illegal states #1, #2 to Error with Log.warn *)
```

Notes:
- `class_` on `failure_payload` is **required, not `option`**. Eliminates
  illegal states #1, #2, #4 by construction.
- `make_err`'s `~class_` is **labelled and required** — caller cannot
  silently default. Eliminates illegal state #4.
- `result` is a *type alias* for `Stdlib.Result.t`, so `Result.map`,
  `Result.bind`, `Result.fold` all compose without wrappers.
- `of_legacy` emits `Log.warn` with `~ctx:"tool_result"` when it
  encounters illegal state #1 or #2 in legacy callers. The warn is
  observable in logs during PR-1b migration and disappears in PR-2.

### 3.2 Migration plan

| Phase | Scope | Diff size | Risk |
|-------|-------|----------:|------|
| **PR-1a** (this RFC) | Add `result` + converters + 7 unit tests | ~200 LoC | ⭐ zero — no caller touched |
| **PR-1b.1** | Migrate `tool_board_*` cluster (26 + 16 + 9 + 7 = 58 calls, 4 files) | ~120 LoC | ★ low |
| **PR-1b.2** | Migrate `tool_task*` cluster (19 + 14 = 33 calls, 2 files) | ~70 LoC | ★ low |
| **PR-1b.3** | Migrate `tool_library` + `tool_plan` (18 + 19 = 37 calls, 2 files) | ~80 LoC | ★ low |
| **PR-1b.4** | Migrate `tool_run` + `tool_misc*` (16 + 20 calls, 4 files) | ~80 LoC | ★ low |
| **PR-1b.5** | Migrate `mcp_server_eio_execute` + `tool_inline_*` (16 + 27 calls, 4 files) | ~100 LoC | ★★ medium (server edge) |
| **PR-1b.6** | Migrate remaining (~115 calls, ~18 files) | ~200 LoC | ★ low |
| **PR-1c** | Migrate 407 accessor sites in 64 files (pattern match instead of `.success`/`.failure_class`) | ~800 LoC | ★★★ high — big-bang per [feedback_radical_improvement_over_diff_size] |
| **PR-2** | Drop legacy `t`, `to_legacy`, `of_legacy`, `classify_from_structured_failure_message`, legacy `ok`/`error`/`of_exn`/`quick_*` | ~250 LoC removed | ★★ medium — dead-code sweep, [feedback_dead_export_audit_must_trace_include_facade] applies |

Each PR-1b step is independently mergeable. Order is intentional:
boards/tasks first (most call sites, most concrete failure semantics),
server edge last (highest blast radius).

### 3.3 What's *not* changing in PR-1a

- At PR-1a time, the legacy record `t` and all its constructors (`ok`,
  `error`, `of_exn`, `quick_ok`, `quick_error`) were intentionally left in
  place. The later PR-2/cleanup path removes that compatibility surface.
- `classify_from_structured_failure_message` is annotated as "scheduled
  for removal in PR-2" but kept live so the legacy `error` constructor
  observes its current behaviour.
- `to_json` projection unchanged → MCP wire format identical.
- 285 constructor sites and 407 accessor sites untouched.

This is what makes PR-1a zero-regression: it is purely *additive*.

## 4. Verification

### 4.1 PR-1a (this commit)

- `dune build --root . lib/` → exit 0 (verified)
- `dune exec --root . test/test_tool_result.exe` → 20/20 PASS (verified)
  - 13 pre-existing tests (round-trip, structured failure_class honor, exception classification)
  - 7 new RFC-0189 tests:
    1. `make_ok round-trip` (Ok → to_legacy → of_legacy → Ok)
    2. `make_err required class` (compile-time + run-time class preservation)
    3. `make_err round-trip preserves class` (Error → to_legacy → of_legacy → Error)
    4. `of_legacy coerces illegal state #1` (success=true + class=Some → Error)
    5. `of_legacy coerces illegal state #2` (success=false + class=None → Error + Runtime_failure)
    6. `make_err_of_exn classifies by constructor` (Eio.Time.Timeout → Transient_error)
    7. `result aliases Stdlib.Result.t` (Result.map composes)

### 4.2 PR-1b (per-step)

Each PR-1b step must:
1. `dune build --root . lib/` → exit 0
2. `dune exec --root . test/test_tool_result.exe` → 20/20 PASS
3. `dune build @runtest` → no new regression (sandbox config caveat per
   `reference_masc_sandbox_config_unresolved_runtest`)
4. Migrated file's `dune` `(libraries ...)` unchanged → no new dependency
5. `Log.warn` count from `of_legacy` measured before/after each step — should
   trend toward zero as PR-1b lands

### 4.3 PR-2

Once `to_legacy`/`of_legacy`/`t` are removed:
1. Full `rg "Tool_result\.t\b" lib/`  → 0 hits
2. Full `rg "\.success\b" lib/` → 0 hits on Tool_result records
3. Full `rg "classify_from_structured_failure_message" lib/` → 0 hits
4. 5-prong dead-export audit per
   `feedback_dead_export_dead_export_sweep_2026_05_23_anti_pattern`:
   - direct grep, facade re-export, `include` re-export,
     opener-unqualified, paired test file

## 5. Workaround Signature Gate compliance

Per `software-development.md` §워크어라운드 거부 기준:

- **§1 Telemetry-as-fix**: ❌ does not apply — RFC removes a classifier,
  adds none.
- **§2 String/substring classifier**: ✅ explicitly removes
  `classify_from_structured_failure_message` in PR-2.
- **§3 N-of-M patch**: ❌ does not apply — PR-1a is *additive*; PR-1b is
  a planned, staged caller migration with explicit per-step verification
  per RFC §4.2.
- **Override clause**: not invoked.

This RFC *closes* an existing workaround rather than introducing one.

## 6. Open questions

| # | Question | Default | Decision deadline |
|---|---|---|---|
| Q1 | Should PR-2 also drop `tool_failure_class_of_string`? It exists for parsing JSON-encoded `failure_class` fields, which become unnecessary once the typed payload owns the field. | Yes — drop in PR-2 alongside `classify_from_structured_failure_message` | PR-2 review |
| Q2 | Should `failure_payload.data` be narrowed beyond `Yojson.Safe.t` (per-tool GADT)? | No — defer to "Full ambition" follow-up RFC tied to RFC-0179 descriptor migration | After RFC-0179 PR-7 lands |
| Q3 | Should `make_err_of_exn` keep `?class_:tool_failure_class` optional? It is a *single* option (not option-of-option), so it does not fall into illegal state #4. | Yes — keep, but document that `Some` is preferred at every catch boundary | PR-1a review |

## 7. Related work

- **RFC-0062** — Typed `Tool_result.t` + typed `Sdk_*` blocker class
  (Implemented). Introduced `tool_failure_class` 4-variant closed sum.
  RFC-0189 picks up where RFC-0062 §3.3 stopped: the `option` wrapping
  remained, and §3.2's promise to remove the substring classifier was
  partially undone by `classify_from_structured_failure_message`.
- **RFC-0044** — Typed persistence read-drop reason (Active). Sibling
  pattern for read-side silent failures.
- **RFC-0077** — Write-side silent failure typed propagation
  (Implemented). The closest precedent in shape: PR #15054 migrated
  ~13 keeper write sites to typed `Write_failure_reason.t`.
- **RFC-0088** — Counter-as-fix → Result propagation umbrella (Active).
  RFC-0189 falls under the umbrella's category "Result propagation in
  tool dispatch" (not enumerated in 0088 §3 inventory because 0088 is
  scoped to counter-paired silent failures; this RFC handles the
  classifier-paired analogue).
- **RFC-0179** — ToolDescriptor ecosystem coverage (PR-7 merged 2026-05-26
  as #18710). Now that 286 tools route through descriptors, the natural
  next step is for descriptors to *speak* `(success, failure) Result.t`
  natively. PR-1c (accessor migration) is what unlocks that.
