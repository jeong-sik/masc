---
rfc: "0142"
title: "cascade_error_classify Decomposition + Typed JSON-Extraction Variant"
status: Active
created: 2026-05-20
updated: 2026-05-23
author: vincent
supersedes: []
superseded_by: null
related: ["0085", "0088", "0089", "0148", "0154"]
implementation_prs: [16790, 16806, 16894, 16899, 17474]
---

## Progress audit (2026-05-21)

Status promoted Draft → Active. Phase 1 of the four-phase plan has
landed in part; Phase 2/3 remain.

### Phase 1 — `Json_field` helper module

| PR | Scope | Merged |
|----|-------|--------|
| #16790 | `lib/json/json_field.{ml,mli}` typed extractor (`Found` / `Field_absent` / `Wrong_shape`) + `to_option` / `log_wrong_shape` | 2026-05-19 |
| #16806 | `telemetry_unified` string/bool field migration (Stack PR-3) | 2026-05-19 |
| #16894 | `dashboard/dashboard_http_helpers` migration (PR-4) | 2026-05-20 |
| #16899 | `server/server_dashboard_http_*` local helpers migration (PR-5) | 2026-05-20 |

### Variance from spec

- **PR sequencing collision**: numbering jumped #16790 → #16806 (Stack
  PR-3) → #16894 (PR-4). Stack PR-2 is unlabeled in the commit log;
  it appears subsumed into PR-3 or was never landed. Closeout will
  resolve the numbering after Phase 2.
- **`cascade_error_classify.ml` migration deferred**: Phase 1 spec
  promised ~20 catch-alls in this file converted. Measured 2026-05-21:
  4 `Json_field` usages / 33+ `| _ ->` catch-alls remain / file grew
  to 939 LoC (vs spec-time 873 LoC). The Phase 1 migration landed on
  the *other* call families (telemetry_unified, dashboard_http_helpers,
  server_dashboard_http) but the originating godfile remains untouched.

### Phase 2 — module split (mostly landed; PR-3 cancelled)

`cascade_error_classify.ml` has been reduced from **939 LoC** at
2026-05-21 to **111 LoC** on `origin/main` (2026-05-22).  Two of
the three planned target modules now exist; PR-3 was cancelled
when the codex-preflight content was reorganized into
`cascade_config_builder.ml` instead of a new sibling.

| Phase 2 PR | Target | Status |
|------------|--------|--------|
| PR-1 | `lib/cascade/cascade_internal_error.ml(.mli)` | **landed** (file present on `origin/main`) |
| PR-2 | `lib/cascade/cascade_error_from_sdk.ml(.mli)` | **landed** (PR #17474, merged 2026-05-22; appears in §frontmatter `implementation_prs`) |
| PR-3 | `lib/cascade/cascade_codex_preflight.ml(.mli)` | **cancelled** — the Codex CLI prompt preflight content lives in `lib/cascade/cascade_config_builder.ml`, whose module-header comment reads *"Cascade config construction and Codex CLI prompt preflight"*.  The functions reachable via `grep -n 'preflight' lib/cascade/cascade_config_builder.ml` cover the original PR-3 scope without creating a third sibling module. |

Net Phase 2 effect: the originating godfile is **88% smaller**
(939 → 111 LoC) and the two new modules carry the typed bodies
PR-1/PR-2 prescribed.

### Phase 3 — reachability sweep (Phase 2 prerequisite now met)

The Phase 3 prerequisite ("smaller Phase 2 modules") is satisfied
as of 2026-05-22.  `masc_internal_error` variant constructor
reachability audit can now run on the three smaller surfaces
(`cascade_internal_error.ml`, `cascade_error_from_sdk.ml`, the
residual 111-line `cascade_error_classify.ml`).  Not started yet.

### Remaining work

Phase 3 reachability sweep is the only substantive work left for
this RFC.  Phase 1 migration of the remaining `Json_field`-eligible
catch-alls is now achievable on the much-smaller residual godfile
(was ~20 catch-alls in 939 LoC, expected to be 3-5 in the 111 LoC
remainder).

### Related RFC

- **RFC-0148** (Typed `tool_error` Variant for LLM-Facing Tool Failure
  Surface, Implemented 2026-05-20): sister closed-sum migration. Phase
  2 of RFC-0142 should reuse the variant shape pattern.
- **RFC-0154** (System_error_class typed SSOT, Implemented 2026-05-21):
  operator-facing closed-sum SSOT. The `Wrong_shape` diagnostic
  affordance here is the same parse-don't-validate discipline.

### Phase 4 — `Provider_error_class` typed boundary (NEW 2026-05-23)

Audit on 2026-05-23 (`memory/keeper-health-probe-hardcoding-audit-2026-05-23.html`)
identified an adjacent surface untouched by Phases 1-3:
`lib/keeper/keeper_health_probe.ml:provider_runtime_pressure_class`
holds the same `contains "<needle>"` + magic HTTP status + 20-alias
parse soup that this RFC's umbrella exists to eliminate.

Inventory at `origin/main` 2026-05-23:

| Surface | Count | Site |
|---------|-------|------|
| `String_util.contains_substring_ci` substring literals | 23 | `keeper_health_probe.ml:66-98` |
| Magic HTTP status integer literals | 5 (`408`/`429`/`504`/`524`/`529`) | `keeper_health_probe.ml:83, 99` |
| `runtime_pressure_class_of_label` alias strings | 20 (10 variants × 1-3 aliases) | `keeper_health_probe.ml:37-52` |

The fall-through `| _ -> Provider_error` in
`provider_runtime_pressure_class` is exactly RFC-0088 §1 *Unknown →
Permissive Default* — an `Unknown` provider error is silently
classified into the catch-all bucket, defeating reactor
specialization.

#### Phase 4 PR plan

| PR | Scope | Acceptance |
|----|-------|-----------|
| **PR-A** (this PR) | `lib/keeper/provider_error_class.{ml,mli}` new module — closed-sum `t` + named `Http_status` constants + wire tags + tests. Zero callers, zero behavioural change. | `dune build lib/keeper/provider_error_class.cmi` clean; `test_provider_error_class` Alcotest green; `rg 'contains "' lib/keeper/keeper_health_probe.ml` count *unchanged* (PR-A is additive only). |
| PR-B-Anthropic | `lib/llm_provider/anthropic_*` adapter emits `Provider_error_class.t` directly from typed error response. | Anthropic adapter test covers 6 named variants; `Unspecified` only on genuinely unknown payloads. |
| PR-B-Openai_compat | Same for OpenAI-compatible adapter (Kimi, GLM, llamacpp-OpenAI-API). | Adapter test covers 6 variants. |
| PR-B-Llamacpp_local | Same for local llama.cpp adapter. | Adapter test covers timeout & DNS only (no backpressure surface). |
| PR-C | Add `classified_as : Provider_error_class.t` field to `Keeper_registry_types.Provider_runtime_error`. Producers set it from PR-B output; consumers may still ignore it. | Field present in `.ml` + `.mli`; `failure_reason_to_string` reads `classified_as |> to_short_tag` for the tag prefix; backwards-compatible serialization. |
| PR-D | `keeper_health_probe.ml:provider_runtime_pressure_class` rewritten as pure typed `match` on `classified_as`. `runtime_pressure_class_of_label` parse function deleted. | `rg 'contains "' lib/keeper/keeper_health_probe.ml` → **0**; `rg '\b(408\|429\|504\|524\|529)\b' lib/keeper/keeper_health_probe.ml` → **0**; new typed variant in `Provider_error_class.t` triggers exhaustive-match compile error in the consumer. |

#### Acceptance metric for Phase 4 closure

| Metric | Before | After Phase 4 |
|--------|--------|---------------|
| Substring literals in `keeper_health_probe.ml` classifier branches | 23 | 0 |
| Magic HTTP status integers in `keeper_health_probe.ml` | 5 | 0 (named constants in `Provider_error_class.Http_status`) |
| `runtime_pressure_class_of_label` alias strings | 20 | 0 (function deleted, callers consume typed `Provider_error_class.t` directly) |
| Classifier surface compiler-checked on new provider error addition | No (substring soup) | Yes (exhaustive `match` on closed sum) |

#### Why Phase 4 belongs in RFC-0142

RFC-0142's umbrella scope is "cascade/provider error classification
substring-and-catch-all elimination" (cf. RFC-0089 string-classifier
umbrella).  The originally-listed `cascade_error_classify.ml` was one
file under that umbrella; `keeper_health_probe.ml` is another.  Phase
4 closes the keeper-reaction-layer twin.

---

# RFC-0142 — cascade_error_classify Decomposition

## 1. Summary

`lib/cascade/cascade_error_classify.ml` is 873 LoC with 33 line-leading `| _ -> None | [] | 0.0 | …` catch-all arms. Most of these catch-alls are inside ad-hoc JSON-field extraction code. The file is both a godfile (RFC-0085 decomposition track) and a hotbed of sparse exhaustive matches (RFC-0088 §3.4 / §3.5 surface).

This RFC proposes:

1. **A typed `Json_field.t` extraction helper** that replaces ~20 of the 33 catch-alls.
2. **A two-axis decomposition** of the remaining file into (a) the `masc_internal_error` ADT + JSON codec, (b) the CLI preflight, and (c) the SDK error → classification mapping.

## 2. Surface today

```
lib/cascade/cascade_error_classify.ml — 873 LoC
  catch-alls (`| _ -> default`):                33
  audit clusters:
    :87-126   8 catch-alls — JSON field extraction (`detail`, `reason`, `status`)
    :418-462  5 catch-alls — provider rejection JSON extraction
    :494-506  5 catch-alls — admission queue JSON extraction
    :239      1 catch-all — `List.concat` over string values
    other     14 catch-alls scattered
```

These coexist with three distinct concerns intertwined in one module:

- **Concern A** — `masc_internal_error` variant definition + JSON serialization (lines ~1-300).
- **Concern B** — SDK error (`Anthropic_sdk.Error.t`, `Openai_sdk.Error.t`) → `masc_internal_error` classification (lines ~300-650).
- **Concern C** — codex CLI prompt preflight (lines ~650-873).

The godfile header itself documents extraction from `oas_worker_named.ml`. A second extraction is overdue.

## 3. Why the catch-alls are dangerous

The JSON extraction shape repeats:

```ocaml
match Yojson.Safe.Util.member "reason" json with
| `String s -> Some s
| _ -> None
```

`_` swallows `` `Int _``, `` `Bool _``, `` `Assoc _``, `` `Null``, `` `List _``, every future variant Yojson adds. When an upstream provider changes the field shape (string → object with `{"detail": …}`), the call silently returns `None` — the cascade classification routes to `Unknown` and the user sees a generic "cascade exhausted" with no provider rejection detail.

MEMORY `project_cascade_tier_group_misroute_2026_05_17` is a sibling incident: cascade.toml parsing silenced a partial-config bug. The catch-all extraction pattern in this file is the *runtime-side* sibling — provider responses silently lose detail.

## 4. Proposal — phased

### Phase 1 — `Json_field` helper module

**Scope amendment (2026-05-20)**: the helper lives at `lib/json/json_field.ml(.mli)` — not `lib/cascade/` — because `lib/telemetry_unified.ml` carries the same JSON-extraction catch-all shape at 21 sites (`:53`, `:284-300`, `:448-525`, `:598-641`, `:899` measured 2026-05-20). Promoting the helper to `lib/json/` lets both call families share it. Both modules' migrations move under Phase 1.

The original `lib/cascade/`-scoped sketch below is preserved for archival purposes; the actual module path is `lib/json/`.

New `lib/json/json_field.ml(.mli)`:

```ocaml
(** Typed extraction from Yojson.Safe.t with explicit shape-mismatch
    diagnostics. Replaces ad-hoc [| _ -> None] catch-alls in
    cascade_error_classify and similar JSON-shaped boundaries. *)

type 'a extraction =
  | Found of 'a
  | Wrong_shape of { expected: string; got: string }   (** e.g. expected "string", got "object" *)
  | Field_absent

val string : Yojson.Safe.t -> string -> string extraction
val int    : Yojson.Safe.t -> string -> int extraction
val float  : Yojson.Safe.t -> string -> float extraction
val assoc  : Yojson.Safe.t -> string -> (string * Yojson.Safe.t) list extraction
val list   : Yojson.Safe.t -> string -> Yojson.Safe.t list extraction

val to_option : 'a extraction -> 'a option
(** Lossy conversion: discards [Wrong_shape] diagnostic. Use only at
    call sites that already accept "no field" semantics. *)

val log_wrong_shape : label:string -> 'a extraction -> 'a option
(** [to_option] + emit a [Log.Cascade.warn] on [Wrong_shape] so
    schema drift surfaces in operator logs without aborting the
    response classification path. *)
```

Phase 1 replaces ~20 catch-alls in `cascade_error_classify.ml` **plus the 21 catch-alls in `telemetry_unified.ml`** (audit 2026-05-20). The two helpers (`to_option`, `log_wrong_shape`) keep migration mechanical while preserving the option-call-site contract.

The telemetry_unified sites are technically *boundary-correct* today: a non-`String value gets `None` because the Yojson variant doesn't match, and the caller already accepts `None` semantics. They are migrated alongside cascade_error_classify so that *schema drift in upstream payloads becomes operator-visible* via `log_wrong_shape` rather than silently disappearing. No data-loss bug is being fixed in telemetry_unified — the migration is purely diagnostic.

`log_wrong_shape` is **not** a telemetry-as-fix workaround (RFC-0088 §3.1) because the underlying *fix* is the typed variant — the log is a diagnostic affordance for the case where schema drift is unavoidable (third-party provider response).

### Phase 2 — module split

Three new modules:

- `cascade_internal_error.ml(.mli)` — variant + JSON codec (Concern A)
- `cascade_error_from_sdk.ml(.mli)` — SDK error mapping (Concern B)
- `cascade_codex_preflight.ml(.mli)` — CLI prompt preflight (Concern C)

Each ≤ 350 LoC. `cascade_error_classify.ml` becomes a thin re-exporting facade for backwards compatibility, then deleted once callers migrate.

### Phase 3 — `masc_internal_error` reachability sweep

The variant has ~25 constructors; the audit will publish which are reachable from production vs which are dead. Phase 3 deletes the dead constructors (a separate concern from this RFC but enabled by Phase 2's smaller-surface modules).

## 5. Compatibility

- Phase 1: behavioral no-op on the happy path. `to_option` reproduces today's `Some|None` contract; `log_wrong_shape` adds a `Log.Cascade.warn` line when the response schema drifts. No on-wire change.
- Phase 2: file rename + re-export facade. CI ratchet `ocaml-structure-ratchet.sh` will detect the godfile reduction.
- Phase 3: only deletes unreachable code (verified by `dune-coverage` + `merlin-occurrences` cross-check).

## 6. Non-goals

- Replacing `Yojson` with a typed schema (e.g. `atd`). Out of scope; would touch every JSON boundary in masc-mcp.
- Touching `cascade_attempt_fsm.ml` 13-site substring classifier. Tracked separately (RFC-0042 / RFC-0057 follow-up).
- ~~Touching `telemetry_unified.ml` 22 catch-alls. Tracked separately.~~ **Moved into Phase 1 scope on 2026-05-20** — see Phase 1 amendment.

## 7. Test plan

| Phase | Test |
|---|---|
| Phase 1 | Unit tests for each `Json_field` extractor — `Found`, `Wrong_shape`, `Field_absent` cases. Round-trip test: malformed `reason` field (`{"reason": 42}`) → `Wrong_shape { expected="string"; got="int" }`. Telemetry_unified migration: `tool_called_detail_from_fields` against a `{"event": ["Tool_called", 42, …]}` payload (Int instead of Assoc) emits a `log_wrong_shape` line and returns `None` (same as before, with diagnostic). |
| Phase 2 | Existing `test/test_cascade_error_classify*.ml` suites must continue to pass against the new facade. Add a "no-direct-import" lint check ensuring downstream callers go through the facade until Phase 2 closeout. |
| Phase 3 | `dune-coverage` report shows ≥95% reachability of the post-split variant constructors. |

## 8. RFC-0088 conformance

- **§3.1 (Counter-as-Fix)**: `log_wrong_shape` adds a log line **alongside** the typed-variant root fix, not in place of it. The variant *is* the fix.
- **§3.2 (String classifier)**: this RFC removes string-shape decisions (`| _ -> None`) and replaces them with `Yojson.Safe.t` variant matching.
- **§3.3 (N-of-M)**: Phase 1 closes ~20 sites in one migration. Phase 2 closes the remaining catch-alls structurally (they have no place in the split modules).
- **§3.4 (Symptom suppression)**: no cap/cooldown/repair introduced.

## 9. Open questions

1. ~~Should `Json_field` live in `lib/cascade/` or a more general `lib/json/` location?~~ **Resolved 2026-05-20**: `lib/json/` from Phase 1. The same audit that produced RFC-0141 also flagged 21 sites in `lib/telemetry_unified.ml`; promoting the helper at the start avoids a later module-move and lets both call families migrate under a single PR-1.
2. Should Phase 2 facade be deleted in the same PR as the module split, or two PRs? Two PRs — split first to surface call-site failures, then delete facade once green.

## 10. Related work

- RFC-0085 — keeper bulk-promotion + godfile decomp track.
- RFC-0088 — workaround rejection bar (catch-all is §3.5 anti-pattern).
- MEMORY `project_cascade_tier_group_misroute_2026_05_17` — sibling silent-drop incident at config-parse boundary, root cause closed by RFC-0058 strict parsing (PR #16739 in flight at audit time).
