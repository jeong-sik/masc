---
title: Runtime phonebook typed roundtrip for protocol/flavor/provider identifiers
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

# RFC-0184 — Runtime phonebook typed roundtrip

Status: **Draft (Deferred until RFC-0181 architect decision)**
Related:
- RFC-0172 (big-bang vendor purge across docs/audits/RFCs/design-system/dashboard tests, PR #18232, merged 2026-05-24)
- RFC-0173 (`refactor(ocaml): purge vendor names from lib/bin/test identifiers + string literals`, commit `6426b841d`)
- RFC-0181 (Runtime SSOT skeleton, PR #18697 OPEN, Q1~Q5 architect decision pending)

## 0. Problem framing

The old runtime phonebook module was removed by the RFC-0181/RFC-0206 runtime
rebirth. The remaining string boundary is now the TOML parser:
`lib/runtime/runtime_toml.ml` maps provider `protocol` strings through
`api_format_of_protocol`, then stores the parsed result in
`Runtime_schema.provider.api_format`. Current accepted literals include
`"provider_a-cli"`, `"provider_a-http"`, `"chat_completions_v1_cli"`,
`"chat_completions_v1_http"`, `"provider_f-cli"`, `"provider_c-cli"`, and
`"ollama-http"`.

This produces two compounding fragilities:

### Fragility 1 — string literals are unguarded by the type system

Adding a new protocol literal requires a manual branch in
`Runtime_toml.api_format_of_protocol`, plus fixture/runtime TOML updates. The
literal has no compiler-checked relationship to the runtime schema value it
selects. Drift between the accepted string (`"chat_completions_v1_http"`), test
fixtures, and `<MASC_BASE>/.masc/config/keeper_runtime.toml` is only caught by
tests, and only the tests that happen to exercise that path.

PR #18837's dropped commit `1e0f96365` ("fix(runtime): accept hyphenated
protocol/flavor strings in phonebook parser", 2026-05-27) is the concrete
evidence: an LLM-authored fix claimed PR #18232 had renamed fixtures from
underscore to hyphen, but the main fixtures and runtime
`<MASC_BASE>/.masc/config/keeper_runtime.toml` were still underscore. The old
phonebook module no longer exists; the same failure mode now lives at the TOML
parser string boundary. This is CLAUDE.md §워크어라운드 §2 (string/substring
classifier 보강) verbatim — `pr-rfc-check.sh --workaround-gate-only` would have
flagged it at push time.

### Fragility 2 — generic placeholder names are semantically empty

RFC-0172/0173 vendor purge replaced vendor names (`anthropic`, `openai`,
`deepseek`, `groq`, `zai`) with placeholders (`chat_completions_v1`,
`provider_g`, `provider_h`, `provider_k`). The typed OCaml schema keeps only
`Messages_api`, `Chat_completions_api`, and `Ollama_api`; provider-specific
semantics live in parser literals and provider bindings. A reader of
`<MASC_BASE>/.masc/config/keeper_runtime.toml` who sees
`protocol = "chat_completions_v1_http"` cannot tell what wire format it commits
to without bouncing through `runtime_toml.ml` and `runtime_schema.ml`.

`"provider_a-http"` is the proof — the purge stripped vendors from the name,
but the placeholder still carries no protocol semantics by itself. The string
surface is now placeholder-heavy and requires parser context to understand.

## 1. Root cause

Hand-written TOML string classifiers are the *implementation*, not the
*interface*. The interface a TOML fixture exposes is "give me a protocol," but
there is no machine-readable schema that says what string forms are valid. Each
new format variant requires manual literal addition, with no exhaustiveness
guarantee tying the string to the `Runtime_schema.api_format`. Test-driven
discovery of drift is the current safety net.

The right interface is either:
- a generated serializer from a single schema (ATD/PPX), so the typed variant *is* the source of truth and string roundtrip is mechanical, or
- elimination of the string indirection — use sexp/TOML's own variant encoding so the variant constructor name *is* the wire form, or
- a closed enum schema (e.g. `[@@deriving enum]` with a single canonical string) so adding alt forms is a deliberate, audited act with a single point of edit.

## 2. Proposal sketch

This RFC is **deferred**. RFC-0181 (Runtime SSOT skeleton, PR #18697 OPEN) is mid-review and its Q1~Q5 architect decisions cover capability granularity, runtime semantics, and routing policy — the boundary RFC-0184 sits on top of. Locking a typed-roundtrip design before RFC-0181 commits to a capability schema risks doing the work twice.

Sketch of the proposed direction (subject to RFC-0181 outcome):

| Option | Mechanism | Drift surface | Migration cost |
|---|---|---|---|
| **A. ATD/PPX deserialization** | TOML parser generated from a single ATD schema or `[@@deriving of_toml]` PPX. Variant constructor *is* the wire form (e.g. ATD `<json name>` maps to constructor name). | Zero — the schema is the contract. | Medium — schema authoring + caller migration, but no behavior change. |
| **B. Restore vendor names** | Reverse RFC-0172/0173 for runtime phonebook only. `"openai-http"` instead of `"chat_completions_v1_http"`. | Same as today, but at least the literal carries meaning. | Low (code) + needs IP/legal sign-off on why vendor names were purged in the first place. |
| **C. Closed-enum single-form** | One canonical literal per variant, explicit `Result.t` rejection of all alt forms. No `|`-alternation in match arms. Drift detection via a CI ratchet (`pr-rfc-check.sh` extension). | Zero in code; drift in fixture vs runtime caught at parse time. | Lowest — only the alt-form branches deleted, plus the CI ratchet. |

Recommendation pending RFC-0181 decision: **A** if RFC-0181 introduces new typed surfaces (consistent generation pipeline), **C** as a holding pattern if RFC-0181 stays string-based.

## 3. Out of scope

- Vendor name restoration (option B) requires legal/IP review of the RFC-0172/0173 purge rationale — not in scope here.
- `keeper_runtime.toml` per-runtime / per-provider field renames (covered by RFC-0181 §Q3-Q5).
- Runtime config migration from `<MASC_BASE>/.masc/config/keeper_runtime.toml` to a versioned schema (separate RFC if A is picked).

## 4. Verification plan (when activated)

- Acceptance: every supported protocol literal in runtime TOML parses to the
  intended `Runtime_schema.api_format`, and every fixture/runtime config uses a
  literal accepted by `Runtime_toml.api_format_of_protocol`.
- Drift gate: `pr-rfc-check.sh --workaround-gate-only` extension that flags any
  new alternate string-classifier arm in `lib/runtime/runtime_toml.ml` as
  `WORKAROUND` requiring §override 3-line label.
- Regression: runtime TOML parser tests must continue PASS after the migration.
- Smoke: runtime `<MASC_BASE>/.masc/config/keeper_runtime.toml` parses unchanged,
  hot-reload preserves every (protocol, provider, model) tuple.

## 5. Why this RFC matters even while deferred

Without RFC-0184 the next LLM-authored "fix" hits the same false-premise trap. PR #18837 commit `1e0f96365` consumed reviewer + author + force-push cycles for a zero-progress change. Recording the antipattern in an RFC (rather than only in a memory note) lets `pr-rfc-check.sh --workaround-gate-only` reference RFC-0184 in the gate message when a future PR introduces a string-classifier alt-form on runtime identifiers.

Interim mitigation (no code change): add an entry to `pr-rfc-check.sh`'s grep
that catches alternate provider/protocol string arms in
`lib/runtime/runtime_toml.ml` and requires `WORKAROUND: RFC-0184 deferred` or
`WORKAROUND-WAIVED:` in the PR body.

## 6. Implementation status

| Stage | Status |
|---|---|
| RFC draft | This commit |
| RFC-0181 architect decision (Q1~Q5) | **Blocking** — RFC body cannot finalize Option A vs C until runtime SSOT shape settles |
| Interim `pr-rfc-check.sh` gate (runtime string-classifier) | Pending (this PR can include it as a small additional change, or split) |
| ATD/PPX migration PR | Pending RFC activation |

## 7. Evidence Record

- **Evidence**: 
  - `lib/runtime/runtime_toml.ml` `api_format_of_protocol` (current hand-rolled protocol string classifier)
  - PR #18837 commit `1e0f96365` body (false-premise documentation) + diff vs main (`provider_d-http` vs `chat_completions_v1_http`)
  - `rg 'protocol = "chat_completions_v1_http"' test lib/runtime` → runtime TOML fixtures and parser fixtures use the underscore form
  - `rg "^protocol\s*=" <MASC_BASE>/.masc/config/keeper_runtime.toml` → all `chat_completions_v1_http` (underscore)
  - PR #18232 (RFC-0172 vendor purge) merged 2026-05-24, commit `6426b841d` (RFC-0173)
  - PR #18697 (RFC-0181) OPEN, Q1~Q5 architect decision pending per memory
- **Timestamp**: 2026-05-27
- **Confidence**: High on §0/§1 (concrete drift evidence). Medium on §2 option choice (depends on RFC-0181 outcome — flagged Deferred).
- **Delta**: First RFC capturing the runtime phonebook string-classifier antipattern. Previously only documented in CLAUDE.md §워크어라운드 §2 abstract; now anchored to a concrete subsystem with reproducible drift evidence.
