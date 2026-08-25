# RFC-OAS-033: thinking_control_format vocabulary leaf SSOT

| | |
|---|---|
| Status | Implemented |
| Author | jeong-sik (audit: provider SSOT sweep, 2026-06-30) |
| Created | 2026-06-30 |
| Amended | 2026-07-18 — exact lossless thinking-control codec contract |
| Target | `lib/llm_provider/capability_vocab.ml`, `capabilities.ml`(+`.mli`), `provider_catalog.ml`, `capability_manifest.ml`, `model_catalog.ml`, `reasoning_dialect.ml` |
| Supplements | RFC-OAS-023 (capability axis reshape), RFC-OAS-029 §1.2 (string classifier bypassing typed kind) |
| Boundary | OAS capability vocabulary and catalog-input contract. Variant ownership remains internal; the public codec rejects non-canonical labels and invalid token combinations. |

## 0. Summary

This RFC records the accepted and implemented leaf-SSOT ownership for
`thinking_control_format` / `preserve_thinking_control_format`.

Before the migration, these closed sum variants were owned by `Capabilities`,
while `capability_vocab` was the documented SSOT home for operator-facing wire
vocabulary. Because `capability_vocab` is a leaf module with no dependency on
`Capabilities`, it could only expose string lists, and every consumer that
needed `variant <-> wire-string` reimplemented literal matches. That was the
cycle-break bug: the leaf owned the vocabulary intent, but not the variant.

The implemented design adopts Option A from this RFC:

- `capability_vocab.ml` owns the `thinking_control_format` and
  `preserve_thinking_control_format` variants.
- It owns one exhaustive canonical-label projection for
  `thinking_control_format`, exact typed encode/decode functions, and one
  canonical table for `preserve_thinking_control_format`.
- `capabilities.ml` re-exports the variants via type/constructor aliases, so
  existing `Capabilities.*` call sites compile unchanged.
- capability manifests, model catalogs, and provider catalogs delegate the
  complete `{ label; token }` declaration to `Capability_vocab`.

The thinking-control declaration is an exact contract. Labels are compared
with `String.equal`; they are never trimmed, case-folded, or aliased. A
`Chat_template_token` preserves its token byte-for-byte, but empty,
whitespace-only, or padded tokens are rejected. Declaration absence remains
`None` and never defaults to `No_thinking_control`.

This document is therefore a design record and verification contract for the
landed implementation, not a request to perform a future relocation.

## 1. Original Evidence (2026-06-30 SSOT Audit)

This section preserves the pre-migration audit that justified the change. It
does not describe the current code after the relocation landed.

The same closed vocabulary is matched independently at:

| site | form | dimension |
|---|---|---|
| `capabilities.ml:623` `thinking_control_format_of_manifest_string` | 8-arm literal match, comment admits *"Mirrors Provider_catalog... kept local to avoid a dependency cycle"* | variant-fragmentation (P1) |
| `capabilities.ml:636` `preserve_thinking_control_format_of_manifest_string` | table + lookup, duplicated | variant-fragmentation (P1) |
| `provider_catalog.ml:206` `parse_thinking_control_format` | 8-arm literal match | string-match-classifier (P1) |
| `provider_catalog.ml:229` `parse_preserve_thinking_control_format` | 5-arm literal match | string-match-classifier (P2) |
| `capabilities.ml:670` `modality_priority_of_catalog_string` | 4-arm literal match (same pattern, `Modality` variant) | string-match-classifier |

Sibling parsers in the **same file** already delegate correctly — `parse_reasoning_replay` and `parse_assistant_tool_content_format` call `Capability_vocab.*_of_string` — proving the delegation pattern is established and these sites bypass it. The bypass exists for one reason: `capability_vocab` owns those variants (it defines `reasoning_replay_override`, `assistant_tool_content_format`) but **does not own** `thinking_control_format` (that lives in `Capabilities`, which the leaf cannot depend on).

At the time of the audit, `capability_vocab.ml:1-6` documented the intent
explicitly:
> *"This module intentionally has no dependency on Capabilities... the canonical wire vocabulary must live in a leaf module to avoid duplicate enum tables and dependency cycles."*

The pre-migration state violated that intent for `thinking_control_format`: the
enum table was duplicated because the variant was on the wrong side of the
cycle break.

## 2. Implemented Design

### 2.1 Option A — variants owned by `capability_vocab` (ADOPTED)

The variant definitions live in `capability_vocab.ml`, alongside the existing
`reasoning_replay_override` / `assistant_tool_content_format`.

`thinking_control_format` cannot use a flat `string * variant` table because
`Chat_template_token` carries caller-owned data. Its single vocabulary owner is
therefore:

- an exhaustive `canonical_label_of_thinking_control_format` projection;
- `tokenless_thinking_control_formats`, whose labels derive from that
  projection;
- `encode_thinking_control_format`, which validates the public token-bearing
  constructor and returns a typed result;
- `decode_thinking_control_format`, which accepts only an exact canonical
  `{ label; token }` pair;
- `decode_optional_thinking_control_format`, which preserves absent
  declarations and rejects orphan tokens.

The codec error family is closed: `Unknown_label`, `Token_required`,
`Token_forbidden`, and raw-preserving `Invalid_token`. Token trimming is used
only to detect invalid empty or padded input; no trimmed value is accepted or
emitted. `preserve_thinking_control_format` remains a data-less vocabulary
derived from its canonical table.

`capabilities.ml` is a consumer with a type alias and constructor re-export:

```ocaml
type thinking_control_format = Capability_vocab.thinking_control_format =
  | No_thinking_control
  | Thinking_object
  | ...
```

The OCaml constructor alias keeps `Capabilities.No_thinking_control` valid at
existing call sites, including `reasoning_dialect.ml` and the matches across
`backend_openai_request`, `backend_anthropic`, `api_openai`, and related files.
Duplicated parsers are replaced by delegation to the exact codec for thinking
control and the canonical table parser for preserve-thinking control.

**Dependency direction:** `capability_vocab` (leaf) ← `capabilities` ← everyone else. No cycle: `capability_vocab` still depends on nothing. `capabilities` already depends on `capability_vocab` (it aliases `reasoning_replay_override` today), so the new edge is not even new.

The same pattern applies to `preserve_thinking_control_format`.

### 2.2 Option B — absorb `capability_vocab` into `capabilities`

Eliminates the cycle by collapsing the leaf into the owner. Rejected: it destroys the leaf-module invariant other consumers rely on and forces every `capability_vocab` user to pull `Capabilities`.

### 2.3 Option C — functor parameterising the parser over the variant

Over-engineered for a flat 8-constructor enum. Rejected.

## 3. Completed Migration

| step | change | blast radius |
|---|---|---|
| 1 | `capability_vocab`: own both variants; derive thinking-control labels from one exhaustive projection and preserve-thinking values from one canonical table. | leaf only |
| 2 | `capabilities.ml` (+`.mli`): replace owned type defs with aliases `= Capability_vocab.*`; re-export constructors | type-only, call sites unchanged |
| 3 | capability manifest, model catalog, and provider catalog pass the raw optional label/token pair to `decode_optional_thinking_control_format`; preserve-thinking parsing still delegates to `Capability_vocab`. | parser collapse |
| 4 | exact decode rejects unknown/non-canonical labels, missing/orphan tokens, and empty or padded tokens with a typed raw-preserving error. | fail-closed contract |
| 5 | exact encode validates token-bearing public constructors instead of emitting an invalid declaration. | serializer guard |
| 6 | tests cover every format round-trip, canonical-label uniqueness, exact rejection, token preservation, absence, and all three loader boundaries. | drift guard |

The migration is complete for the thinking-control vocabularies. This RFC no
longer asks maintainers to perform these steps.

## 4. Verification Contract

- **Compiler**: aliases keep existing constructors visible while preserving
  exhaustiveness checks at match sites.
- **Single-owner proof**: every thinking-control label derives from the
  exhaustive canonical projection; no independent label table or normalizing
  parser exists.
- **Exact codec proof**: every valid format round-trips, canonical labels are
  unique, and rejected labels/tokens retain the original bytes in the typed
  error.
- **Absence proof**: a missing declaration decodes to `Ok None`; it never
  selects a default. An orphan token fails typed.
- **Delegation proof**: manifest, model-catalog, and provider-catalog loaders
  invoke the same optional codec and fail closed; they do not reproduce label
  or cross-field logic.
- **Preserve-thinking proof**: its exported values and parser remain derived
  from one canonical table.

## 5. Why not bundle into the SSOT-audit subset PRs

The 2026-06-30 audit produced three surgical PRs (#2333 provider-kind
round-trip, #2334 stop_reason wire SSOT, #2335 catch-all exhaustiveness) that
were zero-runtime-change. The original variant relocation preserved runtime
behavior. The later exact codec amendment intentionally tightens catalog-input
and public-encode behavior, so it remains isolated here rather than being
hidden inside an unrelated SSOT cleanup.

## 6. Non-goals

- `stop_reason_wire` per-backend mapping consolidation (separate variant-fragmentation finding).
- `provider_registry` `max_context` drift (262_144 hardcoded shadowing capability-verified 256_000/128_000) — semantic fix, separate PR.
- `provider.ml:335` documented dual fallback — intentional per docstring, not addressed here.
- `reasoning_dialect.streaming` dead field / `Template_parser` stub variant — related SSOT debt (the streaming-reasoning variant is declared but no live parser consumes it); tracked separately, may fold into this RFC's migration if the streaming field is also relocated.

## 7. Remaining Follow-Up

- `Modality.t` priority still follows a similar vocabulary pattern. It can be
  evaluated separately; it is not a blocker for the implemented
  `thinking_control_format` relocation.
- Any future thinking-control serializer must consume
  `encode_thinking_control_format`; it must not add a second label projection or
  bypass typed token validation.
