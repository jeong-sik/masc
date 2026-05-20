---
rfc: "0131"
title: "Shell Command Gate facade — multi-caller IR-first validation"
status: Draft
created: 2026-05-19
updated: 2026-05-19 (status note + §10 revised PR slicing added)
author: vincent
supersedes: []
superseded_by: null
related: ["0054", "0089", "0091", "0092", "0126"]
implementation_prs: [16335,16340,16346,16433,16527,16532,16542]
---

# RFC-0131 — Shell Command Gate facade

Status: Draft
Author: jeong-sik (vincent) with Claude Opus 4.7
Date: 2026-05-19
Related:
- RFC-0054 (Shell IR PPX — typed AST surface, ACTIVE)
- RFC-0091 (Keeper bash typed argv — execve-style public input)
- RFC-0092 (Keeper shell-bash typed validation — Phase A advisor done; B/C/D pending)
- RFC-0089 (string classifier → typed variant — general policy)
- RFC-0126 (silent fallback discipline — workaround rejection bar)

---

## Status note — 2026-05-19 author correction

The original §1 below claimed no facade existed.  That was wrong.  A
companion audit of `origin/main` after RFC submission found that
`lib/shell_command_gate.{ml,mli}` **already exists** and is wired into
two of the three callers:

```
$ rg "Shell_command_gate" lib/
lib/tool_code_write.ml:106-107   parse + last_stage_bin (exit classifier)
lib/worker_dev_tools.ml:536-564  parse + stage_bins + stage_count + validate_allowlist
lib/shell_command_gate.ml(.mli)  the facade itself
```

The facade exposes `parse`, `validate_allowlist ?allow_pipes`,
`stage_count`, `last_stage_bin`, plus tag functions.  Test coverage
exists at `test/test_shell_command_gate.ml`.

So RFC-0131 is **not the first-mover for the facade**.  Its remaining
contribution is the **extension** that promotes the existing facade to
RFC-0131's full §4 contract:

1. Add `caller` partition (currently unpartitioned) so telemetry can
   per-caller measure parity against the legacy fallback.
2. Add `redirect_allowed` policy flag (currently always-allow).
3. Add explicit `Unsupported_nested_pipeline` reject (current code
   silently flattens via `simples_of_ir`'s `List.concat_map`).
4. Wire `keeper_shell_bash.ml` as the third caller directly (it
   currently uses the facade transitively via
   `Worker_dev_tools.validate_command_coding_with_allowlist`).
5. Remove legacy fallback paths in `worker_dev_tools.ml`
   (`validate_command_coding_legacy_segments`) and `tool_code_write.ml`
   (`first_token_basename (last_pipeline_segment ...)`).

§§1–7 below are kept verbatim for historical record; §10 below restates
the revised PR slicing under this correction.

---

## 1. Problem

The bash gate path is owned by three different modules today, each carrying its own
string scanner / splitter / classifier:

| Module | Function | What it does |
|---|---|---|
| `lib/worker_dev_tools.ml` | `validate_command_coding_with_allowlist` (line 549) | `forbidden_shell_chars` blacklist + `split_pipeline_segments` (line 92) + allowlist + `tokenize_path_args` (line 744) + `path_validation_tokens` (line 1043) |
| `lib/tool_code_write.ml` | `validate_command_coding_with_allowlist` (line 579 wrapper) + `classify_code_shell_exit` | Local pipeline splitter for `masc_code_shell`, last-stage parser, exit classifier |
| `lib/keeper/keeper_shell_bash.ml` | `handle_keeper_bash` validation block | `Worker_dev_tools.validate_command_coding_with_allowlist` + `Eval_gate.detect_destructive` + `Eval_gate.detect_evasion` + raw shape scanner |

`lib/shell_ir_validator.ml` (RFC-0092 Phase A) parses through `Bash.parse_string` once
and emits a typed `advisory`, but it **has no production caller**:

```
$ rg "Shell_ir_validator\." lib/ | rg -v lib/shell_ir_validator
# (empty)
```

Effects (measured 2026-05-18 in `MASC/OAS Error-Warn Reduction Goal`):

- `keeper_tool_policy_blocked + keeper_tool_execution_errors = 17,004` per 72h
  (largest single error category).
- Recurrent false positives from string-based classifiers: PR #16110 fixed one
  (`|` inside a regex literal being treated as a real pipe); analogous bugs surface
  in `tokenize_path_args` (quote/glob/escape loss) and `forbidden_shell_chars`
  (overbroad on regex/`$` parameter expansion).
- Drift between callers: same raw `cmd` can be allowed by `tool_code_write` and
  rejected by `worker_dev_tools` because they use slightly different splitter
  variants. Operators cannot predict which gate fires.

RFC-0092 plans Phase B (parity), C (authority flip), D (legacy purge) for
`keeper_shell_bash` only. It does not consolidate the **other two callers**, and
it leaves the pipeline first-class contract open.

## 2. Goals

1. Add a single facade `lib/exec/shell_command_gate.ml(.mli)` owning the
   parse-once → policy → telemetry pipeline for **all three callers**.
2. Promote pipeline to first-class: `a | b | c` enters as
   `Shell_ir.Pipeline [Simple a; Simple b; Simple c]` ordered stage list. No
   string re-splitting downstream. Quoted `|` is never a delimiter. Nested
   pipelines (`a | (b | c)`) are explicitly `unsupported_nested_pipeline`.
3. Each caller becomes a thin adapter that constructs the facade input and
   maps the typed verdict back to its existing JSON-error shape — no behavior
   change in PR-1.
4. Legacy purge sequence is RFC-pinned: facade owns the only string-parse path;
   `worker_dev_tools.ml` and `tool_code_write.ml` lose `split_pipeline_segments`,
   `tokenize_path_args`, `path_validation_tokens` and `classify_code_shell_exit`
   after caller adoption.

## 3. Non-goals

- Replacing `Eval_gate.detect_destructive` / `detect_evasion`. Those run on
  the raw command string and are orthogonal to AST validation (per RFC-0092 §4.5).
- Adding a full Bash grammar. The facade rejects out-of-subset input as
  `Too_complex` (closed sum, no catch-all). `bash_subset.mly` may grow in
  follow-up RFCs.
- Docker shell rewrite. `keeper_shell_docker.ml` is on the same trajectory but
  has its own credential/runtime surface; a separate RFC covers it.
- Typed argv public surface for the Bash tool. RFC-0091 owns that contract;
  this RFC adapts to it via a Phase E callback (§4.5) but does not modify
  the public tool schema in PR-1.

## 4. Design

### 4.1 Facade API (PR-1, behavior-neutral addition)

`lib/exec/shell_command_gate.mli`:

```ocaml
(** Shell_command_gate — single-parse gate for keeper, worker, and code-shell
    bash validation. RFC-0131. *)

(** Input source. Used to scope policy + telemetry partitions. *)
type caller =
  | Worker_dev_tools
  | Tool_code_write
  | Keeper_shell_bash

(** Allowlist mode. Each caller has its own set today; the facade does not
    merge them — it accepts the caller's allowlist as data. *)
type allowlist = {
  binaries : string list;        (** allowed binary names, e.g. ["rg"; "git"] *)
  pipeline_allowed : bool;       (** false rejects any Pipeline _ at the gate *)
  redirect_allowed : bool;       (** false rejects [> path] / [>> path] *)
}

(** Path policy snapshot. The facade calls this opaquely; no caller-private
    classifier strings escape the boundary. *)
type path_policy = {
  reject : Path_scope.t -> string option;
  (** Returns [Some reason] when the path is denied (e.g. outside cwd,
      sandbox-escape, protected target). Reason is included in [Reject]
      diagnostic. *)
}

type sandbox_context = {
  target : Sandbox_target.t;
  cwd : Path_scope.t option;
}

type verdict =
  | Allow of {
      stages : Shell_ir.t list;      (** [Simple s] when single-stage, else
                                         pipeline stage list. Length >= 1. *)
      classified_last_binary : Bin.t;  (** for exit classification reuse *)
    }
  | Reject of {
      reason : reject_reason;
      diagnostic : string;
    }
  | Cannot_parse of { kind : Gate_diff_types.parse_outcome_kind }
  | Too_complex of {
      reason : Parsed.reason_too_complex;
      (** Closed sum from bash_subset; the caller decides whether to fall
          back or surface unsupported. *)
    }

and reject_reason =
  | Command_not_in_allowlist of string
  | Pipeline_stage_disallowed of { stage_index : int; binary : string }
  | Pipeline_disallowed_in_caller       (** allowlist.pipeline_allowed = false *)
  | Unsupported_nested_pipeline         (** stage is itself a Pipeline _ *)
  | Redirect_to_protected_path of string
  | Redirect_disallowed_in_caller       (** allowlist.redirect_allowed = false *)

val gate :
  caller:caller ->
  allowlist:allowlist ->
  path_policy:path_policy ->
  sandbox:sandbox_context ->
  cmd:string ->
  verdict
```

### 4.2 Implementation outline (PR-1)

1. Call `Bash.parse_string cmd` once.
2. On `Parsed (Simple s)`: run allowlist + redirect + path policy → `Allow` or `Reject`.
3. On `Parsed (Pipeline stages)`:
   - If `not allowlist.pipeline_allowed` → `Reject Pipeline_disallowed_in_caller`.
   - For each stage, if it's a nested `Pipeline _` → `Reject Unsupported_nested_pipeline { stage_index }`.
   - Otherwise check each stage's binary + redirect + path policy.
   - Return `Allow { stages; classified_last_binary = (last stage's bin) }`.
4. On `Parse_error` / `Parse_aborted _` → `Cannot_parse`.
5. On `Too_complex _` → `Too_complex` with the reason variant preserved.
6. Emit a single typed telemetry record (`Gate_diff_types.gate_outcome`)
   partitioned by `caller`. Same record shape RFC-0092 advisor uses.

PR-1 ships the module + 100% test coverage of all 7 verdict arms. **No caller wired**.

### 4.3 Caller adoption (PR-2/3/4 — one per caller, behavior-neutral)

Each caller PR:

- Computes `caller_allowlist : allowlist` and `caller_path_policy : path_policy`
  from existing local state (no shared global).
- Calls `Shell_command_gate.gate ...` and maps the verdict to the caller's
  existing error JSON (preserving wire shape).
- **Parallel** to the existing legacy gate — both run, both decide independently
  (legacy still authoritative). Disagreement is recorded as a typed
  telemetry diff per caller.

This phase mirrors RFC-0092 Phase A (advisor) but applies it at the gate boundary
instead of at the keeper_shell_bash boundary.

### 4.4 Authority flip (PR-5)

When all three callers' agreement ratio ≥ 99.5 % over 7 days AND zero
`disagree_legacy_reject_typed_allow` rows:

- `MASC_SHELL_GATE_AUTHORITY=1` makes the facade verdict authoritative.
- Legacy paths run as fallback only on `Cannot_parse` (parser coverage gap).
- The flag is per-caller (`worker`, `code_write`, `keeper_bash`) to allow
  staged rollback.

### 4.5 Typed argv input compatibility

When a caller has access to a typed argv (RFC-0091 public Bash tool), it can
bypass `Bash.parse_string` by lowering the typed argv directly to
`Shell_ir.Simple s` (or `Shell_ir.Pipeline [Simple s1; Simple s2; ...]`).
A helper `Shell_command_gate.gate_typed : Shell_ir.t -> verdict` accepts
already-parsed IR. Same policy module; same telemetry partition.

### 4.6 Legacy purge (PR-6)

After ≥ 7 days at authority with zero incidents:

- `lib/worker_dev_tools.ml`: remove `split_pipeline_segments`,
  `tokenize_path_args`, `path_validation_tokens`, `contains_forbidden_shell_chars`,
  `forbidden_shell_chars_coding_base`. `validate_command_coding_with_allowlist`
  becomes a 3-line wrapper around `Shell_command_gate.gate`.
- `lib/tool_code_write.ml`: remove local `split_pipeline_segments` and
  `classify_code_shell_exit`. Exit classification reuses
  `Allow.classified_last_binary`.
- `lib/keeper/keeper_shell_bash.ml`: remove raw shape scanner; gate result is
  authoritative.

Purge PR's acceptance check (per Doc #3 §"Legacy Removal Checklist"):

```
rg "split_pipeline_segments" lib/        # count 0
rg "tokenize_path_args"       lib/        # count 0
rg "path_validation_tokens"   lib/        # count 0
rg "forbidden_shell_chars"    lib/        # count 0
rg "shell_ir_parse_failure_shape_block" lib/keeper/  # parse-failure-only helper
```

## 5. Workaround-rejection compliance (per CLAUDE.md §워크어라운드 거부 기준)

- **Telemetry-as-fix (#1)**: Phase 4.3 (caller adoption) emits telemetry *and*
  prepares the authority flip in 4.4. Telemetry alone is not the deliverable.
- **String classifier (#2)**: This RFC removes 4 string classifiers (chars,
  splitter, path tokens, exit) in favor of typed AST consumption. Net direction
  is toward closed sum types (`Shell_ir`, `Parsed.reason_too_complex`,
  `Gate_diff_types.parse_outcome_kind`).
- **N-of-M (#3)**: PR-2/3/4 adopt the facade across all three callers; the
  authority flip and legacy purge are gated by all-callers-ready criteria. No
  caller is left with the legacy path after Phase D.
- **Cap/cooldown/dedup**: not applicable.

## 6. Rollout

| Phase | PR | Trigger | Rollback |
|---|---|---|---|
| Facade addition | PR-1 | RFC merged | Revert PR (zero callers, zero risk) |
| Caller adoption — worker_dev_tools | PR-2 | PR-1 merged | Revert PR (caller falls back to legacy) |
| Caller adoption — tool_code_write | PR-3 | PR-1 merged (parallel to PR-2) | Revert PR |
| Caller adoption — keeper_shell_bash | PR-4 | PR-1 merged (parallel to PR-2/3); composes with RFC-0092 Phase A | Revert PR |
| Authority flip | PR-5 | All callers at ≥ 99.5 % parity for 7d | Unset `MASC_SHELL_GATE_AUTHORITY` |
| Legacy purge | PR-6 | Phase 5 stable 7+ days, zero incidents | Revert (legacy code returns) |

Total cost estimate: ~600 LoC new (facade + tests + 3 caller adapters) +
~800 LoC removed (splitters + tokenizers + scanners) = net ~200 LoC reduction.

## 7. Acceptance criteria

This RFC is **accepted** when:

1. PR-1 (facade) and at least one caller adoption (PR-2/3/4) are merged.
2. Typed telemetry shows non-zero `shell_command_gate_total` rows on at least
   one production keeper for 24h+.

This RFC is **implemented** when:

1. All three callers are wired (PR-2/3/4 merged).
2. Authority flip merged (PR-5) and stable for ≥ 7 days.
3. Legacy purge merged (PR-6); acceptance grep checks pass (§4.6).
4. `keeper_tool_policy_blocked + keeper_tool_execution_errors` per 72h is
   ≤ 4,000 (Doc #1 Pass 1 target) AND no shell-gate-related entry in the
   top 5 categories for 7 consecutive days.

## 8. Open questions

- Should pipeline length be capped? Current `bash_subset.mly` does not bound
  stage count. Suggest soft cap of 8 stages, hard cap of 32, configurable per
  caller. Defer to PR-1 review.
- Does `path_policy` need to see all args in a pipeline, or only the last
  stage's? Last-stage-only is simpler; full-pipeline is safer for chained
  `tee` → `rm` patterns. Likely full-pipeline; defer to PR-1 implementation.
- Cross-caller telemetry aggregation: per-caller counters are necessary for
  staged rollback, but operators will also want a fleet-wide rollup.
  `Legendary_counters` snapshot can sum on read; no schema change needed.

## 9. References

- Doc: `~/me/.tmp/plans-2026-05-18/03-shell-ir-promotion.md` (this RFC's
  external goal-plan, reformatted from the Shell IR Promotion Goal Plan HTML).
- Doc: `~/me/.tmp/plans-2026-05-18/00-synthesis.md` §R2 (root-fix selection).
- Measurement: `MASC/OAS Error-Warn Reduction Goal — 2026-05-18` (P2 category).

## 10. Revised PR slicing (2026-05-19 update)

Given the facade already exists (status note above), §6 rollout's PR-1
is replaced by the following micro-PRs, each independently mergeable and
behavior-preserving for existing callers (`Error _` wildcard patterns in
`tool_code_write` and `worker_dev_tools` absorb new arms):

| PR | Scope | Lines | Risk |
|---|---|---|---|
| PR-1a | Add `caller` partition tag + optional `?caller` arg to `validate_allowlist`. Backwards-compatible default. | ~40 | Low |
| PR-1b | Add `Unsupported_nested_pipeline` arm to `cannot_parse_kind`. Replace `simples_of_ir`'s `List.concat_map` with a fail-closed walker. | ~30 | Low |
| PR-1c | Add `?redirect_allowed` flag to `validate_allowlist`. Default `true` preserves current behavior. | ~30 | Low |
| PR-2 | Wire `keeper_shell_bash.ml` to call `Shell_command_gate` directly for the validation block currently funneled through `Worker_dev_tools.validate_command_coding_with_allowlist`. Telemetry uses `~caller:Keeper_shell_bash`. | ~80 | Medium |
| PR-3 | Telemetry counter exposure (`Legendary_counters.incr_shell_gate ~caller ~verdict`) + dashboard read. | ~120 | Low |
| PR-4 | Per-caller parity measurement window (PR-1a + PR-3 prereq). | observation-only | None |
| PR-5 | Authority flip per-caller via `MASC_SHELL_GATE_AUTHORITY=worker,code_write,keeper_bash`. | ~40 | Medium |
| PR-6 | Legacy purge: remove `validate_command_coding_legacy_segments`, `first_token_basename (last_pipeline_segment ...)` fallback, and remaining string scanners per §4.6. | ~200 net removal | Medium |

PR-1a–c can land in any order; PR-2 depends on PR-1a (for the caller
tag); PR-5/PR-6 depend on PR-4 parity evidence.
