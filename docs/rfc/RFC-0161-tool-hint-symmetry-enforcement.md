---
rfc: "0161"
status: Draft
author: claude-opus
created: 2026-05-21
related: ["0148"]
---

# RFC-0161 — Tool Error Hint Symmetry Enforcement

## §1 Motivation

Team BBB iter#14 found D8 in `lib/tool_code_write.ml`:

- `count = 0` branch (line 497-530) emits a **3-sample contextual hint** —
  surfaces up to 3 lines containing the first-line needle of `old_string`,
  letting the LLM correct whitespace/indent in the next attempt
  *without re-reading the whole file*.
- `count > 1 && not replace_all` branch (line 531-534) emits **only a numeric
  count** — `"old_string found %d times. Use replace_all=true or provide
  more context"`. No line numbers. No surrounding context. No samples.

Both branches answer the same operator question *"where did your match
miss?"*, but only the `count = 0` branch answers it usefully. The LLM
sees `found 3 times` and must re-read the file blind to disambiguate,
producing a retry storm. D8 fixes this specific site by adding sample
line numbers to the `count > 1` branch.

**Generalization.** D8's asymmetry is an instance of a broader anti-pattern:

> When a tool emits errors from two branches that share an underlying
> question ("where/which/how-many"), and one branch supplies a rich
> hint while the other emits only a metric or bare phrase, the
> resulting LLM retry behavior degrades on the metric-only branch.

This RFC names the pattern (**Tool Error Hint Asymmetry**), inventories
known sites, and proposes a closed-set protocol for new tool error
branches.

### Why generalize now

- D8 was found by manual code-read, not by lint. Other instances are
  invisible to current tooling.
- Audit (§4) shows at least one other site (`tool_keeper.ml` keeper
  not-found) emits a bare phrase where a "did you mean?" hint with
  candidate names would resolve >50% of retries.
- RFC-0148 (typed `tool_error`) addresses the *envelope* but is
  orthogonal to *hint content quality*. A typed `tool_error` can still
  carry an information-poor message.

## §2 Non-goals

- **Not** redefining tool dispatch or the `tool_result.t` shape.
- **Not** mandating perfect hints for every tool error — that is
  scope creep (see §8).
- **Not** introducing a new error taxonomy. Closed-set is "same level
  of detail across branches answering the same operator question."
- **Not** requiring multi-language NLP or fuzzy matching. The protocol
  is structural symmetry, not message richness in the abstract.

## §3 Design

### §3.1 Symmetry protocol (closed-set)

When a tool emits an error from a branch B1 and another branch B2 of
the **same predicate family** (success-precondition vs.
failure-precondition over the same resource), both branches MUST emit
the same level of detail along three axes:

| Axis | Example | Symmetric required? |
|------|---------|---------------------|
| **Locator** | line number, byte offset, candidate name | Yes |
| **Sample** | up to N matched lines, up to N near-name candidates | Yes |
| **Operator advice** | suggested next action ("Use replace_all=true", "Did you mean X?") | Yes |

A branch may choose to emit *less* detail only when the underlying
resource cannot supply it (e.g. `File not found` has no in-file line
numbers because the file does not exist). The asymmetry test is:

> If branch B1 can compute hint H, and branch B2 operates on the same
> resource as B1, then B2 must either compute H or document why H is
> structurally unavailable.

### §3.2 Predicate families

Initial families to audit (closed list, extensible by RFC amendment):

1. **String-match arity**: 0 / 1 / N matches (D8 case).
2. **Name resolution**: exact / alias / candidate-near / not-found.
3. **Path resolution**: existing-file / existing-dir / not-found /
   no-permission.
4. **State arity**: 0 / 1 / N matching states (e.g. pending approval
   not found, multiple matching tasks).

### §3.3 Enforcement

Two options (decision deferred to §9):

- **(A) Lint rule.** Custom ppx or AST scanner that flags tool error
  branches lacking line/sample/advice when a sibling branch supplies
  one. Risk: structural detection is hard; false-positive heavy.
- **(B) Convention + review checklist.** Each `lib/tool_*.ml` PR adds
  a one-line check: *"if this PR adds or modifies a tool error
  branch, do sibling branches in the same predicate family emit the
  same detail level?"*. Cheaper, lower coverage.

## §4 Audit — known asymmetric sites

Scan: `rg -n 'no matches|multiple matches|ambiguous|found .* times'
lib/tool_*.ml` plus targeted reads.

| File:line | Predicate family | Branch with rich hint | Branch with poor hint | Severity |
|-----------|------------------|-----------------------|-----------------------|----------|
| `lib/tool_code_write.ml:497-534` | String-match arity (0/N) | `count = 0` emits 3 samples | `count > 1` emits only `%d times` | High (D8) |
| `lib/tool_keeper.ml:484-487, 556` | Name resolution | `also tried %s` shows stripped variant | bare `keeper not found: %s` (no near-name candidates) | Medium |

Two confirmed sites. Audit is not exhaustive — §6 schedules per-tool
sweeps. No automated scanner exists yet; severity is hand-graded.

### Counter-example (acceptable asymmetry)

`lib/tool_code_write.ml:469` (`File not found: %s`) vs `:514`
(`old_string not found in file` with first-line sample) — different
predicate families (path resolution vs. string-match arity).
Asymmetry here is structural, not a defect.

## §5 Workaround self-check (against `software-development.md`)

Per the §"워크어라운드 거부 기준" 7-item checklist:

1. **Telemetry-as-fix?** No — this RFC mandates *richer hints*, not
   counters/metrics.
2. **String classifier?** No — the protocol is structural symmetry over
   predicate families, no string match added.
3. **N-of-M patch?** Risk yes — D8 alone is 1-of-2 known sites.
   Mitigated: §4 audit explicitly inventories sites; §6 schedules
   per-tool sweep, not site-by-site PRs.
4. **Catch-all `_ ->` added?** No.
5. **Cap/cooldown/dedup/repair?** No — protocol is positive (add hint),
   not suppressive.
6. **Test backdoor?** No — acceptance test in §7 is operator-observable
   retry-rate metric.
7. **Same typo/off-by-one in N sites?** Partially yes — D8 + keeper
   not-found are structurally similar omissions. Codemod is *not*
   feasible (each hint requires resource-specific computation), so §6
   mandates **manual sweep with the §3.1 protocol as a checklist**, not
   mechanical patch.

Score: 2 of 7 risk flags, both mitigated. Acceptable.

## §6 Migration

Per-tool sweep, one PR per `lib/tool_*.ml` containing user-visible
errors:

1. List all `Tool_result.error` / `Error ...` sites in the file.
2. Group by predicate family (§3.2).
3. For each group with ≥2 branches, apply the §3.1 symmetry test.
4. Where symmetric, add the missing hint to the poor-hint branch.
5. Where structurally asymmetric (counter-example case), add a
   one-line comment naming the family difference.
6. Add a focused test exercising the previously-poor branch and
   asserting the new hint shape.

Estimated scope: D8 (`tool_code_write.ml`) and `tool_keeper.ml` are
the only confirmed sites today. Per-tool audit will surface more.
Each PR ≤ ~150 LoC, no godfile expansion.

## §7 Acceptance

Measurable on production telemetry (existing keeper retry counters):

- 24h asymmetry-induced retries (LLM re-invokes same tool with same or
  near-identical args within ≤2 turns after error) reduced by **≥50%**
  on swept tools.
- No regression in non-error tool latency (hint computation must be
  cheap — bounded by O(file lines) for D8-class, O(name set) for
  keeper-class).
- New tool error branches added after this RFC pass the §3.1
  symmetry test at PR review (subject to §9 enforcement choice).

## §8 Risks

- **Scope creep.** Could be misread as "every tool error must have a
  perfect hint." Explicitly out of scope (§2). Symmetry only — if both
  branches are equally bare, that is acceptable under this RFC
  (though arguably bad UX, that is a separate concern).
- **Lint false positives.** §3.3 option (A) risk. If chosen,
  initial rule must operate on AST patterns, not string heuristics,
  to avoid recurrence of `software-development.md` §"String/Substring
  분류기 보강" anti-pattern.
- **Audit incompleteness.** §4 is hand-graded. The first round of
  per-tool sweeps (§6) may surface more sites than estimated.
- **Hint computation cost.** Adding samples requires reading file
  content or scanning candidate sets. Already paid on the
  rich-hint branch, so symmetric extension is bounded.

## §9 Open questions

1. **Lint vs convention.** §3.3 (A) lint rule vs (B) review checklist.
   Lint has higher cost upfront and false-positive risk; convention has
   lower cost but degrades over time. Default proposal: start with
   (B) for 2 months, escalate to (A) only if a regression is observed.
2. **Predicate family extension.** §3.2 lists 4 initial families. New
   families should be added by RFC amendment or by an explicit
   `families.md` SSOT under `docs/rfc/RFC-0161/`. Which?
3. **Relationship to RFC-0148.** RFC-0148 introduces a typed
   `tool_error` variant. Should this RFC's hint protocol be encoded
   in the variant constructor's payload type (e.g. a `hint :
   structured_hint option` field), or remain a free-form string with
   review-time checking? Encoding in the type is stronger but
   couples two RFCs.
4. **Threshold for "same predicate family."** §3.1 leaves the test
   informal. A future amendment may need a more precise grouping —
   e.g. by the type of the input that triggers each branch.
