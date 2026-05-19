# Keeper Shell Quality Leaks

Runtime baseline: `/Users/dancer/me/.masc/tool_calls`, 240h window ending
`2026-05-19T09:47:28+0900`.

Baseline command:

```bash
scripts/analyze-keeper-bash-failures.sh /Users/dancer/me 240
```

Baseline result:

| Metric | Count |
|---|---:|
| Bash calls | 21,917 |
| Failed or semantic-failed Bash calls | 8,902 |
| Failure rate | 40.62% |

Release target: after the improvement PR is merged and keepers have generated a
fresh 240h sample, the same script should report `failure_pct < 10.00`.

Adjacent tool-surface sample from the same 240h window:

| Tool | Failed | OK | Failure rate |
|---|---:|---:|---:|
| `masc_code_shell` | 1,643 | 6,340 | 20.58% |
| `masc_code_edit` | 119 | 51 | 70.00% |
| `keeper_shell` | 166 | 399 | 29.38% |
| `keeper_bash` | 174 | 948 | 15.51% |
| `keeper_pr_review_read` | 17 | 23 | 42.50% |
| `keeper_pr_review_comment` | 58 | 50 | 53.70% |
| public `Edit` | 41 | 15 | 73.21% |
| public `Write` | 103 | 8 | 92.79% |

## Leak Map

| Leak class | Baseline count | Code boundary | Current fix path |
|---|---:|---|---|
| `shape_block:pipe_or_redirect` | 2,606 | `lib/keeper/keeper_shell_bash.ml`, `scripts/analyze-keeper-bash-failures.sh` | Infer shape from the command, not from hint text. Keep unsafe pipelines blocked, but allow safe read-only `|| echo`, stderr-dev-null, and `read-only primary | head -N` fallbacks through deterministic validation of the primary command. |
| Missing path or wrong cwd | 1,602 | `lib/worker_dev_tools.ml`, `lib/keeper/keeper_shell_docker.ml` | Preserve path validation, but make public `Bash` expose `cwd`, make retry hints use the public `Bash { command, cwd }` shape, and allow the safe `/dev/null` sentinel instead of treating `cat /dev/null` as an out-of-whitelist path. |
| `shape_block:chaining` | 1,275 | `lib/keeper/keeper_shell_bash.ml` | Normalize safe read-only fallbacks. `cd repos/... && <read-only>` is treated like a cwd-scoped read instead of a hard shape failure. |
| Non-zero command exits | 846 | `lib/exec_core.ml`, `lib/keeper_tool_call_log.ml` | Treat structured `ok=true` and `semantic_status=no_match` as semantic success even when the transport-level call was marked failed. |
| Path syntax blocked | 540 | `lib/worker_dev_tools.ml`, `lib/keeper/keeper_path_check_error.ml`, `lib/keeper/keeper_tool_pr_review.ml` | Keep the safety gate; measure it distinctly instead of collapsing it into generic structured errors. PR review mutation tools now write review bodies to temp files and pass `--body-file` / `-F body=@file`, so body prose is no longer parsed as path-bearing shell syntax. |
| `other` / unclassified failures | 459 | `lib/keeper_tool_call_log.ml`, `lib/dashboard/dashboard_http_tool_quality.ml` | Promote structured `semantic_status`, `shape_block`, and diagnosis fields into stable failure categories. |
| `shape_block:unknown` | 352 | `scripts/analyze-keeper-bash-failures.sh` | Leave true parser-unknown shape blocks separate from command-inferable pipe/chaining failures. |
| Multi-repo cwd required | 286 | `lib/keeper/keeper_shell_docker.ml`, `lib/keeper/keeper_tool_alias.ml` | Parse command tokens with the Bash parser and return a public `Bash` retry shape including `cwd`. |
| Timeout | 271 | `lib/exec_core.ml`, Docker shell runtime | Classify as `semantic_status:timeout` for the quality loop; command scoping remains the caller-side correction. |
| Repeat/streak gates | 203 | OAS retry cache, keeper tool diversity gates | Measure separately as `repeat_or_streak_gate` so retries are not mistaken for new Bash defects. |
| Wrong tool channel | 164 | `lib/keeper/keeper_shell_bash.ml`, `scripts/analyze-keeper-bash-failures.sh` | Preserve the pre-exec block, expose it as `wrong_tool_channel`, and classify public `gh`/MASC-tool attempts before generic allowlist failures. |
| Command not allowed by validator | 110 | `lib/keeper/keeper_shell_bash.ml`, `lib/tool_code_write.ml` | Keep the explicit validator block, but measure it separately from path syntax, wrong-tool, and shell shape classes. |
| Docker image missing | 108 | Docker sandbox runtime | Measure separately from command-shape failures; this is an infrastructure/runtime availability class. |
| Command usage or regex errors | 59 | command-specific handlers | Keep as caller-command defects rather than path or sandbox defects. |
| Approval / PR policy bypass | 20 | `lib/keeper/keeper_shell_bash.ml` | Preserve the pre-exec policy block; classify separately from runtime shell failures. |

## Adjacent Surface Fixes

`masc_code_shell` had a separate allowlist from `keeper_bash`, so safe inspection
commands could fail even when the same read shape was accepted elsewhere. The
top observed adjacent class was `command_not_allowed`; code shell now reuses the
`Dev_exec_allowlist.dev` SSOT plus its tool-specific extras, so commands such as
`sed -n ...`, `pwd`, `echo`, `python3`, `ruff`, and `pyright` no longer drift
from keeper dev-shell policy. The tool schema now describes that SSOT and the
validator still blocks chaining, command substitution, and unsafe redirects.

`keeper_pr_review_comment` and `keeper_pr_review_reply` also shared the path
syntax leak indirectly: the handlers inlined review prose into a shell command,
so markdown, globs, quotes, or code snippets could be classified as path syntax
before `gh` ran. Review/comment bodies now travel through temp files instead of
shell argv.

`masc_code_edit`, public `Edit`, and public `Write` showed a separate writable
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
scripts/dune-local.sh build test/test_keeper_tool_call_log.exe
scripts/dune-local.sh build test/test_keeper_pr_review.exe
scripts/dune-local.sh build test/test_tool_code_write_coverage.exe
```

Runtime remeasure:

```bash
scripts/analyze-keeper-bash-failures.sh /Users/dancer/me 240
```

The same command now emits both the Bash-specific census and a
`[surface summary]`/`[surface failure categories]` section for
`keeper_bash`, `keeper_shell`, `masc_code_shell`, `masc_code_edit`, and public
`Edit`/`Write`, plus the PR review read/comment/reply surfaces that showed the
same path-syntax leak. This lets the `<10%` target be checked across the related
shell, code-edit, and review surfaces after the PR is merged and a fresh runtime
window exists.
