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
| `masc_code_shell` | 1,643 | 6,340 | 20.58% |
| `masc_code_edit` | 119 | 51 | 70.00% |
| `tool_search_files` | 166 | 399 | 29.38% |
| `tool_execute` | 174 | 948 | 15.51% |
| public `EditFile` | 41 | 15 | 73.21% |
| public `WriteFile` | 103 | 8 | 92.79% |

## Leak Map

| Leak class | Baseline count | Code boundary | Current fix path |
|---|---:|---|---|
| `shape_block:pipe_or_redirect` | 2,606 | historical `tool_execute` raw command logs, `scripts/analyze-keeper-execute-failures.sh` | Retired for public `Execute`. Unsafe shell syntax no longer enters `tool_execute` as a raw string; callers must use typed `executable`/`argv` or explicit typed pipeline/stage input. The historical bucket remains only for old runtime samples and adjacent shell surfaces. |
| Missing path or wrong cwd | 1,602 | `lib/worker_dev_tools.ml`, `lib/keeper/keeper_sandbox_docker.ml` | Preserve path validation, but make public `Execute` expose `cwd`, make retry hints use the typed `Execute { executable, argv, cwd }` shape, and allow the safe `/dev/null` sentinel instead of treating `cat /dev/null` as an out-of-whitelist path. |
| `shape_block:chaining` | 1,275 | historical `tool_execute` raw command logs | Retired for public `Execute`. `cd repos/... && ...` is not normalized into a keeper command; callers must pass typed `cwd` plus `executable`/`argv`. |
| Non-zero command exits | 846 | `lib/exec_core.ml`, `lib/keeper_tool_call_log.ml` | Treat structured `ok=true` and `semantic_status=no_match` as semantic success even when the transport-level call was marked failed. |
| Retired path-tokenizer diagnostic | 540 | `lib/worker_dev_tools.ml`, `lib/keeper/keeper_path_check_error.ml` | Retired. Path safety now validates literal Shell IR argv/redirect values for containment; quote/glob/brace/backslash syntax no longer has a separate log bucket. |
| `other` / unclassified failures | 459 | `lib/keeper_tool_call_log.ml`, `lib/dashboard/dashboard_http_tool_quality.ml` | Promote structured `semantic_status`, `shape_block`, and diagnosis fields into stable failure categories. |
| `shape_block:unknown` | 352 | historical `tool_execute` raw command logs, `scripts/analyze-keeper-execute-failures.sh` | Historical only for public `Execute`; new calls fail typed input validation before raw shape parsing. Keep the bucket for old samples and adjacent shell surfaces that still report parser-unknown shape blocks. |
| Multi-repo cwd required | 286 | `lib/keeper/keeper_sandbox_docker.ml`, `lib/keeper/keeper_tool_alias.ml` | Return a typed public `Execute { executable, argv, cwd }` retry shape when sandbox-root git/gh cannot be resolved. Do not infer repository scope from `cd ... &&` command text. |
| Timeout | 271 | `lib/exec_core.ml`, Docker shell runtime | Classify as `semantic_status:timeout` for the quality loop; command scoping remains the caller-side correction. |
| Repeat/streak gates | 203 | OAS retry cache, keeper tool diversity gates | Measure separately as `repeat_or_streak_gate` so retries are not mistaken for new Execute defects. |
| Wrong tool channel | 164 | typed `tool_execute` allowlist, dedicated PR/MASC tools, `scripts/analyze-keeper-execute-failures.sh` | Preserve pre-exec rejection, but do it through typed command allowlists and dedicated tool routing. Public `gh` PR/status mutations belong to PR tools, not a raw shell string channel. |
| Command not allowed by validator | 110 | `lib/keeper/keeper_shell_bash.ml`, `lib/tool_code_write.ml` | Keep the explicit validator block, but measure it separately from path syntax, wrong-tool, and shell shape classes. |
| Docker image missing | 108 | Docker sandbox runtime | Measure separately from command-shape failures; this is an infrastructure/runtime availability class. |
| Command usage or regex errors | 59 | command-specific handlers | Keep as caller-command defects rather than path or sandbox defects. |
| Approval / PR policy bypass | 20 | typed `tool_execute` allowlist and dedicated PR tools | Preserve pre-exec policy rejection and classify it separately from runtime shell failures. Approval/PR operations should enter through dedicated structured tools. |

## Adjacent Surface Fixes

`masc_code_shell` had a separate allowlist from `tool_execute`, so safe inspection
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

`masc_code_edit`, public `EditFile`, and public `WriteFile` showed a separate writable
path leak: `repos/<repo>/...` already mapped to the keeper's own playground, but
repo-top paths such as `lib/foo.ml` were interpreted against the root checkout
and then blocked as outside the writable sandbox. When exactly one repo exists
under the keeper's own `repos/`, top-relative source paths now resolve inside
that repo; multi-repo playgrounds still require an explicit `repos/<repo>/...`
path.

## Verification

Focused tests:

```bash
scripts/dune-local.sh build test/test_keeper_bash_safety.exe
scripts/dune-local.sh build test/test_tool_input_validation.exe
scripts/dune-local.sh build test/test_keeper_bash_typed_input.exe
scripts/dune-local.sh build test/test_keeper_sandbox_docker_route.exe
scripts/dune-local.sh build test/test_keeper_tool_alias.exe
```

Runtime remeasure:

```bash
scripts/analyze-keeper-execute-failures.sh /Users/dancer/me 240
```

The same command now emits both the Execute-specific census and a
`[surface summary]`/`[surface failure categories]` section for
`tool_execute`, `tool_search_files`, `masc_code_shell`, `masc_code_edit`, and public
`EditFile`/`WriteFile`, plus the PR review read/comment/reply surfaces that showed the
same path-syntax leak. This lets the `<10%` target be checked across the related
shell, code-edit, and review surfaces after the PR is merged and a fresh runtime
window exists.
