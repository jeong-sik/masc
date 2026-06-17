# RFC-0254: Shell IR Approval Gate — Autonomous Sandbox-Conditional Policy

**Status**: Draft
**Date**: 2026-06-17
**Builds on**: [RFC-0005](./RFC-0005-typed-capability-substrate.md) (typed capability substrate, a.k.a. "RFC v5"), [RFC-0208](./RFC-0208-shell-ir-compositional-risk-ast.md) (Shell IR compositional risk / path policy)
**Related**: [RFC-0006](./RFC-0006-keeper-surface-and-sandbox.md), [RFC-0213](./RFC-0213-keeper-sandbox-isolation.md), [RFC-0070](./RFC-0070-keeper-sandbox-pure-edge-separation.md) (sandbox boundary); [RFC-0027](./RFC-0027-capability-typed-runtime.md), [RFC-0181](./RFC-0181-capability-intent-runtime-ssot.md) (capability runtime); [RFC-0199](./RFC-0199-evidence-driven-auto-approval.md) (deterministic verdict source replaces human bottleneck — same philosophy, different domain); [RFC-0088](./RFC-0088-counter-as-fix-result-propagation.md), [RFC-0042](./RFC-0042-keeper-terminal-code-closed-sum.md) (no-string-classifier lineage)
**Supersedes wiring of**: PR #21338 `feat(shell-ir): wire approval policy gate behind feature flag`
**Tracking**: MASC task-1333

## 1. Summary

PR #21338 wires `Keeper_tool_execute_shell_ir.dispatch_classified_with_approval` behind `MASC_SHELL_IR_APPROVAL_GATE_ENABLED`, routing keeper Execute calls through `Approval_policy.decide` with `Approval_config.permissive_default`. As wired, enabling the flag converts every audited/privileged command (`git`, `dune`, `npm`, `python`, `rm`, …) into a terminal error returned to the model, because the `Ask` verdict has no resolver in the autonomous keeper lane. The gate blocks the keeper's entire toolchain while the genuinely catastrophic class (force-push) is coupled to a loosenable trust knob.

This RFC defines the correct model: a **sandbox-conditional** gate where

- **Docker profile** → the container is the security boundary; per-command gating is skipped (container-trust).
- **Local/Host profile** → an **autonomous policy**: verdicts collapse to `Allow` (+telemetry) or `Deny` (a trust-independent catastrophic floor). There is no `Ask` in the autonomous lane, because there is no human in the keeper's loop.

It also specifies the supporting change that makes the catastrophic floor expressible without string matching: extending `Capability_check.of_ir` to emit typed `Path_scope` for the arguments of filesystem-mutating programs.

## 2. Context & problem

### 2.1 What PR #21338 wires (verified, head `274ace4e13`)

- `Env_config_runtime.Shell_ir_approval_gate.enabled ()` reads `MASC_SHELL_IR_APPROVAL_GATE_ENABLED` (default `false`), registered in `Feature_flag_registry` (`lifecycle=Experimental`, `since=2.234.0`).
- When enabled, `keeper_tool_execute_runtime.ml` constructs `{ defaults = Approval_config.permissive_default; per_agent = [] }` inline and calls `dispatch_classified_with_approval`.
- `dispatch_classified_with_approval` runs `Approval_policy.decide` on the classified IR, then (on `Allow`/`Suggest_confirm`) delegates to `dispatch_classified` (typed gate → path validation → dispatch); `Ask` → `Approval_required`, `Deny` → `Policy_denied`, both returned to the model as error JSON.

### 2.2 The defects

`permissive_default = { safe_trust = Auto_safe; audited_trust = Enforced; privileged_trust = Enforced }` (`approval_config.ml:33-38`). In `Approval_policy.trust_dispatch`, `Enforced → Verdict.Ask` (`approval_policy.ml:93`).

1. **`Ask` is terminal — there is no resolver.** `Approval_required` is consumed only at two keeper sites (`keeper_tool_execute_runtime.ml`, `keeper_workspace_read_ops.ml`), both converting it to error JSON. No approval queue, human channel, or grant-and-retry exists (verified by exhaustive grep). For an autonomous keeper, `Ask` is functionally identical to `Deny`.
2. **Enabling the flag blocks the toolchain.** `git` is `Audited` (`approval_policy.ml:71`); with `audited_trust = Enforced`, every `git`, `dune`, `npm`, `python`, `make`, `gh`, `sed` (48 audited + 8 privileged binaries) → `Ask` → blocked. Unknown binaries → `Privileged` (fail-closed, `exec_program.ml:356`) → blocked. The keeper can run only the 38 `Safe` programs (`ls`, `cat`, `rg`, `cp`, `mv`, …). It cannot build, test, or commit.
3. **The lane keeps turning but does no work.** The error return is non-fatal (`keeper_tool_shared_runtime.ml:13`), so the keeper fiber survives and the lane keeps running — but every dev command fails, so the keeper makes no code progress and is liable to retry-thrash (burning turns).
4. **Catastrophic protection is coupled to a loosenable knob.** `find_destructive_git` Denies only when `overlay.privileged_trust = Enforced` (`approval_policy.ml:106-120`). Loosening `privileged_trust` to allow `rm` would simultaneously **allow `git push --force`**. The 3-level trust overlay cannot express "run the toolchain incl. rm, but hard-block destructive git". The only unconditional Deny is redirect path-escape.
5. **Redundant inside a sandbox.** `dispatch_classified` already applies `Sandbox_target` routing + `validate_paths` workspace jail + `gate_typed`. The approval gate is a fourth, stricter layer over an already-contained execution.
6. **Unrelated dead code rides along.** Commit `f2ccbc21ab` ("parallel/async/visibility/approval level-up") also adds `Exec_dispatch.dispatch_async`, `dispatch_decided_outcome`, `argv_of_ir`, and `Tool_dispatch.dispatch_many` — none have production callers; they widen the public `.mli` surface with tests but no use.

## 3. Premise: how keepers actually execute

`keeper_tool_execute_runtime.ml:203-228` resolves the dispatch sandbox from `sandbox_profile`:

- `Local → Sandbox_target.host ()` — runs **directly on the host** (secret projection + workspace path-jail, but no container).
- `Docker → docker_sandbox_target …` — runs inside a real Docker container; a playground path may fall back to Host.

`Sandbox_target.t = Host | Docker of { image; runner; … }` (`sandbox_target.mli:38`). So the security boundary differs by profile, and the correct gate behavior must differ with it. This is the premise the PR did not account for.

## 4. Prior art

| | Claude Code (rules + modes) | OpenClaw | Hermes Agent (Nous) |
|---|---|---|---|
| Decision axis | `alwaysAllow/Deny/AskRules` + permission `mode` (default / acceptEdits / plan / bypassPermissions) | Context: `main` = full host, non-main = sandbox | `approvals.mode`: manual / smart / off |
| `Ask` resolver | interactive human / `canUseTool` callback / remote control bridge | DM pairing (human, per-sender) | manual = human; **smart = auxiliary LLM** auto-approves low-risk, auto-denies dangerous, escalates uncertain |
| Catastrophic floor | `strippedDangerousRules` + bypass guard | (delegated to sandbox) | **hardline blocklist, always-on** (`rm -rf /`, fork bomb, mkfs) regardless of mode/yolo/allowlist |
| Sandbox relation | — | non-main → Docker/SSH/OpenShell | **`backend=docker` → dangerous checks skipped** (container is the boundary) |
| Headless posture | `bypassPermissions` / SDK `canUseTool` | `main` is trusted | `cron_mode: deny\|approve` (explicit) |

Sources: `~/me/workspace/yousleepwhen/claude-code/src/types/permissions.ts` (leaked, minified — names mangled, structure intact), `src/tools/BashTool/readOnlyValidation.ts`; openclaw/openclaw README; hermes-agent.nousresearch.com/docs/user-guide/security (`approvals.mode`, hardline blocklist, container exception, `tools/approval.py`). Confidence: Medium-High.

**Lessons.** (a) Trust is contextual, not per-command-absolute. (b) `Ask` always has a resolver — human, LLM, or callback; none of the three leave it dangling. (c) A catastrophic floor is unconditional, independent of mode/allowlist. (d) When a container is the boundary, per-command checks are skipped. MASC's wired gate violates (b), (c), and (d).

## 5. Design

### 5.1 Sandbox-conditional application

The gate is applied as a function of `sandbox_profile`, decided in `keeper_tool_execute_runtime.ml` before dispatch:

| profile | boundary | behavior |
|---|---|---|
| `Docker` | container | container-trust: do **not** apply the approval gate; rely on container isolation (RFC-0213) + existing `validate_paths`. Telemetry only. |
| `Local` / `Host` | path-jail only | apply the **autonomous policy** (§5.2). |

This mirrors Hermes' container exception and removes the redundant fourth layer for the Docker case.

### 5.2 Verdict collapse for the autonomous lane

In the autonomous (Host) lane there is no human and no resolver, so the verdict space collapses to two:

- `Allow` (+ telemetry) — execute through the existing `dispatch_classified` pipeline.
- `Deny { reason }` — a trust-independent catastrophic floor; returned to the model as a `Policy_denied` carrying the rendered typed reason.

`Ask` and `Suggest_confirm` do **not** occur in the autonomous lane. (`Ask` remains valid for a future operator/interactive context — see §5.5.)

### 5.3 `decide` reshape: decouple the floor from trust

Move the catastrophic cases out of the trust-graded path into an unconditional pre-check. As implemented in `approval_policy.ml`:

```ocaml
(* Trust-INDEPENDENT catastrophic floor. Always Deny, regardless of overlay. *)
let catastrophic_floor (caps : Capability.t list) : Verdict.deny_reason option =
  match find_destructive_git caps with
  | Some g -> Some (Destructive_git g)
  | None ->
    match find_write_escape caps with        (* redirect write targets outside the workspace *)
    | Some ps -> Some (Path_escape ps)
    | None -> find_catastrophic_program caps  (* mkfs, by binary identity (Exec_program.known) *)

let decide policy ~overlay ~caps ~simple : Verdict.t =
  match catastrophic_floor caps with
  | Some reason -> Verdict.Deny { caps; reason }
  | None ->
    (* non-catastrophic: graded by context overlay.
       autonomous overlay => every level Observe => Allow (+telemetry).
       operator overlay  => Enforced => Ask (resolved by the operator UI). *)
    (match max_risk caps with
     | `Privileged -> trust_dispatch ~trust_level:overlay.privileged_trust ~caps ~policy ~bin:simple.bin ~simple
     | `Audited    -> trust_dispatch ~trust_level:overlay.audited_trust    ~caps ~policy ~bin:simple.bin ~simple
     | `Safe       -> trust_dispatch ~trust_level:overlay.safe_trust       ~caps ~policy ~bin:simple.bin ~simple)
```

`find_destructive_git` no longer reads `privileged_trust` — destructive git is in the floor. This fixes defect §2.2(4): loosening trust never re-enables force-push.

### 5.4 Catastrophic floor membership — typed, no string match

> **Premise correction (code-verified 2026-06-17, supersedes the original
> draft of this section).** The first draft claimed a typed argv `Path_scope`
> extension to `Capability_check.of_ir` was "the only way to detect `rm -rf /`
> without string matching" and made it a supporting change ("P0"). Reading the
> pipeline disproves this: `rm -rf /` is **already blocked downstream of the
> gate** by `Exec_policy.validate_shell_ir_paths`, unconditionally, in both the
> gate-on and gate-off paths. Trace: `path_argument_values "rm" ["-rf"; "/"]`
> returns `["-rf"; "/"]` → `validate_path_values` matches `"/"` via
> `looks_like_path_token` (contains `/`) → `validate_path "/"` fails the
> workspace whitelist (`exec_policy_paths.ml:103`: only registered repos /
> worktree root / `sandbox_workspace_root` are allowed; `/` is none) →
> `Path_outside_whitelist`. The keeper threads `~workdir` on both dispatch
> paths (`keeper_tool_execute_runtime.ml:419,428`), so the `workdir = None`
> no-op branch is not taken. Therefore P0 is **dropped**: adding a typed argv
> walker in `capability_check` while the `looks_like_path_token` heuristic
> remains would be two layers classifying the same fs-path — the
> duplicate-classification anti-pattern (CLAUDE.md workaround bar). Replacing
> the `validate_paths` string heuristic with typed `Path_scope` capabilities is
> a legitimate but larger, separate effort (its own RFC), not bundled here.

The approval floor is therefore expressed over **three typed members**, all
already available — no `Capability_check` change:

- `Destructive_git of Git_op.t` — `Git_op.Destructive` (force-push, `reset --hard`, `clean -fd[x]`, `branch -D`, `push --delete`); classified by `Git_op.of_argv`, not string match. **Not covered by `validate_paths`** (force-push has no path argument), so the floor is the only enforcer — this is the genuine, non-redundant fix.
- `Path_escape` from a write **redirect** outside the workspace (`find_write_escape`, existing).
- `Catastrophic_program of Exec_program.t` — a binary that is catastrophic by identity regardless of arguments (currently `mkfs`, matched via `Exec_program.known bin = Some Mkfs`, binary identity, typed). New `Verdict.deny_reason` constructor.

Path-bearing destructive programs (`rm`, `dd`, `chmod`, `chown`, `mv`) are **deliberately not in the approval floor**: their danger is a function of the *target path*, which `validate_shell_ir_paths` already jails to the workspace downstream of the gate. At the approval-policy layer they are graded in stage 2 (e.g. `rm` is `Privileged`; under the autonomous overlay → `Allow`), and `validate_paths` then denies an out-of-workspace target. `test_rm_root_allowed_at_policy_layer_jailed_downstream` pins this boundary.

> Open (§13): whether `sudo`/`su` (privilege escalation, typed `Exec_program.known`) should join the `Catastrophic_program` floor as defense-in-depth. Fork bombs are rejected earlier as `Too_complex` by the bash subset parser.

### 5.5 Contextual trust via the `per_agent` overlay

`Approval_config.lookup ~actor` already supports per-actor overlays (`approval_config.ml:42-45`), but the PR wires `per_agent = []`, making `agent_id` inert (defect L1). Wire it: the keeper runtime selects an overlay by execution context —

- **autonomous** overlay = `{ safe=Observe; audited=Observe; privileged=Observe }` → non-catastrophic always `Allow` + telemetry (the floor still applies above it).
- **operator/interactive** overlay = `enforced_all` → non-catastrophic `Ask`, resolved by an operator UI (out of scope; the resolver must exist before this overlay is used).

The overlay is data; `decide` is unchanged between contexts. This is the contextual-trust pattern from OpenClaw/Claude Code modes.

### 5.6 Telemetry

`log_verdict` (PR, `shell_command_gate.ml`) belongs in the approval layer, not injected into the shared `gate_typed`/`gate_raw`/`lower_typed_pipeline` (which serve the non-approval path too — defect M4/scope-creep). Relocate it to the approval boundary and log `Allow` decisions as well (the autonomous lane's value is allow-with-telemetry). Keep level `info` for allow/floor-deny; reserve `warn` for genuine policy denials.

## 6. Non-goals

- **Human-in-the-loop approval for the autonomous lane.** There is no human in a keeper's loop; HITL is a category error here (prior art confirms a resolver is required, but for autonomous agents the resolver is a deterministic policy, not a person). HITL belongs only to a future operator context (§5.5) and is out of scope.
- **An auxiliary-LLM "smart" resolver** (Hermes-style). Possible future extension as the operator-overlay resolver; not in this RFC (adds nondeterminism/latency per command).

## 7. PR #21338 triage (KEEP / DROP / REWORK)

| File / change | commit | verdict | rationale |
|---|---|---|---|
| `feature_flag_registry.ml` (flag) | 274 | KEEP | rollout toggle; keep `Experimental` |
| `env_config_runtime.ml/.mli` (`Shell_ir_approval_gate.enabled`) | 274 | KEEP | toggle accessor |
| `keeper_tool_execute_shell_ir.ml/.mli` (`dispatch_classified_with_approval`) | f2cc | KEEP + REWORK | integration point is correct; H1/L4 fixes retained; `Ask` arm becomes unreachable under §5.2 → remove |
| `keeper_tool_execute_runtime.ml` (gate wiring) | 274 + f2cc | REWORK | replace inline `permissive_default`/`per_agent=[]` with §5.1 sandbox branch + §5.5 contextual overlay; drop `Ask`/`Approval_required` arm |
| `keeper_workspace_read_ops.ml` (error arms) | f2cc | REWORK | reads are not `Ask`-blocked under §5.2; floor only |
| `shell_command_gate.ml` + `dune` (`log_verdict`) | f2cc | RELOCATE | move telemetry to the approval boundary; log allows (§5.6) |
| `exec_dispatch.ml/.mli` (`dispatch_async`, `dispatch_decided_outcome`, `argv_of_ir`, `dispatch_outcome`) | f2cc | DROP | no production callers; unrelated to the gate |
| `tool_dispatch.ml/.mli` (`dispatch_many`) | f2cc | DROP | no callers; `~sw` false contract |
| `test_exec_dispatch.ml` | 274 | SPLIT | keep `dispatch_classified_with_approval` tests (rework for §5.2 verdicts); drop async/outcome tests |
| `test_tool_dispatch.ml` (`dispatch_many` tests) | 274 | DROP | with the dead function |

**Not in the PR, added by this RFC:** the `decide` reshape (§5.3), the `catastrophic_floor` + `find_catastrophic_program` + `Verdict.Catastrophic_program` (§5.4), the `Approval_config.autonomous` overlay (§5.5), and the sandbox branch (§5.1). The PR delivers wiring; this RFC supplies the policy the wiring should carry. (The originally-planned `Capability_check` argv-path-scope extension is dropped — §5.4 premise correction.)

> Already landed on the PR branch (`e6275dfbfe`): typed `Verdict.deny_reason_to_string` (H1), nested-pipeline `Too_complex` alignment (L4), doc-ordering fix (M1), deterministic `rm` test (L3). All remain valid; M3 (`Ask` informative summary) becomes moot once `Ask` is removed from the autonomous lane.
>
> P1 landed (this branch, after `a2a8145de8`): `catastrophic_floor` + `find_catastrophic_program` + `Verdict.Catastrophic_program` + `Approval_config.autonomous`, with the floor decoupled from `privileged_trust`. The two pre-RFC-0254 tests that encoded defect §2.2(4) (`git push --force` → `Allow`/`Suggest_confirm` under a loosened overlay) are inverted to assert `Deny`, plus floor-independence/`mkfs`/`rm`-boundary regression tests.

## 8. Implementation plan

P0 (typed argv path-scope) is **dropped** — see the §5.4 premise correction.

1. **P1 — `decide` reshape + `catastrophic_floor` (§5.3–5.4). ✅ done (`approval_policy.ml`, this branch).** Destructive-git moved out of the trust branch into an unconditional floor; added `find_catastrophic_program` (mkfs) and the typed `Verdict.Catastrophic_program` reason; added the `Approval_config.autonomous` overlay. Tests (`lib/exec/test/test_approval_policy.ml`): the floor Denies `git push --force` under every overlay incl. autonomous; `mkfs` Denied under autonomous; `rm -rf /` Allowed at the policy layer (jailed downstream by `validate_paths`); `git status` Allowed under autonomous. Full `lib/exec` suite green (`DUNE_CACHE=disabled dune build --root . @lib/exec/test/runtest`).
2. **P2 — autonomous overlay wiring + sandbox branch (§5.1, 5.5).** In `keeper_tool_execute_runtime.ml`: select `Approval_config.autonomous` for the keeper lane (replace the inline `permissive_default`/`per_agent = []`); `Docker → skip the gate`, `Local → autonomous`. Remove the `Ask`/`Approval_required` arm. (lib/keeper — CI-verified; local full build blocked by the agent_sdk pin drift.)
3. **P3 — telemetry relocation (§5.6).** Remove `log_verdict` from shared `gate_typed`; log at the approval boundary incl. allows.
4. **P4 — drop dead code (§7).** Remove `dispatch_async`/`dispatch_decided_outcome`/`argv_of_ir`/`dispatch_many` + tests.
5. **P5 — verification (§9).**

## 9. Verification

- **TLA+ bug-model** (per the repo's spec-mutation pattern): model the policy as a state machine; `BugAction` = a catastrophic command reaching `Allow`; `SafetyInvariant` `CatastrophicNeverAllowed`. Clean spec: no error. `-buggy.cfg`: invariant violated. Both `.cfg`s must pass their respective expectations.
- **Property:** for all overlays (autonomous, operator, enforced_all), a catastrophic-floor input is `Deny`. Loosening any trust level never produces `Allow` for a floor input.
- **Behavior tests:** `git status`/`dune build`/`pytest` under autonomous overlay → `Allow`; `git push --force` → `Deny`; `rm -rf /` → `Deny`; `rm ./build` → `Allow`; Docker profile → gate skipped.
- **Build:** `lib/exec`, `lib/keeper_tooling`, `lib/keeper` via `scripts/dune-local.sh` (pin-correct env); full `test/test_exec_dispatch.exe` in CI.
- **Non-fatal preservation:** confirm a floor `Deny` returns error JSON (lane keeps turning), never raises.

## 10. Rollout

- Keep `MASC_SHELL_IR_APPROVAL_GATE_ENABLED` default `false` through P0–P4.
- Enable in a single keeper first; confirm via telemetry that the toolchain runs and only floor inputs are denied; then widen.
- Because the autonomous policy is allow-by-default-with-floor, enabling it does not stop the lane (§2.2(3) resolved).

## 11. Alternatives considered

| Option | Description | Why not (primary) |
|---|---|---|
| **0. Delete the gate** | Rely on sandbox containment only | Correct only for Docker; Host has no container boundary. Adopted *for Docker* in §5.1. |
| **B. Observability-only** | Allow all, log, never Deny | Telemetry-as-fix (RFC-0088 anti-pattern); no protection against force-push. |
| **C. LLM "smart" resolver** | Auxiliary LLM resolves `Ask` | Nondeterminism + latency/cost per command for a keeper that runs many. Possible future operator-overlay resolver, not the autonomous default. |
| **D. Capability budget / cooldown** | Allow with rate caps | cap/cooldown symptom-suppression (CLAUDE.md workaround bar); does not classify danger. |
| **E. Escalate containment per-command** | Risky commands → throwaway sandbox | Heavy infra; some ops (push, network) need real creds/network and cannot be fully sandboxed. |
| **F. Typed sub-tools** | Replace raw shell with `GitCommit`/`GitPush-safe` typed tools | Largest redesign; loses generality of shell. Long-term direction, not this RFC. |

The chosen design = **Option 0 for Docker + the autonomous floor model for Host**, which is the minimal change satisfying: lane keeps running, keeper can work, no double-gating, no HITL, and catastrophic protection strengthened (decoupled from trust).

## 12. Workaround-rejection alignment

This RFC **removes** a workaround-shaped construct (`Ask`-dangling: a verdict that surfaces a block but cannot resolve it — adjacent to RFC-0088 "counter-as-fix") and replaces it with a typed, closed decision (Allow / floor-Deny). The floor is typed (`Verdict.deny_reason`, `Capability`, `Path_scope`), not a substring classifier (RFC-0042 lineage). The inert `per_agent` field is wired rather than left as fan-in-0 scaffolding (the exact anti-pattern RFC-0199's Phase-A removal warns about). No telemetry-as-fix, no cap/cooldown, no string match.

## 13. Open questions

1. Should `sudo`/`su` join the `Catastrophic_program` floor (§5.4) as defense-in-depth? They are typed (`Exec_program.known`) and never legitimate for a keeper, but under the autonomous overlay they are currently graded `Privileged → Allow`. P1 left the floor at destructive-git + redirect-escape + `mkfs` per the chosen scope (Option A).
2. Should the `Docker` profile still apply the catastrophic floor as defense-in-depth, or fully trust the container? (Hermes fully skips; defense-in-depth would keep the floor.) — decides P2.
3. Operator-overlay resolver (§5.5) — separate RFC; what UI/protocol resolves `Ask`?
4. Should the `validate_paths` `looks_like_path_token` + `command_materializes_path_arg` string/heuristic layer be replaced with typed `Path_scope` capabilities (a deferred "typed-replacement" RFC)? That is the honest home for the work the dropped P0 was reaching toward — at the validation layer, not a parallel walker in `capability_check`.

## 14. References

- Code anchors (PR head `274ace4e13` + landed `e6275dfbfe`): `lib/exec/approval_policy.ml`, `approval_config.ml`, `capability_check.ml`, `verdict.ml{,i}`, `exec_program.ml`, `sandbox_target.mli`, `lib/keeper_tooling/keeper_tool_execute_shell_ir.ml{,i}`, `lib/keeper/keeper_tool_execute_runtime.ml:186-466`.
- Prior art: claude-code leaked src `src/types/permissions.ts`; openclaw/openclaw; hermes-agent.nousresearch.com/docs/user-guide/security.
- Parent: RFC-0005 ("RFC v5"). Lineage: RFC-0042, RFC-0088, RFC-0199.
