---
rfc: "0142"
title: "cascade_error_classify Decomposition + Typed JSON-Extraction Variant"
status: Draft
created: 2026-05-20
updated: 2026-05-20
author: vincent
supersedes: []
superseded_by: null
related: ["0085", "0088"]
implementation_prs: []
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
