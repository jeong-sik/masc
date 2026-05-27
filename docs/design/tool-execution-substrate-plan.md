# Tool Execution Substrate Plan

Status: decision plan
Created: 2026-05-27
Scope: keeper agent tool surface, descriptor spine, Shell IR, and tool admission rules
HTML companion: `docs/design/tool-execution-substrate-plan.html`

## Decision

MASC should keep a small, primitive, typed tool surface:

- `Execute`
- `SearchFiles`
- `ReadFile`
- `EditFile`
- `WriteFile`
- `SearchWeb`
- `FetchWeb`

`Shell_ir` is the first-class internal execution substrate behind `Execute`
and `SearchFiles`. It is not a model-facing tool name and not a feature family.
It is the typed language-level representation that carries command structure,
risk, path validation, sandbox target, and dispatch evidence.

Do not introduce `Gh_cli` or `Oas_bridge` as descriptor executors.

- GitHub and git work are ordinary `Execute` calls with typed `executable` and
  `argv`, usually `gh` or `git`, from a scoped `cwd`.
- OAS is a model/run/provider boundary and hook observation path. It is not a
  user tool executor.
- GitHub comments, PR review, PR close, branch commits, and PR edits are not
  dedicated tools. They are CLI workflows expressed through `Execute`, or they
  are runbooks/skills when they need operator guidance.

This reverses the earlier micro-tool failure mode: dedicated PR
comment/review/close wrappers and gh-specific PR/commit wrappers made simple
CLI actions into product APIs. They increased schemas, prompt hints, policy
cases, receipts, tests, docs, and vendor coupling without improving the core
safety model.

## Current MASC Baseline

Current main already points in the right direction.

- `Agent_tool_descriptor.executor` is a closed set of `Shell_ir`,
  `Filesystem`, `Remote_mcp`, and `In_process`.
- `Execute` and `SearchFiles` are descriptor-routed through `Shell_ir`.
- `ReadFile`, `EditFile`, and `WriteFile` are descriptor-routed through
  `Filesystem`.
- `SearchWeb` and `FetchWeb` are descriptor-routed through `Remote_mcp`.
- RFC-0160 is implemented: typed Execute lowers once to Shell IR, classifies
  the resulting IR, gates write/destructive behavior, validates paths, and
  dispatches via the decided IR path.
- The keeper capability matrix already states that GitHub PR and issue work
  uses `Execute` with `executable = "gh"` and typed `argv`.
- A 2026-05-27 live `scripts/audit-shell-ir-consumption.sh --json` run shows
  the Shell IR substrate remains mostly in target range. One metric needs audit
  maintenance: `g3_gate_typed_refs_in_keeper = 2`, while RFC-0160's historical
  target was `>= 4`. This appears to be a measurement drift caused by routing
  through the centralized `Agent_tool_execute_shell_ir` facade rather than
  direct `gate_typed` calls in many keeper files. PR-E must prove this or fix
  a real coverage regression before closing.

The remaining risk is not missing a `Gh_cli` executor. The risk is letting
micro-tools re-enter through convenience pressure.

## External Comparison

### OpenClaw

OpenClaw exposes a small set of built-in tools plus optional skills and MCP
tools. Its built-in shell command tool accepts arbitrary shell commands and is
documented as high risk, disabled by default, and suitable for allowlists.

What to borrow:

- Treat shell execution as privileged and policy-controlled.
- Keep built-in tools few enough that users can understand them.
- Prefer allowlists for dangerous execution capability.

What not to copy:

- Do not expose raw shell strings as the normal model-facing shape.
- Do not make the shell tool the place where every semantic policy is
  re-parsed from text.

### Hermes Agents

Hermes Agents has a broad toolset model. It documents many built-in tools,
toolsets, terminal/process backends, file tools, browser tools, memory tools,
delegation tools, and dynamically generated MCP tools.

What to borrow:

- Toolsets are useful for grouping capability exposure.
- Terminal/process execution can be backend-selectable without changing the
  model-facing tool contract.
- MCP tools should be namespaced and treated as remote capabilities.

What not to copy:

- Do not let tool count grow into a second product API.
- Do not mirror every remote service operation as a first-class agent tool.
- Do not expose `mcp_github_*`-style operations to keepers when `gh` typed argv
  is enough.

### Claude Code Local Tool Model

The local `claude-code` tree exposes many concrete tools: `Bash`, `Glob`,
`Grep`, `FileRead`, `FileEdit`, `FileWrite`, `WebFetch`, `WebSearch`, task
tools, MCP resource tools, and optional feature-flagged tools. Its Bash prompt
explicitly tells the model to prefer dedicated tools for file/search work
because they provide better review and permission UX. Its execution path has a
central permission decision before tool execution.

What to borrow:

- File and search operations deserve structured tools because they improve
  review, permissions, summaries, and diffs.
- The execution service should emit an explicit permission decision with the
  tool name and source.
- Optional tool groups must be capability-scoped.

What not to copy:

- Do not expose raw `Bash` as the primitive. MASC should expose typed
  `Execute`, then lower into Shell IR.
- Do not split every common command into its own public tool.
- Do not use prompt preference alone as the boundary. MASC should enforce the
  boundary in descriptor projections and tests.

## MASC Rules

### Rule 1: Commands Are Not Tools

A CLI operation is not a new MASC tool when it can be represented as:

```json
{
  "executable": "gh",
  "argv": ["pr", "comment", "123", "--body", "..."],
  "cwd": "/path/to/repo"
}
```

The same rule applies to `git`, `pnpm`, `npm`, `dune`, `curl`, `jq`, and other
ordinary executables. The policy surface belongs to Shell IR classification,
cwd/path scope, sandbox target, credential profile, and execution receipt.

### Rule 2: New Tools Need Domain State

A new tool is admissible only when at least one condition holds:

- It mutates or reads MASC-owned domain state that is not naturally a local CLI
  command, such as tasks, board posts, goals, approvals, memory, personas, or
  keeper lifecycle.
- It needs structured review UX that a command cannot provide safely, such as
  `EditFile` diff semantics.
- It fronts a remote capability whose primary value is current evidence, such
  as web search/fetch with citations.
- It is a discovery or introspection tool required to keep the tool surface
  manageable, such as tool search/list.

If the only reason is "the model often does this", create a prompt rule, skill,
or runbook instead of a tool.

### Rule 3: Executors Stay Primitive

Descriptor executors remain:

- `Shell_ir`
- `Filesystem`
- `Remote_mcp`
- `In_process`

Rejected executor variants:

- `Gh_cli`: use `Shell_ir` with `executable = "gh"`.
- `Git_cli`: use `Shell_ir` with `executable = "git"`.
- `Oas_bridge`: OAS is provider/run plumbing and hook observation, not a tool
  executor.
- `Browser_vendor_*`: if browser automation becomes necessary, it should first
  appear as a remote/toolset boundary with explicit evidence and policy, not as
  an ad hoc executor variant.

### Rule 4: Shell IR Is Internal and Typed

`Execute` accepts typed argv or an explicit pipeline. It must not accept raw
shell strings, shell quoting, redirects, glob expansion, command chaining, or
subshell syntax as the model-facing contract.

The internal flow is:

1. Parse typed JSON into typed Execute input.
2. Lower to `Shell_ir.t`.
3. Classify to a decided Shell IR envelope.
4. Gate risk, write permission, command allowlist, and path scope.
5. Select sandbox target.
6. Dispatch the decided IR.
7. Emit receipt evidence.

### Rule 5: Hooks Observe

Hooks and OAS callbacks may record observations, summaries, and receipt
projections. They must not own tool policy, tool routing, sandbox decisions, or
GitHub semantics.

### Rule 6: Evidence Must Include the Route and the Decision

Every descriptor-backed tool call should emit:

- descriptor id
- public name
- internal name
- executor
- backend
- sandbox
- runtime handler
- policy metadata
- actual permission/gate decision
- decision reason
- Shell IR risk class when applicable

Static descriptor evidence is not enough. The receipt must show why this
specific call was allowed, blocked, or escalated.

## Concrete Work Plan

### PR-A: Decision Plan and Ratchet Targets

Document this plan and make it the reference for future tool-surface review.

Validation:

```bash
git diff --check
```

### PR-B: Descriptor Executor Ratchet

Status: implemented in this PR as a narrow active-surface lint plus CI/source
guard wiring.

Add tests that fail if descriptor executor variants reintroduce:

- `Gh_cli`
- `Git_cli`
- `Oas_bridge`

Also add a source ratchet for micro-tool names in active descriptor, prompt, and
tool hint surfaces:

- dedicated PR comment wrapper
- dedicated PR review wrapper
- dedicated PR close wrapper
- gh-specific PR wrapper
- gh-specific commit wrapper
- GitHub comment wrapper

Validation:

```bash
bash scripts/lint/no-tool-substrate-adapter-surface.sh --fail
scripts/dune-local.sh build test/test_ci_hardening_source.exe
./_build/default/test/test_ci_hardening_source.exe test source_guard 28
```

### PR-C: Prompt and Matrix Alignment

Status: implemented in this PR for keeper-facing web aliases and protected by
the active-surface lint/source guard.

Normalize keeper-facing prompts to the active public names:

- `SearchWeb`
- `FetchWeb`
- `SearchFiles`
- `ReadFile`
- `EditFile`
- `WriteFile`
- `Execute`

Keep the `masc_web_search` / `masc_web_fetch` MCP contract documented only
where MCP public compatibility requires it. Model-facing keeper instructions
should not ask keepers to call `masc_web_search` when the active public alias is
`SearchWeb`.

Validation:

```bash
bash scripts/lint/no-tool-substrate-adapter-surface.sh --fail
scripts/dune-local.sh build test/test_ci_hardening_source.exe
./_build/default/test/test_ci_hardening_source.exe test source_guard 28
```

### PR-C.1: Claim Lock Contention Hardening

Status: implemented in this PR as a runtime robustness slice.

Preserve distributed backlog lock contention as a typed transient tool failure
instead of flattening it through `Claim_next_error` and reclassifying it as a
workflow rejection. The tool result now carries `failure_class=transient_error`,
retry metadata, the lock key, attempt count, and best-effort current-holder
diagnostics.

Validation:

```bash
scripts/dune-local.sh build test/test_tool_task_coverage.exe test/test_distributed_lock_acquire_failed_counter.exe
./_build/default/test/test_tool_task_coverage.exe test coverage 49
./_build/default/test/test_distributed_lock_acquire_failed_counter.exe
```

### PR-D: Actual Policy Decision Evidence

Extend per-tool call evidence beyond static descriptor metadata:

- `policy_decision`: `allow`, `deny`, `ask`, or `escalate`
- `decision_source`: descriptor policy, shell gate, path validator, sandbox,
  approval queue, or hook observation
- `decision_reason`
- `shell_ir_risk_class` for `Shell_ir` executor routes

Turn-level receipts should aggregate this, but the per-call JSONL remains the
authoritative source.

Validation:

```bash
scripts/dune-local.sh build test/test_keeper_tool_alias.exe test/test_execution_receipt*.exe
```

### PR-E: Shell IR Closeout Audit

Re-run the Shell IR audit before claiming the substrate is still clean.

```bash
scripts/audit-shell-ir-consumption.sh --json
```

Expected state:

- non-test `Bash.parse_string` callers remain at the RFC-0160 target
- parallel parser refs remain zero
- dispatch consumers use decided IR
- no raw GitHub simple-command dispatch path returns
- `G3` is either restored as a meaningful coverage metric or replaced with a
  facade-aware metric. A lower direct `gate_typed` grep count is acceptable only
  if all `Shell_ir` executor paths still route through
  `Agent_tool_execute_shell_ir.dispatch` or `dispatch_classified`.

### PR-F: GitHub Workflow Guidance Cleanup

Delete or rewrite any docs, prompts, or hints that imply dedicated GitHub tools
for PR comments, PR review, PR close, commits, or issue mutation.

Replacement guidance:

- Use `Execute` with typed `gh` argv for GitHub remote operations.
- Use `Execute` with typed `git` argv for local repository operations.
- Use runbooks or skills for multi-step workflows.
- Use tasks/board/goals tools only for MASC-owned state.

Validation:

```bash
scripts/lint/no-tool-substrate-adapter-surface.sh --fail
```

The only accepted active-surface hits should be ratchet tests or this decision
plan. Broader scans may still find dashboard/reporting metrics and tests for
retired PR review concepts. Those are work-category names, not active tool
names, and should be classified separately instead of deleted by string match.

## Review Checklist for Future Tool Additions

Before adding any new public or internal tool, answer:

1. Can this be done by `Execute` with typed argv?
2. Can this be done by `ReadFile`, `EditFile`, `WriteFile`, or `SearchFiles`?
3. Is the state owned by MASC rather than by a CLI or remote service?
4. Does the tool add a stable semantic contract, or just wrap a vendor command?
5. What policy decision will the receipt record for each call?
6. What source ratchet prevents future name drift?

If answers 1 or 2 are yes, do not add a tool.

## Evidence

[evidence] 2026-05-27, confidence High: local repo
`lib/keeper/agent_tool_descriptor.mli` defines executor variants as `Shell_ir`,
`Filesystem`, `Remote_mcp`, and `In_process`.

[evidence] 2026-05-27, confidence High: local repo
`lib/keeper/agent_tool_execute_runtime.ml` lowers typed Execute input to Shell
IR, classifies the IR, gates destructive/write behavior, and dispatches the
classified IR.

[evidence] 2026-05-27, confidence High: local repo
`docs/rfc/RFC-0160-shell-ir-first-class.md` records Shell IR first-class status
as implemented. A live audit on 2026-05-27 returned G1=3, G2 string=0/IR=2,
G4 phantom=18, G5=4, G6=1, and G7=0. It also returned G3=2, which requires
metric follow-up because the current facade structure may make the old direct
`gate_typed` grep heuristic stale.

[evidence] 2026-05-27, confidence High: local repo
`docs/KEEPER-CAPABILITY-MATRIX.md` records GitHub PR/issue work as `Execute`
with typed `gh` argv.

[evidence] 2026-05-27, confidence Medium:
OpenClaw official docs describe built-in tools and a shell command tool that
executes arbitrary shell commands, is high risk, and is disabled by default:
https://openclawdoc.com/docs/agents/overview/
https://openclawdoc.com/docs/agents/shell-commands
OpenClaw source repository:
https://github.com/openclaw/openclaw

[evidence] 2026-05-27, confidence Medium:
Hermes Agents official docs describe broad built-in toolsets, terminal/process
tools, file tools, delegation tools, and MCP-prefixed dynamic tools:
https://hermes-agent.nousresearch.com/docs/reference/tools-reference/
Hermes Agent source repository:
https://github.com/NousResearch/hermes-agent

[evidence] 2026-05-27, confidence High: local repo
`/Users/dancer/me/workspace/yousleepwhen/claude-code/src/tools.ts`,
`src/tools/BashTool/prompt.ts`, and `src/services/tools/toolExecution.ts` show a
large concrete tool catalog, Bash guidance that prefers dedicated file/search
tools, and a central permission decision before execution.
