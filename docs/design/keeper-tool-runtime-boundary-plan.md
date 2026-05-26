# Keeper Tool Runtime Boundary Plan

Last updated: 2026-05-25

## Problem

Keeper execution currently has several module names that couple tool
surfaces to runtime environments, for example shell/bash/GitHub logic
combined with Docker-specific helpers. This makes Docker vs local look
like a tool semantics choice, even though sandbox backend selection
should be orthogonal to typed command validation, Git/GitHub semantics,
and public tool aliases.

## Principles

- Public tool surfaces name user capabilities: `Bash`, `Grep`, `Read`,
  `Edit`, `Write`, `WebSearch`, `WebFetch`, and PR tools. Internal
  `keeper_*` handler names stay routing details unless a keeper-native schema
  explicitly exposes them.
- Sandbox modules name runtime responsibilities: backend selection,
  target construction, mounts, credentials, process execution, failure
  recording.
- Git and GitHub modules name domain semantics: repo context, `gh`
  command validation, credential binding, PR workflow.
- Docker/local selection must happen after command input is typed,
  parsed, permission-gated, and lowered to the backend-neutral execution
  request.

## Refactor Sequence

1. Decouple obvious godfile-decomp helpers from shell/docker names.
   Done in this slice:
   - `Keeper_shell_docker` -> `Keeper_sandbox_docker`
   - `Keeper_shell_docker_exec_failure` -> `Keeper_sandbox_exec_failure`
   - `Keeper_shell_bash_docker` -> `Keeper_sandbox_shell_ir_target`

2. Replace direct `Keeper_sandbox_docker` calls from tool-specific modules
   with a backend-neutral sandbox command runner facade. No legacy
   `run_docker*` compatibility aliases remain in `Keeper_shell_shared`.
   Tool modules now pass host and backend command projections to
   `Keeper_sandbox_runner.run_command_with_status`; the runner decides
   whether the command executes on the host or through the sandbox backend.

3. Remove the legacy Git/GitHub compatibility ops from `keeper_shell`.
   GitHub access now belongs to dedicated PR tools and typed command
   paths; `keeper_shell_ops.ml` no longer dispatches `op=gh` or
   `op=git_clone`, and the bridge modules/tests were deleted instead
   of kept as compatibility shims.

4. Collapse local-vs-Docker result shaping so command failures carry the
   same semantic fields regardless of backend. Backend-specific details
   may remain as optional evidence fields.
   Started in slice 5:
   - `Keeper_sandbox_runner` now owns the route label via
     `route_for`/`route_via`.
   - The removed `Keeper_shell_gh_bridge` and
     `Keeper_shell_git_bridge` shims no longer shape compatibility
     output.
   - `test_keeper_sandbox_runner` pins host/backend route labels for
     native tool and typed command execution.

5. Tighten boundary tests so new modules cannot reintroduce
   `shell_docker` or `shell_bash` names for sandbox-runtime concerns.
   Started in slice 6:
   - `Keeper_sandbox_read_runner` now hides Docker-routed read execution
     behind a backend-neutral facade.
   - `keeper_shell_ops.ml` no longer calls `Keeper_sandbox_read_backend`
     directly and uses runner-owned backend route labels for read
     responses.
   - `test_keeper_sandbox_read_runner` uses an injected mock backend to
     pin the read facade without invoking Docker.
   - `test_keeper_sandbox_boundary_policy` now fails if structured shell
     read ops reselect `Keeper_sandbox_read_backend` or hard-code `via=docker`.
   Continued in slice 7:
   - `keeper_fs_read` now uses `Keeper_sandbox_read_runner` instead of
     selecting `Keeper_sandbox_read_backend` directly.
   - `keeper_fs_read` and `keeper_fs_edit` no longer hard-code
     `via=docker`; backend route labels come from the sandbox runner
     facades.
   - `test_keeper_sandbox_boundary_policy` now fails if file tools
     reselect `Keeper_sandbox_read_backend` or hard-code `via=docker`.
   Continued in slice 8:
   - `Keeper_docker_read` was retired in favor of
     `Keeper_sandbox_read_backend`, so the read path no longer exposes a
     tool-shaped Docker module name.
   - The read backend interface now exports backend-neutral
     `read_file`/`run_command` functions; Docker/container wording stays inside
     implementation details and tests.
   - `test_keeper_sandbox_boundary_policy` now fails if the retired
     `keeper_docker_read` files or `Keeper_docker_read` references return.
   Continued in slice 9:
   - `Keeper_sandbox_docker` now runs host-side Docker process execution
     under the sandbox backend actor, not the public shell tool actor.
   - `test_keeper_sandbox_boundary_policy` now fails if sandbox backend
     sources use `Keeper_shell` as their process execution actor.
   Continued in slice 10:
   - `Keeper_shell_ir` now owns the reusable Shell IR facade:
     typed argv construction, risk classification, command gate,
     optional pre-path validation, path validation, and `dispatch_decided`.
   - `keeper_shell_ops.ml` uses that facade for host-side structured
     IR-backed `pwd`, `git_status`, `ls`, `cat`, `rg`, `git_log`,
     `find`, `head`, `tail`, `wc`, `tree`, and `git_diff` paths instead of repeating the
     gate/validate/dispatch sequence locally or falling back to raw
     host argv execution.
   - `keeper_shell_bash.ml` now keeps only bash-specific risk blocking,
     environment capture, timing, and response rendering locally; the shared
     gate/path/dispatch chain runs through `Keeper_shell_ir.dispatch_classified`.
   - `keeper_shell_command_parse.ml` keeps the GH command parser surface, but GH
     command IR construction and risk classification now delegate to
     `Keeper_shell_ir.simple` / `Keeper_shell_ir.classify`.
   - `keeper_sandbox_docker.ml` still owns Docker command rewriting and
     sandbox-context resolution, but Shell IR path validation now goes through
     `Keeper_shell_ir.validate_paths`.
   - `Shell_ir_dispatch` now owns shared GH argv execution through
     `Keeper_sandbox_runner`; dedicated PR helper wrappers have been retired,
     so PR-specific credentials, cwd selection, and JSON envelopes no longer
     live behind a separate keeper tool surface.
   - `test_keeper_sandbox_boundary_policy` now fails if
     `keeper_shell_ops.ml` or `keeper_shell_bash.ml` reintroduces local
     `gate_typed`, `validate_shell_ir_paths`, or `dispatch_decided`; it also
     blocks raw `Shell_ir.Simple`/`Lit` construction in `keeper_shell_ops.ml`
     and raw GH IR construction/classification in `keeper_shell_command_parse.ml`, plus
     direct path validation in `keeper_sandbox_docker.ml` and direct sandbox
     routing in concrete GH tool modules. It also blocks
     `Keeper_shell_shared.run_argv_with_status_retry_eintr` from returning to
     `keeper_shell_ops.ml`.
   Continued in slice 11:
   - `Dev_exec_allowlist` now derives its dev/read-only string lists from
     typed `Masc_exec.Exec_program.known` lists. The compatibility string lists remain
     for existing gate APIs, but executable vocabulary is owned by `Exec_program`
     instead of a parallel raw string table.
   - `Masc_exec.Exec_program` now knows every executable admitted by the dev/read-only
     keeper allowlists, and the generated Shell IR typed walker fallback was
     updated so adding known executables remains exhaustively checked by the compiler.
   - `test_keeper_bash_safety` now verifies that both keeper executable
     allowlists are derived from `Exec_program.name_of_known` and that every allowlisted
     executable resolves to a known `Exec_program`.
   Continued in slice 12:
   - `Keeper_workspace_read_ops` now owns structured read/list/search handlers
     (`pwd`, `git_status`, `ls`, `cat`, `rg`, `git_log`, `find`, `head`,
     `tail`, `wc`, and `tree`) plus their sandbox read-runner and host Shell IR
     fallbacks.
   - `keeper_workspace_ops.ml` is now the public dispatcher/facade: it normalizes
     aliases, delegates read operations to `Keeper_workspace_read_ops`, and keeps
     the remaining `git_diff` branch.
   - Source-level guards now require the read runner/path/Shell IR assertions
     to live on `keeper_workspace_read_ops.ml` and reject `Keeper_sandbox_read_runner`
     from returning to `keeper_workspace_ops.ml`.
   - `Keeper_shell_ir` now also owns Shell IR construction for typed Bash
     input lowerers through `simple_bin` and `pipeline`, so
     `keeper_tool_bash_input.ml` no longer hand-builds `Shell_ir.Lit`,
     `Shell_ir.Simple`, `Shell_ir.Pipeline`, or cwd path scopes.
   - `test_keeper_sandbox_boundary_policy` now fails if typed Bash input
     lowering bypasses the keeper Shell IR facade.
   Continued in slice 13:
   - `keeper_hooks_oas_pr_metrics.ml` now asks
     `Keeper_shell_command_semantics.effective_stages_of_cmd` for git action
     detection instead of parsing command strings into Shell IR locally.
   - `test_keeper_sandbox_boundary_policy` now fails if PR action metrics
     reintroduce direct `Exec_policy.parse_string_to_ir`,
     `Exec_policy_mutation_classifier.literal_words_of_simple`, or raw
     `Shell_ir` matching for that command-shape read.
   Continued in slice 14:
   - `Keeper_shell_command_words` now owns lowercased guard-token
     extraction from raw shell commands, including quoted-word preservation and
     top-level separator markers.
   - `keeper_sandbox_docker_nested_runtime.ml` keeps Docker/container-runtime
     detection policy, but no longer parses Shell IR or reads quoted words
     directly from `Exec_policy_mutation_classifier`.
   - `test_keeper_sandbox_boundary_policy` now fails if nested-runtime
     detection reintroduces direct shell parsing or mutation-classifier access
     instead of using the shared command semantics module.
   Continued in slice 15:
   - `Keeper_shell_command_words.first_token_of_cmd` now owns first-command
     token extraction from raw shell commands.
   - `Keeper_shell_command_words.cmd_prefix` also owns the history/logging
     command-prefix helper; `Keeper_shell_command_semantics` is now limited to
     stage/cwd policy instead of word extraction.
   - `keeper_approval_queue.ml` uses that helper for approval action keys
     instead of parsing Shell IR and reading flattened mutation-classifier words
     locally.
   - `test_keeper_sandbox_boundary_policy` now fails if the approval queue
     reintroduces direct command parsing or mutation-classifier access for this
     action-key derivation.
   Continued in slice 16:
   - `Keeper_shell_command_parse.parse_cmd_to_ir_opt` now owns the
     dependency-light fallible raw command -> Shell IR helper used by Docker
     shell dispatch and GH command parsing.
   - `keeper_sandbox_docker.ml` no longer calls
     `Exec_policy.parse_string_to_ir` directly for sandbox-root cwd detection or
     host-side validation-command parsing.
   - `keeper_shell_command_parse.ml` now uses the same parser owner before applying
     GH-specific command-shape checks.
   - `test_keeper_sandbox_boundary_policy` now fails if Docker shell dispatch
     or GH command parsing reintroduces direct `Exec_policy.parse_string_to_ir`.
   Continued in slice 17:
   - `test_keeper_sandbox_boundary_policy` now pins keeper-wide raw parser
     ownership: under `lib/keeper`, only `Keeper_shell_command_parse` and the
     `Keeper_shell_ir.coding_command_context` facade may call
     `Exec_policy.parse_string_to_ir`.
   - The same boundary test now pins keeper-wide command-word ownership: under
     `lib/keeper`, only `Keeper_shell_command_words` may call
     `Exec_policy_mutation_classifier`.
   Continued in slice 18:
   - `Shell_command_repo_context` now owns GitHub repo slug validation and host-side
     origin discovery, including the `git remote get-url origin` fallback.
   - `Keeper_shell_command_parse` is now limited to GH command parsing, repo-flag argv
     helpers, and Shell IR/risk adaptation; it no longer shells out through
     `Exec_gate`.
   - PR list/status and PR review tools now infer default repositories through
     `Shell_command_repo_context` before passing argv to `Shell_ir_dispatch`.
   - `test_keeper_sandbox_boundary_policy` now fails if repo slug discovery
     returns to `Keeper_shell_command_parse` or concrete GH tools infer repo slug through
     the parser module.
   Continued in slice 19:
   - `Keeper_shell_path` now owns keeper shell cwd/path resolution,
     autocorrect, playground containment helpers, and PATH executable probes.
   - `Keeper_shell_shared` keeps compatibility exports for older callers, but
     delegates those helpers to `Keeper_shell_path` instead of carrying a second
     implementation.
   - The unused `Keeper_shell_shared.run_argv_with_status_retry_eintr` host
     process runner was removed so direct Shell argv execution cannot return to
     the shared helper module.
   - Structured shell ops and PR/GitHub tools now call `Keeper_shell_path`
     directly for cwd/path resolution.
   - `test_keeper_sandbox_boundary_policy` now fails if path/probe ownership
     moves back into `Keeper_shell_shared` or production callers route through
     the shared facade.
   Continued in slice 20:
   - `Keeper_shell_op` now owns structured `keeper_shell` operation vocabulary
     and valid op strings.
   - `Keeper_shell_timeout` now owns shell timeout constants, timeout clamping,
     and typed Shell IR timeout floors.
   - `Keeper_shell_runtime_paths` now owns runtime path rewrites between
     container-visible and host-visible paths.
   - `Keeper_shell_shared` delegates op, timeout, runtime path, and shell path
     exports to dedicated owner modules; production shell modules no longer
     depend on `Keeper_shell_shared`.
   - `test_keeper_sandbox_boundary_policy` now fails if production shell code
     starts using `Keeper_shell_shared` as an implementation owner again.
   Continued in slice 21:
   - `Keeper_shell_readonly_policy` now owns readonly shell rejection
     categories, Good/Bad hints, and structured recovery diagnoses.
   - `Keeper_exec_shell` now re-exports its public helper surface directly from
     dedicated owner modules instead of including `Keeper_shell_shared`.
   - `Keeper_shell_shared` was deleted outright. The boundary test now asserts
     that both source files stay absent.
   Continued in slice 22:
   - `Tool_resource_axis` now owns tool-call resource classification across
     public aliases, public MCP names, and internal handler names.
   - `Tool_resource_gate` enforces semaphores only; it no longer owns alias
     normalization, typed Bash executable classification, or structured
     `keeper_shell` op classification.
   - Public aliases such as `Bash`, `Grep`, `Read`, `Write`, and `WebSearch`
     normalize through `Keeper_tool_alias.canonical_resolution` before lane
     selection, so lanes are not modeled as separate Keeper Bash / Keeper
     Docker / Keeper GH surfaces.
   Continued in slice 23:
   - `Tool_resource_axis` no longer assigns Docker, web, or filesystem lanes
     through substring matches on unknown tool names.
   - Non-catalog resource-gated callers are explicit (`shell_exec` and the
     dashboard GH PR lookup). New tool names must enter `Tool_name` or this
     explicit table instead of relying on fuzzy fallback classification.
   Continued in slice 24:
   - `Keeper_tool_capability_axis` now owns semantic capability predicates
     used by actionable-signal contracts and PR-work telemetry.
   - Contract classification and PR-work metrics no longer carry separate
     Bash/Shell/GitHub string lists for public aliases, prefixed MCP names,
     and internal names.
   - PR-work telemetry normalizes public `Bash`/prefixed alias calls through
     the same capability axis before extracting command actions.
   Continued in slice 25:
   - `Keeper_agent_tool_surface` now gets work-discovery and worktree-delta
     candidate/preferred tool names from `Keeper_tool_capability_axis`.
   - Turn-affordance routing no longer maintains a separate shell/code/FS list
     for worktree inspection apart from the semantic capability axis.
   Continued in slice 26:
   - `Tool_name_alias_axis` now owns the low-dependency public alias projection
     (`Bash`, `Grep`, `Read`, `Write`, `WebFetch`, `WebSearch`) in `masc_core`.
   - `Keeper_tool_alias` builds its routing table from the shared projection,
     and `Coord_task_classify` uses the same projection for required-tool set
     comparisons without depending on keeper runtime modules.
   Continued in slice 27:
   - The Docker PR lifecycle reprobe harness now defaults split-phase
     `required_tools` to public `WebSearch`/`Bash` plus the native PR review
     mutation tool instead of internal `keeper_bash`/`keeper_shell`.
   - Generated create/review prompts now instruct keepers to use visible
     `Bash`/web surfaces and native PR review tools; audit evidence recognizes
     public `Bash` tool calls for Docker-backed PR creation.
   Continued in slice 28:
   - `Keeper_agent_tool_surface.tool_search_aliases` now resolves public
     aliases through `Keeper_tool_alias.canonical_internal_name` before reading
     the canonical alias table, so model-visible `Bash`/`Grep` search entries
     reuse the same center-axis mapping as required-tool and runtime dispatch.
   - Draft PR creation retrieval terms live on the `Bash`/`keeper_bash`
     command route, while `keeper_shell` remains a structured read/search
     route and no longer advertises PR creation discovery terms.
   Continued in slice 29:
   - Prompt/runbook GitHub workflow guidance now names public `Bash` with
     `executable="gh"` and typed `argv` for PR create/edit instead of a
     separate shell-plus-GitHub surface.
   - Dedicated PR helper tools are retired; PR reads, creation, and reversible
     CLI mutations are modeled as typed `Bash` command execution, not Keeper GH
     / Keeper Shell / Docker GH siblings.
   Continued in slice 30:
   - `Keeper_tool_capability_axis.shell_command_input_candidates` now owns
     command extraction for PR-work shell-capable tools, including public
     `Bash` typed `executable`/`argv`, legacy `keeper_bash` `cmd` telemetry
     fallback, and the retired code-shell `command` field.
   - `Keeper_hooks_oas_output_json` no longer maps shell-capable tool names
     to local command-field strings; PR-work metrics consume command
     candidates from the semantic capability axis.
   Continued in slice 31:
   - `Masc_exec.Exec_program` owned the retired code-shell executable extras
     during the migration, and the later legacy code-tool purge removed that
     compatibility surface instead of preserving a parallel allowlist.
   Continued in slice 32:
   - `Keeper_shell_ir.dispatch_classified` now exposes the command-gate policy
     knobs that used to be hardcoded for keeper Bash: caller attribution, pipe
     allowance, redirect allowance, and optional keeper/base path scope.
   - `Keeper_shell_ir.coding_command_context` now owns legacy raw coding
     command parse/validation before dispatch, so the retired code-shell no longer
     calls the coding command-context gate directly from
     `retired_file_write_shell_validate`.
   - The retired code-shell now routes parsed Shell IR through
     `Keeper_shell_ir.dispatch_classified` with `caller=Retired_file_write_tool`,
     `allow_pipes=true`, and `redirect_allowed=false`, preserving the legacy
     no-redirect code-shell policy while sharing the same gate/path/dispatch
     center as keeper Bash.
   - `retired_file_write_tool.ml` no longer calls
     `Exec_policy.validate_shell_ir_paths` or
     `Masc_exec.Exec_dispatch.dispatch_decided` directly; it keeps only
     code-shell response rendering and `rg`/`grep`/`diff` exit semantics.
   Continued in slice 33:
   - `Masc_exec.Exec_program` now has one exhaustive `known_metadata` owner for
     executable name, risk, and kind.
   - `Exec_program.known_of_string` is derived from `all_known` plus that metadata
     owner, removing the parallel string-to-constructor match table.
   - `test_exec_types` round-trips every `Exec_program.all_known` entry and checks
     name uniqueness, reverse lookup, risk, and kind coherence.

## Verification

- `test_keeper_sandbox_boundary_policy` protects source-level ownership.
- `test_keeper_sandbox_docker_route` protects existing Docker route
  behavior while names and ownership move.
- `test_keeper_sandbox_runner` uses a mock backend to verify the facade
  delegates user-shell and trusted-tool commands without invoking Docker.
- The boundary test now fails if PR/GitHub tool modules select the
  concrete Docker backend directly.
- The boundary test now fails if `keeper_workspace_ops.ml` reabsorbs
  `op=gh` or `op=git_clone` command semantics, or if active gate
  scripts name retired `keeper_shell_docker` files.
- The boundary test now fails if structured shell read ops call
  `Keeper_sandbox_read_backend` directly instead of `Keeper_sandbox_read_runner`;
  the read-runner owner is `keeper_workspace_read_ops.ml`, not the public dispatcher.
- The boundary test now fails if file tools call `Keeper_sandbox_read_backend`
  directly or hard-code Docker route labels instead of asking the
  sandbox runner facades.
- `test_keeper_sandbox_read_runner` verifies facade delegation with a
  mock backend and route labels sourced from `Keeper_sandbox_runner`.
- `test_keeper_sandbox_read_backend` protects the concrete backend behavior
  without leaking the retired `Keeper_docker_read` public module name.
- The boundary test now fails if concrete sandbox backend modules execute
  host processes as `Keeper_shell` instead of a backend-owned actor such as
  `System_sandbox`.
- The boundary test now fails if structured shell host IR paths or typed bash
  dispatch bypass the `Keeper_shell_ir` facade and re-own the gate/path/dispatch
  chain.
- The boundary test now fails if `keeper_shell_command_parse.ml` reintroduces raw GH
  `Shell_ir` construction or direct `Shell_ir_risk.classify` instead of using
  the `Keeper_shell_ir` facade.
- The boundary test now fails if Docker shell dispatch path validation bypasses
  `Keeper_shell_ir.validate_paths`.
- The boundary test now fails if concrete GH tool modules bypass
  `Shell_ir_dispatch` and call `Keeper_sandbox_runner.run_command_with_status`
  directly.
- The boundary test now fails if `keeper_workspace_ops.ml` or
  `keeper_workspace_read_ops.ml` reintroduces direct
  `Keeper_shell_shared.run_argv_with_status_retry_eintr` execution instead of
  routing host structured ops through `Keeper_shell_ir`.
- `test_keeper_bash_safety` now fails if `Dev_exec_allowlist.dev` or
  `Dev_exec_allowlist.readonly` drifts away from the typed `Exec_program` vocabulary.
- The boundary test now fails if `Masc_exec.Exec_program` reintroduces separate
  `risk_of_known`/`kind_of_known` pattern-match owners or a parallel
  string reverse-lookup table instead of the `known_metadata` axis.
- The boundary test now fails if `keeper_tool_bash_input.ml` reintroduces raw
  `Shell_ir` node construction instead of lowering via `Keeper_shell_ir`.
- The boundary test now fails if PR work-action metrics bypass
  `Keeper_shell_command_semantics` and locally re-own Shell IR parsing/matching.
- The boundary test now fails if nested-runtime detection bypasses
  `Keeper_shell_command_words.guard_tokens_of_cmd` and locally re-owns
  raw command parsing/quoted-word tokenization.
- The boundary test now fails if approval action-key derivation bypasses
  `Keeper_shell_command_words.first_token_of_cmd` and locally re-owns
  Shell IR parsing/flattening.
- The boundary test now fails if Docker shell dispatch bypasses
  `Keeper_shell_command_parse.parse_cmd_to_ir_opt` and locally re-owns raw
  command parsing.
- The boundary test now fails if any other `lib/keeper` module calls
  `Exec_policy.parse_string_to_ir` or `Exec_policy_mutation_classifier`
  directly instead of going through the parse/word owners.
- The boundary test now fails if `Keeper_shell_command_parse` shells out through
  `Exec_gate` or re-exports repo slug discovery instead of leaving that to
  `Shell_command_repo_context`.
- The boundary test now fails if `Keeper_shell_shared` source files return or
  if production shell modules bypass the dedicated op, timeout, runtime-path,
  readonly-policy, or path owner modules.
- The boundary test now fails if `Tool_resource_gate` reabsorbs tool-name,
  alias, executable, or structured shell-op classification instead of using
  `Tool_resource_axis`.
- The boundary test now fails if `Tool_resource_axis` hand-rolls alias routing
  through `Keeper_tool_alias.route` or `public_masc_to_internal` instead of
  consuming the alias SSOT resolver.
- The boundary test now fails if `Tool_resource_axis` reintroduces substring
  lane classification for unknown tool names.
- The boundary test now fails if actionable-signal contracts or PR-work
  metrics reintroduce local Bash/Shell/GitHub capability lists instead of using
  `Keeper_tool_capability_axis`.
- The boundary test now fails if work-discovery or worktree-delta turn
  affordances reintroduce local shell/code/FS capability lists instead of using
  `Keeper_tool_capability_axis`.
- The boundary test now fails if coord or keeper alias routing reintroduces
  local public-alias maps instead of using `Tool_name_alias_axis`.
- `test_ci_hardening_source` now fails if the Docker PR lifecycle harness
  reintroduces internal `keeper_bash`/`keeper_shell` required-tool defaults.
- `test_keeper_topk_llm` now fails if draft PR creation discovery drifts back
  to `keeper_shell` or if public aliases stop reusing their canonical internal
  search aliases.
- Prompt and Docker PR lifecycle source tests now fail if GitHub PR creation
  guidance reintroduces the vague shell-plus-GitHub surface
  instead of public `Bash executable="gh"` typed argv.
- `test_keeper_hooks_oas_telemetry` now verifies typed public `Bash`
  `executable="gh"`/`argv=["pr","create",...]` emits `PR_CREATE`, and
  prefixed public `Bash` typed git push normalizes to `keeper_bash`.
- The boundary test now fails if OAS output command extraction reintroduces a
  local `keeper_bash`/retired-code-shell field map instead of using
  `Keeper_tool_capability_axis.shell_command_input_candidates`.
- `test_keeper_bash_safety` now verifies the remaining dev/read-only
  allowlists are derived from typed `Exec_program` values without the removed
  legacy code-shell allowlist surface.
- `test_worker_dev_tools` now fails if the retired code-shell bypasses
  `Keeper_shell_ir.coding_command_context` /
  `Keeper_shell_ir.dispatch_classified`, re-enables redirects at the facade,
  or reintroduces direct path-validation / dispatch ownership in
  `retired_file_write_tool.ml`.
