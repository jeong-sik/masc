---
status: draft
last_verified: 2026-06-26
code_refs:
  - docs/design/tool-execution-substrate-plan.md
  - docs/rfc/RFC-0290-keeper-background-wait-tool.md
  - docs/KEEPER-CAPABILITY-MATRIX.md
  - lib/keeper/keeper_tool_descriptor.ml
  - lib/keeper/keeper_world_observation.ml
  - lib/keeper/keeper_heartbeat_stimulus_intake.ml
  - lib/process/process_eio_detached.ml
  - lib/process/bg_task.ml
---

# External Tool Surface Audit

## Scope

This audit covers the keeper-facing external tool/CLI surface for GitHub,
git, Jira, Notion, Figma, browser automation, and future long-running tools.
The goal is not to add a service-specific tool for each external system. The
goal is to make the existing typed surface discoverable, wake-capable, and
operationally safe without reintroducing raw-shell policy or prompt-only
constraints.

## Current Decision

MASC should keep the public model-facing surface small:

- `Execute` for external CLI work, including `gh`, `git`, `jira`, `notion`,
  `figma`, or local vendor CLIs, always as one typed non-empty `argv` process vector.
- `Read`, `Grep`, `Edit`, and `Write` for structured filesystem work.
- `WebSearch` and `WebFetch` for current external evidence.
- MASC-owned domain tools for board, task, goal, memory, keeper lifecycle, and
  discovery/introspection.

Do not add `Gh_cli`, `Git_cli`, `Jira_cli`, `Notion_cli`, `Figma_cli`, or
`Oas_bridge` descriptor executors. The descriptor executor closed set is still
`Shell_ir`, `Filesystem`, and `In_process` in
`lib/keeper/keeper_tool_descriptor.ml`; the capability matrix already says
GitHub PR and issue work goes through `Execute` with typed `gh` argv.

## Finding 1: Service-Specific CLI Tools Would Be a Surface Regression

Status: keep blocked

`docs/design/tool-execution-substrate-plan.md` already rejects `Gh_cli` and
`Oas_bridge` executors. The current descriptor implementation matches that
decision: `lib/keeper/keeper_tool_descriptor.ml` exposes only `Shell_ir`,
`Filesystem`, and `In_process`. That is the right boundary.

Operational impact: adding a `gh_pr_comment` or `jira_ticket_update` tool would
create another product API that must duplicate Shell IR risk classification,
cwd/path validation, credential handling, audit receipts, replay semantics,
and review UX. It would also make every external service plugin a new policy
surface. Typed `Execute` already carries the actual command as data; the missing
piece is better discovery and receipts, not new executor variants.

Acceptance bar before adding any new external-service tool:

- it must read or mutate MASC-owned domain state, or
- it must provide structured review UX that `Execute` cannot safely provide, or
- it must front current evidence where raw CLI output is not enough.

Otherwise, use `Execute` plus a skill/runbook/toolset hint.

## Finding 2: Background Completion Delivery Is Now the Right Primitive Shape

Status: first slice implemented in PR #22326

RFC-0290 picks wake-on-completion over a blocking wait tool. The code slice in
PR #22326 makes `Bg_completed` actionable by converting it into a
`pending_board_event` and returning it from heartbeat stimulus intake. This
matches the already-proven fusion completion path and avoids making a keeper's
single turn fiber block on `Eio.Promise.await`.

Code anchors:

- `lib/keeper/keeper_world_observation.ml`: `Bg_completed` is converted through
  `pending_board_event_of_bg_job_completion`.
- `lib/keeper/keeper_heartbeat_stimulus_intake.ml`: the intake arm now returns
  the converted event instead of `[]`.
- `test/test_fusion_wake.ml`: regression coverage asserts success, failure,
  fallback post id, and stimulus conversion.

This is intentionally not a full background-spawn implementation. It fixes the
silent drop first, so later registry/spawn work has a typed wake path to land
on.

[근거] Eio Promise docs say `await` blocks until resolution, while Eio Fiber
docs say `fork` attaches work to a switch and does not wait for completion;
checked 2026-06-26 KST; confidence High:
https://ocaml-multicore.github.io/eio/eio/Eio/Promise/index.html ,
https://ocaml-multicore.github.io/eio/eio/Eio/Fiber/index.html

## Finding 3: Generic Background Subprocess Work Must Not Reuse Current Fork/Thread Shape

Status: P0 design blocker before generic subprocess spawn

`lib/process/process_eio_detached.ml` uses `Unix.fork` in both
`spawn_detached` and `spawn_detached_devnull`. `lib/process/bg_task.ml` then
uses `Thread.create` for the exit watcher. That shape is acceptable only if the
runtime is known not to have spawned OCaml domains or threads before fork. A
keeper/server process using Eio and background workers cannot assume that.

The practical risk is not theoretical:

- `Unix.fork` can fail once any domain has been spawned.
- if any `Thread` module thread has been spawned, the fork child may be
  corrupted.
- after `bg_task` starts one watcher thread, future forks are in the
  thread-after-fork danger zone.

Do not wire `masc_bg_spawn` to this detached subprocess substrate as-is.
The generic background executor needs a process-spawn substrate that does not
depend on unsafe post-thread `fork`, or a narrow proof that it runs before any
threads/domains exist. The safer direction is a posix_spawn-style helper or a
single supervised process manager with explicit lifecycle and receipt state.

[근거] OCaml 5.4 `Unix.fork` documentation states that fork fails after any
domain is spawned and that a child may be corrupted after any `Thread` module
thread has been spawned; checked 2026-06-26 KST; confidence High:
https://ocaml.org/manual/5.4/api/Unix.html

## Finding 4: Switch Lifetime Must Be an Acceptance Test, Not a Comment

Status: P0 design blocker before generic subprocess spawn

RFC-0290 already identifies the resource-shape issue: background work must
outlive the keeper turn, but subprocess pipes and cleanup hooks must not be
owned by the server-lifetime switch forever. Eio switches are the lifetime
container for fibers and resources; resources attached to a switch cannot
outlive it, and cleanup runs when the switch finishes.

Acceptance criteria for the next implementation slice:

- root/server switch owns the background fiber only;
- each subprocess run owns FDs in an inner switch that exits at command
  completion;
- cancellation preserves `Eio.Cancel.Cancelled` and does not broad-catch it;
- FD-count regression proves the process returns near baseline after many
  completed jobs;
- cap rejection is functional backpressure, not telemetry-only accounting.

[근거] Eio Switch docs define switches as the owner of fibers/resources and
state that `Switch.run` waits for attached fibers then releases resources;
checked 2026-06-26 KST; confidence High:
https://ocaml-multicore.github.io/eio/eio/Eio/Switch/index.html

## Finding 5: Discovery Is the Missing Product Surface

Status: next non-invasive slice

The current surface is safer than a service-tool explosion, but it is still
hard for keepers to discover the right typed command shape and policy result.
The capability matrix says "use `Execute` with typed argv", but operators and
keepers still need a compact introspection path that answers:

- which tools are currently exposed to this keeper;
- why a tool is hidden or denied;
- which external CLI profiles are available from this repo/worktree context;
- which command shape was classified as read, reversible mutation, or
  destructive;
- which sandbox/credential profile will be used before execution.

This should be discovery/introspection over the existing descriptor/Shell IR
state, not a new service-specific executor. A good v1 is a read-only
`keeper_tools_list`/descriptor projection improvement that includes executor,
public alias, schema shape, policy group, and a few typed examples for `gh`,
`git`, and test commands.

## Sequenced Work

1. Land PR #22326 after inherited main CI is unblocked. This removes the
   current silent `Bg_completed` drop.
2. Add descriptor/tool discovery detail for typed `Execute` examples and policy
   projections. Keep it read-only and data-derived.
3. Design a safe subprocess background substrate. Treat current
   `fork`/`Thread.create` shape as a blocker for generic keeper background
   subprocesses.
4. Add registry, cap rejection, terminal-once, FD non-leak, and duplicate
   poll/wake consumption tests before exposing `masc_bg_spawn`.
