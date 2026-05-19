---
rfc: "0092"
title: "Keeper shell-bash typed validation via Shell_ir.parse"
status: Draft
created: 2026-05-17
updated: 2026-05-20
author: vincent
supersedes: []
superseded_by: null
related: ["0054", "0070", "0084", "0087", "0089"]
implementation_prs: [16721]
---

# RFC-0092 — Keeper shell-bash typed validation via Shell_ir.parse

Status: Draft
Author: jeong-sik (vincent) with Claude Opus 4.7
Date: 2026-05-17
Related:
- RFC-0054 (Shell IR PPX — codegen track ACTIVE)
- RFC-0070 (Keeper sandbox pure/edge separation)
- RFC-0084 (Keeper tool dispatch unification)
- RFC-0087 (Tool dispatch path unification + legacy purge)
- RFC-0089 (string classifier → typed variant)
- Prerequisite PRs (open Drafts):
  - PR #15699 (parse_outcome_kind typed downstream)
  - PR #15700 (legacy string aliases purge)
  - PR #15703 (destructive_patterns SSOT)
  - PR #15704 (evasion_kind typed)

## 1. Problem

`lib/keeper/keeper_shell_bash.ml` (1039 LoC) is the `keeper_bash` tool's
entrypoint. Its validation pipeline is currently regex+substring-only:

1. `Worker_dev_tools.validate_command` — allowlist check over
   `dev_allowed_commands` plus `contains_forbidden_shell_chars`.
2. `Eval_gate.detect_destructive` — destructive substring match.
3. `Eval_gate.detect_evasion` — evasion regex match.

The `lib/exec/shell_ir.mli` typed AST + `bash_subset.mly` parser exist
but have **zero callers in `lib/keeper/`** (confirmed by
`rg "Shell_ir\." lib/keeper/` returning only `keeper_gh_shared.ml`
and `keeper_hooks_oas.ml`, neither of which is on the keeper_bash
validation path).

The shadow gate (`Worker_dev_tools.classify_shadow`, flag-gated by
`MASC_BASH_AST_SHADOW_LOG`) does run `Shell_ir`-equivalent parsing
side-by-side but emits **observation only**: gate-diff counters
(`Legendary_counters.incr_gate_diff` etc.) and structured log lines.
The shadow verdict never drives a real allow/deny decision.

Why this matters:

- The legacy substring gate is structurally fragile (substrings, not
  AST nodes). `r\m -rf` (backslash-evading) is the canonical bypass;
  `bash_subset.mly` parses it correctly as a command + flags.
- RFC-0054's typed surface (`Shell_ir_typed`'s 9-constructor GADT
  with `[`Safe / `Audited / `Privileged]` risk phantom params) is
  designed to be the validation substrate but currently has no
  production caller — its only consumers are the codegen walker
  generator (`bin/gen_shell_ir_walkers.ml`) and its own tests.
- The shadow gate has accumulated dead-launch infrastructure
  (Tick 22 logger, parity counters) without a flip path. Recent PRs
  #15699/#15700 closed the typed `parse_outcome_kind` downstream;
  the *upstream* — making the shadow verdict authoritative for at
  least one decision — remains undone.

## 2. Goals

1. Wire `Shell_ir.parse` into `keeper_shell_bash.handle_keeper_bash`
   as a parallel *typed* validation path, flag-gated, fail-closed
   on parse failure (legacy gate still authoritative; typed path is
   advisory).
2. Once parity ratio ≥ 99.5 % over a rolling 7-day operator window,
   flip authority: typed path decides, legacy is the fallback for
   `Shell_cannot_parse`.
3. Once the typed path has been authoritative for 7+ days with zero
   false-positive incidents reported, remove the legacy substring
   path entirely.

Non-goals:

- Pipeline / complex bash construct support (`heredoc`, `subshell`,
  `cmd_subst`, etc.) — those remain `Too_complex` and fall back to
  legacy until the bash_subset grammar grows.
- `keeper_shell_docker` rewrite — docker has its own validation
  surface and is out of this RFC's scope.
- New evasion classes — iter5 already typed the existing 6; new
  patterns are a separate metric-rename PR.

## 3. Non-goals

(Above doubles as both motivation context and scope fencing.)

## 4. Design

### 4.1 Phase A — parallel typed advisor (no behavior change)

Add `lib/exec/shell_ir_validator.ml` (~80 LoC, new module):

```ocaml
(* Pure function. Returns Result for the typed validation outcome.
   No side effects, no env reads, no destructive checks (those stay
   in Eval_gate for now). *)
type advisory =
  | Allow                          (* typed AST accepts as Simple
                                      with all args under whitelist *)
  | Reject of {
      reason : reject_reason;
      diagnostic : string;
    }
  | Cannot_parse of {
      kind : Gate_diff_types.parse_outcome_kind;
    }

and reject_reason =
  | Command_not_in_allowlist of string
  | Pipeline_with_disallowed_segment
  | Redirect_to_protected_path of string

val advise : cmd:string -> allowlist:string list -> advisory
```

In `keeper_shell_bash.handle_keeper_bash`, *after* the existing
`Worker_dev_tools.validate_command` call, run `Shell_ir_validator.advise`
and emit a structured log line + a new counter
`Legendary_counters.incr_typed_advisor` partitioned by `advisory`.
**No behavior change.** Legacy gate decides; the advisor only logs.

Flag: `MASC_BASH_TYPED_ADVISOR=1` (default off).

### 4.2 Phase B — parity measurement window

Operators run with `MASC_BASH_TYPED_ADVISOR=1` for ≥ 7 days. The
dashboard exposes:

- `typed_advisor_total` (denominator)
- `typed_advisor_agree` (legacy + typed converged)
- `typed_advisor_disagree_legacy_allow_typed_reject` (typed
  blocks something legacy permits — over-reject candidate)
- `typed_advisor_disagree_legacy_reject_typed_allow` (typed
  permits something legacy blocks — false-negative candidate)
- `typed_advisor_cannot_parse` (parser bailout — coverage gap)

**Promotion criterion**: `typed_advisor_agree / typed_advisor_total
≥ 0.995` for 7 rolling days AND zero
`disagree_legacy_reject_typed_allow` rows.

### 4.3 Phase C — authority flip (behavior change)

When the criterion is met:

1. Add a second flag `MASC_BASH_TYPED_AUTHORITY=1`.
2. When set: typed advisor's `Reject` returns the JSON error; typed
   `Allow` proceeds; typed `Cannot_parse` falls back to legacy
   verdict (parser-coverage gap remains backward-compatible).
3. Legacy gate continues to run *as a fallback*; the same counters
   keep flowing so we can detect regression.

### 4.4 Phase D — legacy purge

After ≥ 7 days at full authority with zero incident:

1. Remove `Worker_dev_tools.validate_command` substring path.
2. Remove `MASC_BASH_TYPED_AUTHORITY` flag — typed is unconditional.
3. Remove `MASC_BASH_AST_SHADOW_LOG` flag and the Tick 22 shadow
   logger — replaced by the always-on typed advisor.
4. Compact `lib/keeper/keeper_shell_bash.ml` validation block from
   ~150 LoC to ~30 LoC by removing legacy branches.

### 4.5 What does *not* change

- `Eval_gate.detect_destructive` / `detect_evasion` — these run on
  the raw command string before the typed path, identical pre/post.
  Destructive detection is orthogonal to AST validation.
- The `keeper_shell_bash` entry point's outer JSON-args parsing,
  cwd resolution, exec_cache, and result rendering.
- `keeper_shell_docker` — docker subsystem stays substring-based
  until a separate RFC covers it.

## 5. Workaround-rejection compliance

Per `software-development.md §워크어라운드 거부 기준`:

- **Telemetry-as-fix (#1)**: Phase B is *measurement*, not *fix*.
  The advisory emits counters; no data-loss path is widened. Phase C
  closes the measurement window with a real authority flip.
- **String classifier (#2)**: Phase A *replaces* the substring gate
  with an AST gate. RFC-0089's first concrete keeper-shell instance.
- **N-of-M (#3)**: Phase D removes the legacy path entirely. No
  "complete migration in PR-N+1" deferral.
- **Cap / cooldown**: not applicable.
- **Log dedup**: not applicable.

## 6. Rollout

| Phase | Trigger | Action | Rollback |
|---|---|---|---|
| A | RFC merged + `Shell_ir_validator` PR merged | Set `MASC_BASH_TYPED_ADVISOR=1` for a single keeper | Unset env var |
| B | Phase A 1 keeper for 24h with no `disagree_legacy_reject_typed_allow` | Roll to fleet, observe 7 days | Unset env var |
| C | Phase B criterion met | Set `MASC_BASH_TYPED_AUTHORITY=1` | Unset, falls back to advisor-only |
| D | Phase C 7+ days, zero incidents | Merge legacy purge PR | Revert PR |

## 7. Implementation PRs (planned, separate)

- **PR-1**: `lib/exec/shell_ir_validator.ml` + tests (Phase A core,
  no integration yet). ~150 LoC.
- **PR-2**: Wire into `keeper_shell_bash` behind
  `MASC_BASH_TYPED_ADVISOR`. ~40 LoC change in keeper_shell_bash.
- **PR-3**: Dashboard counter exposure in
  `lib/legendary_counters.ml` snapshot + `/api/v1/legendary_bash/...`
  route. ~80 LoC.
- **PR-4**: Phase C authority flip behind
  `MASC_BASH_TYPED_AUTHORITY`. ~50 LoC.
- **PR-5**: Phase D legacy purge.

Each PR is incremental and reversible. Total cost estimate: ~400 LoC
new + ~200 LoC removed = net ~200 LoC growth; behavior risk
front-loaded to Phase A (zero) and back-loaded to Phase C (gated).

## 8. Open questions

- Does `Shell_ir.parse` need any extension to recognise the full
  `dev_allowed_commands` set? `bash_subset.mly` accepts simple
  commands and 2-stage pipelines; anything outside (heredoc,
  subshell) parses as `Too_complex` and falls back to legacy.
  Coverage measurement in Phase B will quantify the gap.
- Should `Shell_ir_validator.advise` consume `Sandbox_target`
  (host vs docker) to short-circuit destructive checks when the
  command will run inside a docker sandbox? Defer to Phase A
  feedback.

## 9. Acceptance criteria

This RFC is accepted when:

1. PR-1 + PR-2 merged with `MASC_BASH_TYPED_ADVISOR` flag-gated.
2. One keeper has run for 24h+ with the flag on and emitted at
   least 100 `typed_advisor_total` observations.
3. Dashboard exposes the 5 counters and operators can grep the
   `gate_diff_typed_advisor` log lines.

This RFC is *implemented* (Phase D done) when:

1. `Worker_dev_tools.validate_command` substring path removed.
2. `MASC_BASH_TYPED_AUTHORITY` flag removed (unconditional).
3. `keeper_shell_bash.ml` validation block ≤ 30 LoC.
4. Zero `disagree_legacy_reject_typed_allow` rows over the prior
   7 days at full authority.
