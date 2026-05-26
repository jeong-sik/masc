# Keeper Agent Tool Boundary Audit

- Status: design audit / implementation plan
- Date: 2026-05-25
- Verified at: 2026-05-25T11:01:53+09:00
- Scope: shell/remote command helpers, `keeper_hooks*`, `keeper_sandbox*`,
  `keeper_exec*`, `keeper_shell*`, `keeper_tool*`, `keeper_tools*`,
  Shell IR walkers, `lib/exec/exec_program.ml`, `~/me` PR #814, local
  `claude-code`, OpenClaw, Hermes Agent

## Cold Judgment

MASC is moving in the right direction, but it is not yet a clean next-generation
agent-tool substrate.

The healthy direction is real: public aliases are separated from internal
keeper names; `keeper_bash` is typed argv/pipeline instead of raw `cmd`;
`Keeper_shell_ir` is the center line for classify/gate/path/dispatch;
`Shell_ir_dispatch` owns GH sandbox routing; `Keeper_sandbox_runner` owns
host-vs-Docker dispatch; `Masc_exec.Exec_program` is becoming the executable vocabulary
SSOT; generated Shell IR walkers replaced the earlier hand-written drift point.

The remaining failure mode is also real: ownership is still distributed across
too many implicit surfaces. A reader must compose `Tool_shard`,
`Keeper_tool_alias`, `Keeper_tool_registry`, `Keeper_tool_policy`,
`Keeper_exec_tools`, `Keeper_tools_oas`, `Keeper_shell_*`,
`retired remote-command modules`, and `Keeper_sandbox_*` to answer one simple question:
"what is this tool, who owns it, who executes it, where is it available, and
what boundary contains it?" That is not yet a natural Agent Tool model. It is a
good refactor line that still needs a first-class descriptor spine.

The core correction is not another wrapper. The correction is a typed
owner/executor/availability/sandbox descriptor that every public tool, internal
keeper tool, and MCP/OAS bridge consumes.

## Evidence

- [근거] MASC code snapshot:
  `git worktree add .worktrees/keeper-tool-boundary-audit-20260525 -b analysis/keeper-tool-boundary-audit-20260525 main`,
  HEAD `4063afb0b Refactor keeper shell dispatch axis (#18323)`,
  확인일시 2026-05-25T11:01:53+09:00, 신뢰도 High.
- [근거] Shell IR audit:
  `scripts/audit-shell-ir-consumption.sh`, 확인일시 2026-05-25T11:00:38+09:00,
  신뢰도 High. Results: `Bash.parse_string` 3 files / 3 refs, mutation string
  sig 0 and IR sig 2, keeper `gate_typed` refs 2, risk phantom refs 18,
  `dispatch_decided` consumers 7 files, path validation callers 5, TLA spec 1,
  parallel parser refs 0.
- [근거] Targeted local build attempt:
  `scripts/dune-local.sh build test/test_keeper_sandbox_boundary_policy.exe
  test/test_keeper_bash_safety.exe lib/exec/test/test_shell_ir_walkers_gen.exe`,
  확인일시 2026-05-25T11:00+09:00, 신뢰도 Medium. Result: blocked by
  machine-wide bare Dune processes; no extra Dune job was started.
- [근거] `~/me` PR #814:
  `gh pr view 814 --json ...`, 확인일시 2026-05-25T11:01+09:00, 신뢰도 High.
  PR is merged, `mergedAt=2026-03-16T03:49:30Z`, title
  `feat: apply 3-gap improvements from Claude Agent SDK workshop`.
- [근거] OpenClaw:
  `/private/tmp/openclaw-src`, commit
  `ea3bb9282ca18bbbba37017771a60456837bf909`, cloned from GitHub,
  확인일시 2026-05-25T11:01+09:00, 신뢰도 High.
- [근거] Hermes Agent:
  `/private/tmp/hermes-agent-src`, commit
  `a3abeb5954d41805d8ea205068e2a3725e62ed22`, cloned from GitHub,
  확인일시 2026-05-25T11:01+09:00, 신뢰도 High.
- [근거] Claude Code local checkout:
  `/Users/dancer/me/workspace/yousleepwhen/claude-code`, inspected local files
  `src/tools.ts`, `src/Tool.ts`, `src/tools/BashTool/*`,
  `src/utils/Shell.ts`, `src/utils/shell/bashProvider.ts`,
  확인일시 2026-05-25T11:01+09:00, 신뢰도 Medium because this is a local checkout,
  not a freshly fetched upstream snapshot.

## Current Boundary Map

| Family | Correct owner | Current state | Judgment |
| --- | --- | --- | --- |
| `keeper_tool*` | Tool surface, aliasing, policy, schemas, result shape, disclosure | Split across registry, alias, policy, disclosure, outcome, bash input, GitHub/PR tool modules | Direction is correct, but descriptor ownership is implicit and too hard to audit |
| `keeper_tools*` | OAS/Agent SDK bridge and execution loop integration | `Keeper_tools_oas` wraps keeper tools into OAS tools, normalizes results, tracks retries | Correct bridge layer; should consume descriptors instead of reconstructing policy facts |
| `keeper_exec*` | Category dispatch and side-effect handlers | `keeper_exec_shell.ml` is now a thin facade; `keeper_exec_tools.ml` still owns broad execution/result plumbing | Better than before, but still too central for natural agent tools |
| `keeper_shell*` | Shell read ops, typed Bash lowering, Shell IR facade, path/timeout/runtime-path policy | `Keeper_shell_ir` owns classify/gate/path/dispatch; `keeper_bash` rejects raw `cmd`; shell ops still 1047 LoC | Architecture is right; module granularity still needs ownership table and size caps |
| shell/remote command helpers | GH command parser, repo slug discovery, credentialed GH runner | Parser/repo/runner split exists; `Keeper_shell_command_parse` owns parser/risk adaptation and `Shell_ir_dispatch.run_argv` owns sandbox routing | Correct. The module names now expose the parser/repo/runner axes directly |
| `keeper_sandbox*` | OS/backend isolation, Docker runtime, mounts, credentials, containment, read runner | Docker no longer owns command semantics; runner selects host vs sandbox | Correct boundary. Must keep saying this is the load-bearing boundary, not IR heuristics |
| `keeper_hooks*` | Post-tool/post-turn telemetry, PR metrics, cost/response events | Hooks observe tool IO and command semantics; they do not execute tools | Correct as observer layer. Must not grow execution policy |
| `lib/exec/exec_program.ml` | Closed executable vocabulary and risk/kind classification | `Dev_exec_allowlist` derives names from `Masc_exec.Exec_program`; `exec_program.ml` now uses one exhaustive metadata function plus `all_known` for reverse lookup | Correct center. Keep the metadata/all-known ratchets strict so new executables cannot reintroduce parallel string maps |
| `bin/gen_shell_ir_walkers.ml` | Build-time codegen for GADT walker boilerplate | Generates risk/sandbox/to_simple/of_simple; tests check count/order/round-trip | Justified after PPX failure, but treat as production codegen with drift budgets |

## External Comparison

### Claude Code

Claude Code has an ergonomic single `Bash` tool with `command: string`,
timeout, description, backgrounding, sandbox override, rich UI/progress, and a
large permission pipeline. It ultimately calls `exec(command, ..., 'bash')`,
whose provider builds a shell command string, sources shell/session env, quotes
the command, optionally wraps it in sandbox, and spawns the shell.

Lesson: copy the user-facing ergonomics and progress/result polish, not the raw
string monolith. Claude Code optimizes for interactive compatibility with real
Bash. MASC is deliberately choosing typed argv/pipeline plus Shell IR. That is
the stronger substrate for autonomous agents, provided MASC does not pretend it
supports arbitrary Bash syntax.

### OpenClaw

OpenClaw makes a clean distinction in `src/tools/types.ts`: `ToolDescriptor`
has `owner`, optional `executor`, and optional `availability`; `ToolPlanEntry`
pairs descriptor and executor. Owners and executors can be `core`, `plugin`,
`channel`, or `mcp`. Availability is a typed expression over auth, config, env,
plugin, and context. Plugin tools are resolved through allow/deny rules and
lazy runtime loading.

Lesson: this is the descriptor spine MASC is missing. MASC has the ingredients,
but not the one typed object that says "this is the public surface, this is the
owner, this is the executor, these are the preconditions, this is the sandbox
posture."

### Hermes Agent

Hermes uses a registry/toolset model: tool files self-register schemas and
handlers; `model_tools.py` discovers them and exposes definitions; `toolsets.py`
is the central grouping layer. Its terminal/file tools share terminal backend
isolation. More importantly, `SECURITY.md` is explicit: only OS-level isolation
is a security boundary against an adversarial LLM; approval gates, redaction,
pattern scanners, and allowlists are in-process heuristics.

Lesson: MASC should adopt this trust-model clarity. Shell IR, GADT, allowlists,
and approval queues are excellent deterministic guardrails, but the
load-bearing containment boundary is the OS/backend sandbox.

### `~/me` PR #814

PR #814 added three workflow improvements: live git-status context injection in
`hooks/claude/user-prompt-submit.sh`, adversarial review layer integration, and
grep-like search output formatting. It is not an agent-tool runtime boundary PR.

Lesson: context injection and adversarial review belong to workflow/hook/review
layers. They should inform tool selection and review quality, but must not be
mixed into keeper tool execution policy.

## Self-Critique

1. Boundary progress is substantial, not cosmetic.
   `test/test_keeper_sandbox_boundary_policy.ml` actively asserts that Docker
   does not own command semantics, raw command parsing is centralized, GH tools
   go through `Shell_ir_dispatch`, the retired shared shell facade is gone, old shell/GH
   bridges are absent, and Shell IR dispatch goes through `Keeper_shell_ir`.

2. The system still asks too much of the reader.
   Prefix counts from `rg --files lib/keeper` show the scale:
   `keeper_sandbox` 40 files, `keeper_exec` 38, `keeper_shell` 24,
   `keeper_hooks` 18, `keeper remote command` 8, and `keeper_tool*` 56 raw prefix matches.
   That is survivable only with a canonical ownership matrix and ratchets.

3. `keeper_workspace_ops.ml` is now reduced, but the read-side owner needs the next
   split.
   Slice 12 moves structured read/list/search operations into
   `Keeper_workspace_read_ops`, leaving `keeper_workspace_ops.ml` as a 249 LoC public
   dispatcher for alias normalization, read-op delegation, `git_diff`,
   and unsupported-op reporting. The new read owner is still
   large, so the next P4 slice should split read-file, git-read, and
   listing/search groups out of `Keeper_workspace_read_ops`.

4. The Shell IR audit target and live value disagree.
   The audit reports keeper `gate_typed` refs as 2 while its printed target says
   at least 4. Because the script exits 0, this is a soft ratchet. Either the
   target is stale after moving the call into `Keeper_shell_ir`, or the
   implementation regressed coverage. Leaving that ambiguous is not acceptable.

5. `exec_program.ml` is now a stronger executable-vocabulary center.
   A closed executable vocabulary is exactly the right primitive for typed
   keeper Bash. The prior separate `name_of_known`, `risk_of_known`,
   `kind_of_known`, and `known_of_string` maps have been collapsed behind one
   exhaustive metadata function. `all_known` drives reverse lookup and
   round-trip tests now pin name uniqueness plus risk/kind coherence.

6. `gen_shell_ir_walkers.ml` is justified, but it is now production
   infrastructure.
   The PPX route failed, and generating ordinary OCaml source is a practical
   recovery. The risk is that the generator becomes another hand-written
   shadow spec. Constructor count/order, no-catch-all policies, and generated
   output freshness must be CI ratchets, not informal review expectations.

7. GADT direction is correct but incomplete.
   The GADT encodes risk/sandbox intent in types for known command forms, and
   `Shell_ir_typed` now delegates walkers to generated code. But the production
   center line still runs mostly through untyped `Shell_ir.t` plus risk-stamped
   envelopes. That is acceptable as an incremental bridge, not as a final state.

## Target Architecture

MASC should converge on this explicit stack:

1. Public tool surface:
   `Bash`, `Read`, `Edit`, `Write`, `Grep`, `WebSearch`, MCP/OAS names.
2. Tool descriptor SSOT:
   typed owner, executor, availability, input schema, output schema,
   effect domain, read/write class, sandbox requirement, credential posture.
3. Tool policy:
   shard/preset/allowlist decisions over descriptors, not string mirrors.
4. Domain lowerers:
   `keeper_bash` typed argv/pipeline to Shell IR, `keeper remote command` argv/repo to GH
   runner, file tools to FS/read/write contracts.
5. Execution gate:
   Shell IR classify, typed gate, path validation, approval/side-effect policy.
6. Backend boundary:
   `Keeper_sandbox_runner` and backend-specific sandbox runtime.
7. Observation:
   hooks, PR metrics, cost metrics, dashboard events, history, disclosure.

Anything crossing layers must be explicit. In particular, hooks must not make
execution decisions, sandbox modules must not parse command semantics, and
tool registries must not own backend routing.

## Quantitative Goals

| Goal | Metric | Target |
| --- | --- | --- |
| Boundary map coverage | Every shell/remote command helpers, `keeper_hooks*`, `keeper_sandbox*`, `keeper_exec*`, `keeper_shell*`, `keeper_tool*`, `keeper_tools*` source classified into exactly one owner category | 100% |
| Descriptor SSOT | Public/keeper/MCP tool schemas generated or projected from typed descriptors | 100% of visible tools |
| String mirror removal | Tool read-only/effect/sandbox facts duplicated outside descriptors | 0 unreviewed mirrors |
| Shell parser containment | Non-test `Bash.parse_string` caller files | <= 3, with owner allowlist |
| Shell IR gate clarity | `scripts/audit-shell-ir-consumption.sh` targets match the facade architecture | 0 soft failures / ambiguous target lines |
| Dispatch safety | Production Shell IR dispatch through risk-stamped `dispatch_decided` envelope | 100% of Shell IR dispatch sites |
| Docker boundary | `keeper_sandbox*` references to shell-surface module names or command semantic functions | 0 |
| GH boundary | GH tool execution bypassing `Shell_ir_dispatch.run_argv` | 0 |
| Typed Bash legacy | Advertised `cmd` field in `keeper_bash` schema | 0 |
| Typed Bash compatibility debt | Backward-only aliases such as `stages` documented with removal issue or accepted as permanent | 100% resolved |
| GADT/codegen freshness | Constructor count/order/golden output checked in CI | 100% |
| `Exec_program` SSOT drift | New executable constructor without name/risk/kind/string mapping test failure | 0 possible |
| Module size | `keeper_workspace_ops.ml`, `keeper_sandbox_docker.ml`, `keeper_exec_tools.ml` | each < 700 LoC or documented exception |
| Security doctrine | Docs that mention sandbox/approval/allowlists state OS boundary vs heuristic distinction | 100% |

## Implementation Plan

### P0: Freeze The Map

- Add `docs/design/keeper-tool-boundary-matrix.md` listing every relevant
  module and exactly one owner category.
- Add a source audit script that fails when a new matching module is absent
  from the matrix.
- Clarify the Shell IR audit `gate_typed` target: if `Keeper_shell_ir` is now
  the intended facade, the target should count facade coverage, not raw refs.

Exit criteria:
- Matrix coverage 100%.
- `scripts/audit-shell-ir-consumption.sh` has no informational target mismatch.
- Boundary policy test still passes.

### P1: Introduce `Keeper_tool_descriptor`

Define a typed descriptor close to:

```ocaml
type owner =
  | Public_alias of string
  | Keeper_internal of Tool_name.t
  | Masc_mcp of string
  | Oas_bridge

type executor =
  | Keeper_handler of Tool_name.t
  | Shell_ir_exec
  | Gh_runner
  | Fs_runner
  | External_mcp of string

type availability =
  | Always
  | Requires_tool_access of Keeper_tool_policy.preset
  | Requires_env of string
  | Requires_credential of string
  | Any of availability list
  | All of availability list

type t =
  { public_name : string option
  ; internal_name : string
  ; owner : owner
  ; executor : executor
  ; availability : availability
  ; input_schema : Yojson.Safe.t
  ; output_schema : Yojson.Safe.t option
  ; effect_domain : Tool_catalog.effect_domain
  ; readonly : Yojson.Safe.t -> bool
  ; sandbox : [ `Host | `Docker | `Backend_selected | `None ]
  }
```

Then make `Tool_shard`, `Keeper_tool_alias`, `Keeper_tool_registry`, and
`Keeper_tools_oas` consume projections from this descriptor instead of owning
parallel facts.

Exit criteria:
- Public aliases, shard schemas, read-only classifications, tool search, and
  OAS bridge all derive from descriptors.
- Unknown/hallucinated names still collapse to bounded telemetry labels.

### P2: Finish Shell IR / GADT Hardening

- Decide whether `Shell_ir_typed` is a producer-side API, a classifier-only
  API, or a long-term typed command DSL.
- If it is long-term, add typed constructors only for commands with stable
  semantics; keep `Generic` fail-closed.
- Keep `Masc_exec.Exec_program` metadata and `all_known` golden checks strict; do not
  reintroduce parallel string/risk/kind maps.
- Add a freshness check for generated `Shell_ir_typed_walkers_gen`.

Exit criteria:
- New Shell IR constructor or new `Exec_program.known` constructor cannot merge without
  updating every required generated/golden mapping or metadata ratchet.
- No catch-all in risk/sandbox walkers except explicit `Generic`.

### P3: Security Boundary Doctrine

- Add a short trust-model section to the keeper tool/sandbox docs:
  Shell IR, approval gates, read-only flags, and tool allowlists are
  deterministic guardrails, not adversarial containment.
- State that containment is provided by the OS/backend sandbox and by
  whole-process wrapping where available.
- Audit docs/RFCs for wording that implies in-process heuristics are a security
  boundary.

Exit criteria:
- 100% of sandbox/security docs use the same boundary language.
- Any bypass report can be triaged against an explicit boundary claim.

### P4: Reduce Module Load

- Continue splitting shell operation groups:
  `keeper_workspace_ops.ml` is now the public dispatcher, and
  `Keeper_workspace_read_ops` should next split read-file ops, git read ops,
  listing/search ops, and result/history rendering.
- Keep `Keeper_shell_command_parse` as parser/risk adaptation only; do not let
  repo discovery or GH execution drift back into it.
- Keep `keeper_exec_shell.ml` as facade only; prevent new logic from landing
  there.

Exit criteria:
- `keeper_workspace_ops.ml` below 700 LoC or exception documented.
- No `*_shared` module owns mixed policy/parse/run behavior.

### P5: Runtime Proof Surface

- Add a dashboard/debug view that shows, per tool call:
  public name, internal name, descriptor owner, executor, availability result,
  policy decision, sandbox route, credential posture, Shell IR risk, and final
  backend.
- Emit a durable JSONL receipt for descriptor resolution and execution routing.

Exit criteria:
- A failed or surprising tool call can be explained from one receipt without
  reading source.
- Tool route evidence survives process restart.

## Final Position

The work is not a legacy-ridden failure. The core direction is strong:
typed Bash, Shell IR, risk-stamped dispatch, backend-neutral sandbox routing,
and generated GADT walkers are the right ingredients.

But the system will become legacy-ridden if it stops here. The danger is not
one bad module; it is allowing the current implicit federation of shard, alias,
registry, policy, execution, and hooks to become the permanent SSOT. The next
step must be a first-class Agent Tool descriptor spine with ratchets, not more
ad hoc cleanup around the edges.
