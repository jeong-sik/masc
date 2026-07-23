# Keeper Execute Quality Leaks

Runtime baseline: `/Users/dancer/me/.masc/tool_calls`, 240h window ending
`2026-05-19T09:47:28+0900`.

Baseline command:

```bash
scripts/analyze-keeper-execute-failures.sh /Users/dancer/me 240
```

Baseline result:

| Metric | Count |
|---|---:|
| Execute calls | 21,917 |
| Failed or semantic-failed Execute calls | 8,902 |
| Failure rate | 40.62% |

Release target: after the improvement PR is merged and keepers have generated a
fresh 240h sample, the same script should report `failure_pct < 10.00`.

Adjacent tool-surface sample from the same 240h window:

| Tool | Failed | OK | Failure rate |
|---|---:|---:|---:|
| legacy code-shell surface | 1,643 | 6,340 | 20.58% |
| legacy code-edit surface | 119 | 51 | 70.00% |
| `tool_search_files` | 166 | 399 | 29.38% |
| `tool_execute` | 174 | 948 | 15.51% |
| public `Edit` | 41 | 15 | 73.21% |
| public `Write` | 103 | 8 | 92.79% |

## Leak Map

| Leak class | Baseline count | Code boundary | Current fix path |
|---|---:|---|---|
| `shape_block:pipe_or_redirect` | 2,606 | historical `tool_execute` raw command logs, `scripts/analyze-keeper-execute-failures.sh` | Retired for public `Execute`. Unsafe shell syntax no longer enters `tool_execute` as a raw string; callers must use one typed non-empty `argv` process vector or explicit typed pipeline/stage input. The historical bucket remains only for old runtime samples and adjacent shell surfaces. |
| Missing path or wrong cwd | 1,602 | `lib/keeper/keeper_sandbox_docker.ml`, typed public `Execute` | Preserve path validation, but make public `Execute` expose `cwd`, make retry hints use the typed `Execute { executable, argv, cwd }` shape, and allow the safe `/dev/null` marker instead of treating `cat /dev/null` as an out-of-whitelist path. |
| `shape_block:chaining` | 1,275 | historical `tool_execute` raw command logs | Retired for public `Execute`. `cd repos/... && ...` is not normalized into a keeper command; callers must pass typed `cwd` plus `executable`/`argv`. |
| Non-zero command exits | 846 | `lib/exec_core.ml`, `lib/keeper_tool_call_log.ml` | Treat structured `ok=true` and `semantic_status=no_match` as semantic success even when the transport-level call was marked failed. |
| Retired path-tokenizer diagnostic | 540 | `lib/keeper/keeper_path_check_error.ml`, Shell IR path checks | Retired. Path safety now validates literal Shell IR argv/redirect values for containment; quote/glob/brace/backslash syntax no longer has a separate log bucket. |
| `other` / unclassified failures | 459 | `lib/keeper_tool_call_log.ml`, `lib/dashboard/dashboard_http_tool_quality.ml` | Promote structured `semantic_status`, `shape_block`, and diagnosis fields into stable failure categories. |
| `shape_block:unknown` | 352 | historical `tool_execute` raw command logs, `scripts/analyze-keeper-execute-failures.sh` | Historical only for public `Execute`; new calls fail typed input validation before raw shape parsing. Keep the bucket for old samples and adjacent shell surfaces that still report parser-unknown shape blocks. |
| Multi-repo cwd required | 286 | historical Execute samples | Retired as a MASC policy class. Execute never infers repository or product semantics; the invoked CLI reports its own cwd/syntax error and the Keeper may retry with a corrected typed cwd. |
| Timeout | 271 | `lib/exec_core.ml`, Docker shell runtime | Classify as `semantic_status:timeout` for the quality loop; command scoping remains the caller-side correction. |
| Repeat/streak gates | 203 | OAS retry cache, keeper tool diversity gates | Measure separately as `repeat_or_streak_gate` so retries are not mistaken for new Execute defects. |
| Wrong tool channel | 164 | historical Execute samples | Retired for typed Execute. Descriptor routing validates Tool identity, while Execute treats the complete argv process vector as opaque input and leaves program availability to the actual execution result. |
| Command not allowed by validator | 110 | historical Execute samples | Retired. Structural typed-input validation remains, but MASC has no executable-name allowlist. |
| Docker image missing | 108 | Docker sandbox runtime | Measure separately from command-shape failures; this is an infrastructure/runtime availability class. |
| Command usage or regex errors | 59 | command-specific handlers | Keep as caller-command defects rather than path or sandbox defects. |
| Approval / PR policy bypass | 20 | historical product-specific policy | Retired. The neutral external-effect Gate receives exact opaque operation/input and owns Always Allowed, Auto Judge, and nonblocking HITL without product semantics. |

## Adjacent Surface Fixes

The retired code-shell surface had a separate allowlist from `tool_execute`, so safe inspection
commands could fail even when the same read shape was accepted elsewhere. The
top observed adjacent class was `command_not_allowed`; code shell now reuses the
`Dev_exec_allowlist.dev` SSOT plus its tool-specific extras, so commands such as
`sed -n ...`, `pwd`, `echo`, `python3`, `ruff`, and `pyright` no longer drift
from keeper dev-shell policy. The tool schema now describes that SSOT and the
validator still blocks chaining, command substitution, and unsafe redirects.

The removed review-wrapper handlers also shared the retired path-tokenizer leak
indirectly: those paths inlined review prose into a shell command, so markdown,
globs, quotes, or code snippets could be classified by the wrong layer before
`gh` ran.

The retired code-edit surface, public `Edit`, and public `Write` showed a separate writable
path leak: `repos/<repo>/...` already mapped to the keeper's own playground, but
repo-top paths such as `lib/foo.ml` were interpreted against the root checkout
and then blocked as outside the writable sandbox. When exactly one repo exists
under the keeper's own `repos/`, top-relative source paths now resolve inside
that repo; multi-repo playgrounds still require an explicit `repos/<repo>/...`
path.

## Verification

Focused tests:

```bash
scripts/dune-local.sh build test/test_tool_execute_safety.exe
scripts/dune-local.sh build test/test_tool_input_validation.exe
scripts/dune-local.sh build test/test_agent_tool_execute_typed_input.exe
scripts/dune-local.sh build test/test_keeper_sandbox_docker_route.exe
scripts/dune-local.sh build test/test_keeper_tool_alias.exe
```

Runtime remeasure:

```bash
scripts/analyze-keeper-execute-failures.sh /Users/dancer/me 240
```

The same command now emits both the Execute-specific census and a
`[surface summary]`/`[surface failure categories]` section for
`tool_execute`, `tool_search_files`, the retired code-shell/code-edit surfaces, and public
`Edit`/`Write`, plus the PR review read/comment/reply surfaces that showed the
same path-syntax leak. This lets the `<10%` target be checked across the related
shell, code-edit, and review surfaces after the PR is merged and a fresh runtime
window exists.
