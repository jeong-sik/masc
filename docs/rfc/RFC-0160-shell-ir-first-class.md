---
rfc: "0160"
title: "Shell IR 1급 승격 — single-source decision substrate across producer/classifier/gate/dispatch"
status: Active
created: 2026-05-23
updated: 2026-05-23
author: vincent
supersedes: []
superseded_by: null
related: ["0042", "0086", "0088", "0091", "0107", "0142", "0154"]
implementation_prs: [17873, 17884]
---

## §0 · Context

Post-P9 (typed gh argv, PR #17797) + post-P13a (keeper_gh_shared dead-surface
purge, PR #17865), an inventory of `Masc_exec.Shell_ir` usage across `lib/`
showed 61 files referencing it, 45 non-test IR constructor sites, and 10
non-test callers of `Bash.parse_string`. The shape that surfaced: **Shell
IR sits as a transit envelope between parser and dispatch, not as a
single-source decision substrate**.

Five drift signals:

| # | Signal | Surface |
|---|--------|---------|
| 1 | 병렬 파싱 | `Bash.parse_string` (8 callers) + `Bash_words.stages` / `shell_word_values` (16 refs across 4 files) parse the same input twice |
| 2 | 병렬 typed shape | `Shell_ir.simple` (lib/exec/) and `gh_simple_command` (lib/keeper/keeper_gh_shared) are two typed argv shapes; gh op uses the latter directly, bypassing Shell IR |
| 3 | Decision-by-string | `keeper_shell_bash.ml:109,121` calls `is_destructive_bash_operation cmd:string` / `is_write_operation cmd:string` *before* the same input is lowered to IR. The IR carries no decision |
| 4 | Stamp-less IR | `Shell_ir.simple = { bin; args; env; cwd; redirects; sandbox }` carries no risk / mutation / reversibility metadata; every consumer recomputes |
| 5 | Producer 비대칭 | Producer B (typed argv → IR via `to_shell_ir`, RFC-0091) has exactly one caller (op=bash). Other keeper ops (gh/git/repo_git/code_write) lower from string or bypass IR |

The SSOT plan that frames this RFC is at
`~/me/memory/shell-ir-first-class-promotion-todo-2026-05-23.html`.

## §1 · Goals (verifiable end-state)

Seven KPIs (`scripts/audit-shell-ir-consumption.sh` measures all of them):

| Goal | Metric | Baseline (HEAD `b964f49`) | Target |
|------|--------|---------------------------|--------|
| G1 | `Bash.parse_string` non-test caller files | 10 / 15 refs | ≤ 3 |
| G2 | Mutation classifier signatures | string=2, IR=0 | string=0, IR≥2 |
| G3 | `Shell_command_gate.gate_typed` refs in `lib/keeper/` | 2 | ≥ 4 (one per keeper op) |
| G4 | Risk-stamped IR existence (`risk` field or `'decided` phantom) | 0 | ≥ 1 |
| G5 | `validate_shell_ir_paths` non-test caller files | 4 | ≥ 4 (already met) |
| G6 | `specs/shell-ir-first-class/ShellIRFirstClass.tla` exists | 1 | 1 |
| G7 | Parallel parser refs (`shell_word_values` + `Bash_words.stages`) | 26 | 0 |

## §2 · Non-goals

- Reviving the `Eval_gate.detect_destructive` raw-string evasion check
  inside the IR-typed classifier. Evasion lives upstream of parsing
  (raw-string boundary) and stays separate (RFC-0160 §S1).
- Replacing all string-based safety in hooks (`.claude/hooks/git_guard.ml`
  uses substring matching). Out of scope; recorded as future RFC
  candidate in §S6.
- Touching MASC-coord state machine. The Shell IR shape is orthogonal
  to the keeper lifecycle FSM (RFC-0135).

## §3 · Phase plan

Seven phases. Each closes against a subset of G1-G7. Phases stack
sequentially; no parallel sprints (parent merge → child rebase order
strict).

### S0 · Baseline + RFC + measurement script

- `scripts/audit-shell-ir-consumption.sh` (PR #17873, merged) emits
  text / JSON / `--baseline FILE` diff modes. The diff mode exits 1
  when G1 or G7 regresses, suitable for CI ratchet (S7).
- `scripts/shell-ir-consumption-baseline.json` frozen as
  reproducibility anchor.
- This RFC body.

**Status**: `scripts/audit-shell-ir-consumption.sh` merged.
RFC body PR: pending merge of this PR.

### S1 · Mutation classifier IR-only

Migrate `is_write_operation`, `is_git_branch_switch`,
`is_destructive_bash_operation` from `cmd:string` to
`Masc_exec.Shell_ir.t`.

- New helper `flat_stage_words : Shell_ir.t -> string list` flattens
  `Simple` and `Pipeline` literal args into the historical word-list
  shape consumed by the existing `match parts with "git" :: ...`
  arms — no semantic change to the closed sub-command sets.
- `keeper_shell_bash.ml:109,121` reorders to **lower-then-classify**:
  `to_shell_ir` runs once, both classifiers consume the resulting IR.
- `exec_core.ml` callers (3 sites: family/reversibility/risk inference
  from `cmd:string`) stay on `_of_string` transitional wrappers; S4
  retires them.
- `Eval_gate.detect_destructive` fallback dropped from
  `is_destructive_bash_operation` — typed argv cannot carry shell-level
  evasion patterns by construction.

**Status**: PR #17884 (merged 2026-05-23). G2 hit (string=0, IR=2).

### S2 · gh op → Shell IR lift

`keeper_shell_ops.ml:1149+` gh handler currently:
1. parses raw `cmd:string` via `parse_simple_gh_command` →
   `gh_simple_command` (typed argv, lib/keeper/keeper_gh_shared);
2. renders back to string for `Worker_dev_tools.classify_gh_reversibility`;
3. dispatches via `Exec_gate.run_argv_with_status` with manually-built
   `gh_argv = "gh" :: gh_simple_command_argv parsed_command`.

`Shell_command_gate.gate_typed` and `validate_shell_ir_paths` are
**not** in this path.

S2 introduces `gh_simple_command_to_shell_ir : gh_simple_command ->
sandbox:Sandbox_target.t -> Shell_ir.t` (lib/keeper/keeper_gh_shared).
gh handler then routes IR through the same single gate + path validator
that op=bash uses. `gh_simple_command` becomes a *parse-stage* typed
shape (kept for the parser sub-grammar); the *dispatch* shape is
unified to `Shell_ir.t`.

`classify_gh_reversibility` migrates to `Shell_ir.t -> reversibility`
in S2 to consume the IR consistently (substring rendering is no longer
necessary).

**Closes**: G3 (`gate_typed` 2 → 4+).

### S3 · Risk-stamped IR (1급 승격 핵심)

Two design options. **Default: B (phantom envelope)**. Final selection
in the S3 PR body.

#### Option A — record extension

```ocaml
type simple = {
  bin : Bin.t;
  args : arg list;
  env : (string * arg) list;
  cwd : Path_scope.t option;
  redirects : Redirect_scope.t list;
  sandbox : Sandbox_target.t;
  risk : risk_class;     (* NEW *)
}
```

Every record literal `Shell_ir.Simple { bin; args; ... }` requires an
explicit `risk` value; 42 producer sites touched. Smart constructor
`Shell_ir.simple_decided ~classifier` is the only entry-point that
*runs* the classifier; record literal escape hatch moves to
`shell_ir_unsafe.ml` (consumers outside the classifier are forced
through the smart path).

#### Option B — phantom envelope

```ocaml
type undecided
type decided

type 'phase t = ...    (* Shell_ir.t carries phase marker *)
type 'phase decided_ir = { ir : 'phase t; risk : risk_class }

val classify : undecided t -> decided decided_ir
```

Existing `Simple { ... }` record literals unchanged. Type-level
invariant: `Exec_dispatch.dispatch : decided decided_ir -> ...`
refuses an undecided IR. Producer sites that haven't run the
classifier fail to typecheck.

#### Risk class taxonomy (both options share)

```ocaml
type risk_class =
  | R0_Read
  | R1_Reversible_mutation
  | R2_Irreversible
  | Destructive_protected
```

`Worker_dev_tools.gh_reversibility` (R0/R1/R2) +
`Mutation_classifier.is_destructive_bash_operation` (Destructive_protected)
become inhabitants of this single type. Caller branches use exhaustive
match.

**Closes**: G4 (`risk` stamped) + ensures S1's classifier output is
*reused* by every downstream consumer instead of recomputed.

### S4 · Parser entry consolidation

8 non-test `Bash.parse_string` callers (post-S1 baseline = 12 incl.
transitional wrappers). Migrate to typed-argv producers where the
caller already has structured input:

| Caller | Current input | Target |
|--------|---------------|--------|
| `spawn.ml:263` (`parse_command`) | argv from agent spawn | Build `Shell_ir.Simple` from argv directly, skip parse_string |
| `exec_policy.ml:×2` (path validate) | string from policy entry | Lower at caller |
| `exec_policy_command_syntax.ml` | string from validate flow | Lower at caller |
| `keeper_gh_shared.ml` | string from gh op (S2 covers) | Already typed argv post-S2 |
| `keeper_shell_command_semantics.ml` | string for parse-then-classify | Caller provides IR |
| `keeper_hooks_oas_pr_metrics.ml` | string from PR metric path | Caller provides IR |
| `_of_string` transitional wrappers (S1) | string from `exec_core.ml` | Migrate `exec_core` callers to IR |
| `shell_command_gate.parse_string` | external entry | Keep — single legitimate string→IR entry point |

**Closes**: G1 (≤ 3 callers — parser sub-lib internal + shell_command_gate).
Retires `_of_string` wrappers introduced in S1.

### S5 · Universal path validator + single gate

- `validate_shell_ir_paths` wired into op=gh, op=git, op=repo_git
  dispatch (currently op=bash only).
- `Shell_command_gate.gate_typed` becomes the single gate for all
  four keeper ops. Ad-hoc pre-gates (e.g. structural `is_destructive`
  check *before* gate_typed) reduced to a single chain.
- Integration test: same wire payload (`gh pr merge --admin`) rejected
  with the *same* reason on op=gh and op=bash. Today op=gh routes
  reversibility R2 while op=bash routes `is_destructive_bash`.

**Closes**: G5 (already met) plus eliminates the "two gates for one
verdict" surface today.

### S6 · Cleanup & dead-code purge

- Delete `shell_word_values` (post-G7=0).
- Delete `gh_simple_command` dispatch path. `render_simple_gh_command`
  stays as a logging utility.
- Audit `hooks/claude/.../git_guard.ml` substring matching — record
  as separate RFC candidate (not in this RFC's scope; it is an
  external hook process boundary, not part of the OCaml typed
  pipeline).
- Re-run `scripts/audit-shell-ir-consumption.sh`. Verify G1-G7 all
  at target.

### S7 · Spec & ratchet

- `specs/shell-ir-first-class/ShellIRFirstClass.tla`:
  - States: `{Raw_string, Parsed_IR_no_decision, Decided_IR, Dispatched}`
  - Actions: `parse`, `classify`, `dispatch`
  - Invariant `IR_Carries_Decision`:
    `state = Dispatched ⇒ risk_class ∈ {R0..Destructive_protected}`
  - `NextBuggy` action: `DispatchWithoutDecision`. Clean cfg: no error.
    Buggy cfg: invariant violated.
- QCheck property: `∀ ir. risk(ir) = classifier(ir.bin, ir.args)` —
  stamp matches classify.
- CI ratchet: `scripts/audit-shell-ir-consumption.sh --baseline
  scripts/shell-ir-consumption-baseline.json` runs in PR CI; exits
  non-zero on G1 / G7 regression. Updated baseline committed each
  phase.

**Closes**: G6.

## §4 · Workaround Rejection Bar (self-check applied at body merge)

| Signature | This RFC |
|-----------|----------|
| §1 telemetry-as-fix | NO — structural root-fix (no counter / WARN added) |
| §2 substring classifier | NO — explicit *removal* (shell_word_values, gh classifier on string) |
| §3 N-of-M | EXPLICIT — 7 phases; S4 + S6 retire the transitional surfaces; no partial done |
| cap/cooldown/dedup/repair | NO |
| test backdoor | NO |
| catch-all `_ ->` additions | NO — closed sums (`risk_class`) and `'decided` phantom |

Risk active: S3 record-vs-phantom choice could carry caller-migration
cost asymmetrically. Default = B (phantom) preserves all 42 producer
record literals; A (record extension) forces explicit `risk` value
everywhere but with tighter on-construction invariant. PR body picks
one with a 1-paragraph rationale referencing this section.

## §5 · Open questions

1. **S3 stamp source**: classifier runs at IR construction (Producer A
   + B both call) or at dispatch entry (single late-binding site)?
   Argument for *construction-time*: producers vary in input quality,
   so the source-of-truth classifier should anchor at the typed-input
   boundary. Argument for *dispatch-time*: dispatch is the single
   chokepoint, lowest test cost. Default: construction-time.

2. **S4 spawn.ml lift**: `Spawn.parse_command` accepts both
   `cmd:string` (legacy) and argv shape (newer call sites). The
   string variant is the last `Bash.parse_string` caller after S4
   migrations except for `shell_command_gate`. Choice: keep
   string-tolerant for backward compat (G1 = 4 instead of 3) or
   force all callers to typed argv (G1 = 3 but breaking external
   API).

3. **S6 hook RFC fork**: `git_guard.ml` substring matching is on the
   shell process side, not OCaml lib. Forking an RFC-0160-adjacent
   spec for hook IR (or accepting the substring boundary as a
   process-isolation tradeoff) is a S6 decision.

## §6 · Implementation progress

| Phase | PR | Status |
|-------|-----|--------|
| S0 measurement script | #17873 | **MERGED** 2026-05-23 |
| S0 RFC body | this PR | Active (pending merge) |
| S1 classifier IR-only | #17884 | **MERGED** 2026-05-23 |
| S2 gh op IR lift | — | TBD |
| S3 risk stamp | — | TBD (Option A/B decision in PR body) |
| S4 parser entry | — | TBD |
| S5 universal gate | — | TBD |
| S6 cleanup | — | TBD |
| S7 spec + ratchet | — | TBD |

## §7 · Related SSOT / context

- Plan body (HTML, ~/me): `memory/shell-ir-first-class-promotion-todo-2026-05-23.html`
  (PR jeong-sik/me#1164, pending merge)
- Pre-cursor research: `memory/shell-ir-adjacent-next-plan-2026-05-22.html`
- Tool surface umbrella plan: `memory/tool-surface-unification-plan-2026-05-22.html`
- Related RFCs that closed substring-classifier loops elsewhere:
  - RFC-0042 (closed sum migration)
  - RFC-0088 (counter-as-fix anti-pattern umbrella)
  - RFC-0142 (typed dedup PR sweep)
  - RFC-0148 / RFC-0154 (System_error_class typed SSOT, dashboard substring fallback)
- P0-P13 tool-surface unification SSOT: see umbrella plan above

## §8 · Anti-pattern self-check at merge time

S1 already shipped (#17884) without a separately-merged RFC body —
this RFC is being raised *retrospectively* to anchor S2-S7. Doing the
measurement script first (S0) before the body was the correct order:
baseline metrics replaced 5 estimated numbers (`Bash.parse_string`
callers, parallel parser refs, gate_typed coverage) with measured
values. Two estimates were off by 25-50% (G1 estimated 8, measured
10; G7 estimated ~12, measured 26).

Lesson recorded in `~/me/memory/feedback_*` if the same evidence-first
pattern repeats: measurement scripts before RFC text when KPIs are
not already known.
