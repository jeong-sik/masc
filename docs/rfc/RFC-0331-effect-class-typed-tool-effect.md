# RFC-0331 — Typed tool effect class (retire the `read_only_patterns` string classifier)

- Status: Draft
- Decision driver: Ilya-30-papers adversarial transfer census (2026-07-08), axis A4's sole surviving core after the Trojan-bundle refutation: "`Effect_class.t = Read_only | Mutating` 필수 등록 필드 + exhaustive match. 문자열 분류기를 제거하는 순수 parse-don't-validate." Converges independently with the CLAUDE.md workaround-rejection signature S1 (string/substring classifier) and the RFC-0042 lineage — convergence is the validation.
- Area: `lib/verifier_core.ml:43-76` (`read_only_patterns`, `has_pattern_with_word_boundary`, `should_skip`), `lib/verifier_oas.ml:107,206,319` (the three consumers), tool registration surfaces (`Masc_domain.tool_schema`, `lib/keeper/keeper_tool_descriptor.ml` `~readonly`, `Keeper_tool_progress.effect_domain_for_tool_name`).
- Explicitly NOT in scope: the completion-claim classifier → LLM migration (RFC-0323-deferred). The original A4 proposal bundled both; the refutation showed they have opposite risk profiles (this half removes a string classifier with a typed property; that half adds a live-judge dependency to a deterministic hot path). This RFC is the typed half only.

## Problem (audited)

The verifier decides "does this action need verification at all?" by substring-matching **free text** against 18 hardcoded English patterns:

- `verifier_core.ml:43-47`: `read_only_patterns = ["read"; "glob"; "grep"; "search"; "find"; "list"; "ls"; "cat"; "head"; "tail"; "git status"; "git log"; "git diff"; "status"; "view"; "get"; "fetch"; "query"]`.
- `verifier_core.ml:71-76` `should_skip ~action_description` word-boundary-matches the lowercased description.
- Consumers (`verifier_oas.ml`):
  - `:107` `verify` returns `Ok Core.Pass` — **verification skipped entirely, fail-open** — whenever the description matches.
  - `:206` the pre-tool hook classifies `"tool:%s" tool_name` and `Continue`s past verification.
  - `:319` `read_only_predicate` feeds guardrails filters from `schema.name`.

Failure class (S1, fail-open): any *mutating* action whose description happens to contain a pattern as a word is silently exempted from verification — "delete stale user **list**", "**get** rid of the retry queue", "reset connection **status**". The classifier answers a **closed, declarable property** ("does this tool mutate?") with an open-text heuristic. Two typed axes for the same property already exist and disagree in kind:

- `keeper_tool_descriptor.ml` declares `~readonly:(true|false)` per keeper tool at registration.
- `Keeper_tool_progress.effect_domain_for_tool_name` classifies effect domains (with the documented caveat in `keeper_agent_tool_surface.ml` that its "durable evidence" axis differs from task-state mutation).

So the codebase pays for three effect-classification surfaces: two typed and partial, one stringly and fail-open at the widest boundary.

## Decision

1. **`Effect_class.t = Read_only | Mutating`** — a closed sum, declared at tool registration, required (not optional): a tool that does not declare its effect class is `Mutating`. Unknown/unregistered names are `Mutating`. Fail-closed by construction — the permissive branch is unrepresentable (parse, don't validate).
2. **The verifier consumes the declared class, never the text.** `verify` / the pre-tool hook / `read_only_predicate` take the tool's `Effect_class.t`; free-text `action_description` is never classified again.
3. **Delete** `read_only_patterns`, `has_pattern_with_word_boundary`, `should_skip` — removal, not augmentation (S1 discipline: the string classifier comes out, it does not grow a better word list).
4. **Governance stays typed.** Effect class is a protocol-boundary property (3-layer discipline: typed closed-at-source). It is not a semantic judgment; no LLM is involved, and no learned classifier replaces the list.

## Waves

| Wave | Scope | Exit criterion |
|---|---|---|
| W1 | `Effect_class` type + registration field + plumbing to the three `verifier_oas.ml` consumers, default `Mutating` for undeclared | unknown tool → `Mutating` → verification runs (pin) |
| W2 | Delete `verifier_core.ml:43-76` classifier + its tests; drift guard: `rg 'read_only_patterns'` = 0 | fail-open skip class unrepresentable |
| W3 | Reconcile the keeper `~readonly` axis: either `Effect_class` becomes the SSOT that `keeper_tool_descriptor` reads, or the mapping between the two axes is a total function with an exhaustive-match pin | one declared source of effect truth |

## Verification

- Unit pins: declared `Read_only` → skip path; declared `Mutating` → verify path; undeclared → verify path (fail-closed default). A regression test with a mutating description containing "list"/"get"/"status" words must NOT skip.
- Workaround-gate self-check: this PR *removes* an S1 signature; any future PR re-adding a name/description pattern list to the verifier skip path is an S1 reject.
- TLA+ not required: no concurrency/state-machine change; the property is a total function from registration data.

## Boundaries (untouched)

- Verification *content* (prompt, verdict parsing, `parse_verdict_from_json`) — unchanged.
- `Keeper_tool_progress.effect_domain_for_tool_name`'s durable-evidence axis — documented as a different axis (`keeper_agent_tool_surface.ml`), reconciled only in W3 and only if the mapping is total.
- Completion-claim classification — RFC-0323 lane, explicitly out of scope here.

## Evidence record

- Evidence: `lib/verifier_core.ml:43-76`, `lib/verifier_oas.ml:107,206,319`, `lib/keeper/keeper_tool_descriptor.ml` (`~readonly`), census artifact e1d4ba86 (axis A4, WEAKENED→surviving core), fresh-read re-verified 2026-07-09 at `63b5a69975`.
- Confidence: High (all cited lines re-read at HEAD before this draft).
- Delta: replaces the A4 Trojan bundle with its typed half only; the LLM half stays deferred to RFC-0323's lane.
