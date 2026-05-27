---
title: Cascade phonebook typed roundtrip for protocol/flavor/provider identifiers
rfc: "0184"
status: Draft (Deferred)
created: 2026-05-27
updated: 2026-05-27
author: vincent
supersedes: []
superseded_by: null
related: ["0172", "0173", "0181"]
implementation_prs: []
---

# RFC-0184 — Cascade phonebook typed roundtrip

Status: **Draft (Deferred until RFC-0181 architect decision)**
Related:
- RFC-0172 (big-bang vendor purge across docs/audits/RFCs/design-system/dashboard tests, PR #18232, merged 2026-05-24)
- RFC-0173 (`refactor(ocaml): purge vendor names from lib/bin/test identifiers + string literals`, commit `6426b841d`)
- RFC-0181 (Cascade SSOT skeleton, PR #18697 OPEN, Q1~Q5 architect decision pending)

## 0. Problem framing

`lib/cascade/cascade_phonebook_types.ml` defines typed sum types for `cascade_server_flavor` (`Llama_cpp | Ollama | Vllm | Provider_d_wire | Provider_g_wire | Provider_k_zai | Provider_h_wire`) and `cascade_protocol` (`Openai_http | Ollama_http | Provider_a_http | Openai_cli`). String roundtrip is hand-rolled via `flavor_of_string` / `flavor_to_string` / `protocol_of_string` / `protocol_to_string`, with literal forms `"provider_d"`, `"provider_g"`, `"zai-provider_k"`, `"provider_h"`, `"provider_d-http"`, `"provider_a-http"`, `"provider_d-cli"`.

This produces two compounding fragilities:

### Fragility 1 — string literals are unguarded by the type system

Adding a new flavor adds a variant and forces an exhaustive `match` update — that part is fine. But the *string form* picked for the new variant has no compiler-checked relationship to the fixture or runtime TOML. Drift between the literal (`"provider_d"`), the fixture (`provider_d-http`), and the runtime config (`~/.masc/config/cascade.toml`'s `protocol = "provider_d-http"`) is only caught by tests, and only the tests that happen to exercise that path.

PR #18837's dropped commit `1e0f96365` ("fix(cascade): accept hyphenated protocol/flavor strings in phonebook parser", 2026-05-27) is the concrete evidence: an LLM-authored fix claimed PR #18232 had renamed fixtures from underscore to hyphen, but main fixture (`test/test_cascade_phonebook.ml`), branch base fixture (`57ac702a245`), and runtime `~/.masc/config/cascade.toml` were *all* still underscore. The "fix" introduced an inconsistency it then patched with alt-form parsing (`"provider-d" | "provider_d" -> Provider_d_wire`). This is CLAUDE.md §워크어라운드 §2 (string/substring classifier 보강) verbatim — `pr-rfc-check.sh --workaround-gate-only` would have flagged it at push time.

### Fragility 2 — generic placeholder names are semantically empty

RFC-0172/0173 vendor purge replaced vendor names (`anthropic`, `openai`, `deepseek`, `groq`, `zai`) with placeholders (`provider_d`, `provider_g`, `provider_h`, `provider_k`). The typed OCaml variants kept their semantics in trailing comments (`Provider_d_wire (** canonical: SSE, reasoning_effort, web_search, parallel_tool_calls *)`), but the string surface lost all meaning. A reader of `~/.masc/config/cascade.toml` who sees `protocol = "provider_d-http"` cannot tell what wire format it commits to without bouncing through `cascade_phonebook_types.ml`.

`"zai-provider_k"` is the proof — the purge stripped vendors but left `zai-` as a partial prefix, because the variant name (`Provider_k_zai`) preserved the vendor reference. The string surface is now half-purged, half-vendor, half-placeholder.

## 1. Root cause

Hand-written `_of_string` / `_to_string` functions with literal alternatives are the *implementation*, not the *interface*. The interface a TOML fixture exposes is "give me a `cascade_protocol`," but there is no machine-readable schema that says what string forms are valid. Each new format variant requires manual literal addition in two functions, with no exhaustiveness guarantee that the inverse pair stays consistent. Test-driven discovery of drift is the current safety net.

The right interface is either:
- a generated serializer from a single schema (ATD/PPX), so the typed variant *is* the source of truth and string roundtrip is mechanical, or
- elimination of the string indirection — use sexp/TOML's own variant encoding so the variant constructor name *is* the wire form, or
- a closed enum schema (e.g. `[@@deriving enum]` with a single canonical string) so adding alt forms is a deliberate, audited act with a single point of edit.

## 2. Proposal sketch

This RFC is **deferred**. RFC-0181 (Cascade SSOT skeleton, PR #18697 OPEN) is mid-review and its Q1~Q5 architect decisions cover capability granularity, tier-group semantics, and routing policy — the boundary RFC-0184 sits on top of. Locking a typed-roundtrip design before RFC-0181 commits to a capability schema risks doing the work twice.

Sketch of the proposed direction (subject to RFC-0181 outcome):

| Option | Mechanism | Drift surface | Migration cost |
|---|---|---|---|
| **A. ATD/PPX deserialization** | TOML parser generated from a single ATD schema or `[@@deriving of_toml]` PPX. Variant constructor *is* the wire form (e.g. ATD `<json name>` maps to constructor name). | Zero — the schema is the contract. | Medium — schema authoring + caller migration, but no behavior change. |
| **B. Restore vendor names** | Reverse RFC-0172/0173 for cascade phonebook only. `"openai-http"` instead of `"provider_d-http"`. | Same as today, but at least the literal carries meaning. | Low (code) + needs IP/legal sign-off on why vendor names were purged in the first place. |
| **C. Closed-enum single-form** | One canonical literal per variant, explicit `Result.t` rejection of all alt forms. No `|`-alternation in match arms. Drift detection via a CI ratchet (`pr-rfc-check.sh` extension). | Zero in code; drift in fixture vs runtime caught at parse time. | Lowest — only the alt-form branches deleted, plus the CI ratchet. |

Recommendation pending RFC-0181 decision: **A** if RFC-0181 introduces new typed surfaces (consistent generation pipeline), **C** as a holding pattern if RFC-0181 stays string-based.

## 3. Out of scope

- Vendor name restoration (option B) requires legal/IP review of the RFC-0172/0173 purge rationale — not in scope here.
- `cascade.toml` per-tier-group / per-provider field renames (covered by RFC-0181 §Q3-Q5).
- Runtime config migration from `~/.masc/config/cascade.toml` to a versioned schema (separate RFC if A is picked).

## 4. Verification plan (when activated)

- Acceptance: `flavor_to_string >> flavor_of_string = Ok` for every constructor (qcheck or hand-rolled property). Same for `protocol`.
- Drift gate: `pr-rfc-check.sh --workaround-gate-only` extension that flags any new `| "foo" | "bar" ->` alt-form arm in `lib/cascade/cascade_phonebook_types.ml` as `WORKAROUND` requiring §override 3-line label.
- Regression: existing `test_cascade_phonebook` 24/24 must continue PASS after the migration.
- Smoke: runtime `~/.masc/config/cascade.toml` parses unchanged, hot-reload preserves every (protocol, flavor, provider) tuple.

## 5. Why this RFC matters even while deferred

Without RFC-0184 the next LLM-authored "fix" hits the same false-premise trap. PR #18837 commit `1e0f96365` consumed reviewer + author + force-push cycles for a zero-progress change. Recording the antipattern in an RFC (rather than only in a memory note) lets `pr-rfc-check.sh --workaround-gate-only` reference RFC-0184 in the gate message when a future PR introduces a string-classifier alt-form on cascade identifiers.

Interim mitigation (no code change): add an entry to `pr-rfc-check.sh`'s grep that catches `| "provider[_-][a-z]" ->` patterns in `lib/cascade/cascade_phonebook_types.ml` and requires `WORKAROUND: RFC-0184 deferred` or `WORKAROUND-WAIVED:` in the PR body.

## 6. Implementation status

| Stage | Status |
|---|---|
| RFC draft | This commit |
| RFC-0181 architect decision (Q1~Q5) | **Blocking** — RFC body cannot finalize Option A vs C until cascade SSOT shape settles |
| Interim `pr-rfc-check.sh` gate (cascade string-classifier) | Pending (this PR can include it as a small additional change, or split) |
| ATD/PPX migration PR | Pending RFC activation |

## 7. Evidence Record

- **Evidence**: 
  - `lib/cascade/cascade_phonebook_types.ml` lines 17-44 (current hand-rolled `_of_string` / `_to_string` with literal alt-forms)
  - PR #18837 commit `1e0f96365` body (false-premise documentation) + diff vs main (`provider_d-http` vs `provider-d-http`)
  - `git show 57ac702a245:test/test_cascade_phonebook.ml | rg "protocol = "` → all `provider_d-http` (underscore)
  - `git show origin/main:test/test_cascade_phonebook.ml | rg "protocol = "` → all `provider_d-http` (underscore)
  - `rg "^protocol\s*=" ~/me/.masc/config/cascade.toml` → all `provider_d-http` (underscore)
  - PR #18232 (RFC-0172 vendor purge) merged 2026-05-24, commit `6426b841d` (RFC-0173)
  - PR #18697 (RFC-0181) OPEN, Q1~Q5 architect decision pending per memory
- **Timestamp**: 2026-05-27
- **Confidence**: High on §0/§1 (concrete drift evidence). Medium on §2 option choice (depends on RFC-0181 outcome — flagged Deferred).
- **Delta**: First RFC capturing the cascade phonebook string-classifier antipattern. Previously only documented in CLAUDE.md §워크어라운드 §2 abstract; now anchored to a concrete subsystem with reproducible drift evidence.
