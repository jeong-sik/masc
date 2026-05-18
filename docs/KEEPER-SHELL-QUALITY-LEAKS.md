# Keeper Shell Quality Leaks

Runtime baseline: `/Users/dancer/me/.masc/tool_calls`, 240h window ending
`2026-05-19T03:11:58+0900`.

Baseline command:

```bash
scripts/analyze-keeper-bash-failures.sh /Users/dancer/me 240
```

Baseline result:

| Metric | Count |
|---|---:|
| Bash calls | 21,079 |
| Failed or semantic-failed Bash calls | 8,573 |
| Failure rate | 40.67% |

Release target: after the improvement PR is merged and keepers have generated a
fresh 240h sample, the same script should report `failure_pct < 10.00`.

Adjacent tool-surface sample from the same 240h window:

| Tool | Failed | OK | Failure rate |
|---|---:|---:|---:|
| `masc_code_shell` | 1,621 | 6,087 | 21.03% |
| `masc_code_edit` | 115 | 51 | 69.28% |
| `keeper_shell` | 186 | 509 | 26.76% |
| `keeper_bash` | 198 | 1,111 | 15.13% |
| public `Edit` | 38 | 13 | 74.51% |
| public `Write` | 94 | 6 | 94.00% |

## Leak Map

| Leak class | Baseline count | Code boundary | Current fix path |
|---|---:|---|---|
| `shape_block:pipe_or_redirect` | 2,367 | `lib/keeper/keeper_shell_bash.ml`, `scripts/analyze-keeper-bash-failures.sh` | Infer shape from the command, not from hint text. Keep unsafe pipelines blocked, but allow safe read-only `|| echo`, stderr-dev-null, and `read-only primary | head -N` fallbacks through deterministic validation of the primary command. |
| Missing path or wrong cwd | 1,585 | `lib/worker_dev_tools.ml`, `lib/keeper/keeper_shell_docker.ml` | Preserve path validation, but make public `Bash` expose `cwd`, make retry hints use the public `Bash { command, cwd }` shape, and allow the safe `/dev/null` sentinel instead of treating `cat /dev/null` as an out-of-whitelist path. |
| `shape_block:chaining` | 1,262 | `lib/keeper/keeper_shell_bash.ml` | Normalize safe read-only fallbacks. `cd repos/... && <read-only>` is treated like a cwd-scoped read instead of a hard shape failure. |
| Non-zero command exits | 836 | `lib/exec_core.ml`, `lib/keeper_tool_call_log.ml` | Treat structured `ok=true` and `semantic_status=no_match` as semantic success even when the transport-level call was marked failed. |
| Path syntax blocked | 537 | `lib/worker_dev_tools.ml`, `lib/keeper/keeper_path_check_error.ml` | Keep the safety gate; measure it distinctly instead of collapsing it into generic structured errors. |
| `other` / unclassified failures | 432 | `lib/keeper_tool_call_log.ml`, `lib/dashboard/dashboard_http_tool_quality.ml` | Promote structured `semantic_status`, `shape_block`, and diagnosis fields into stable failure categories. |
| `shape_block:unknown` | 352 | `scripts/analyze-keeper-bash-failures.sh` | Leave true parser-unknown shape blocks separate from command-inferable pipe/chaining failures. |
| Multi-repo cwd required | 282 | `lib/keeper/keeper_shell_docker.ml`, `lib/keeper/keeper_tool_alias.ml` | Parse command tokens with the Bash parser and return a public `Bash` retry shape including `cwd`. |
| Timeout | 271 | `lib/exec_core.ml`, Docker shell runtime | Classify as `semantic_status:timeout` for the quality loop; command scoping remains the caller-side correction. |
| Repeat/streak gates | 203 | OAS retry cache, keeper tool diversity gates | Measure separately as `repeat_or_streak_gate` so retries are not mistaken for new Bash defects. |
| Wrong tool channel | 148 | `lib/keeper/keeper_shell_bash.ml`, `scripts/analyze-keeper-bash-failures.sh` | Preserve the pre-exec block, expose it as `wrong_tool_channel`, and classify public `gh`/MASC-tool attempts before generic allowlist failures. |
| Command not allowed by validator | 110 | `lib/keeper/keeper_shell_bash.ml`, `lib/tool_code_write.ml` | Keep the explicit validator block, but measure it separately from path syntax, wrong-tool, and shell shape classes. |
| Docker image missing | 108 | Docker sandbox runtime | Measure separately from command-shape failures; this is an infrastructure/runtime availability class. |
| Command usage or regex errors | 59 | command-specific handlers | Keep as caller-command defects rather than path or sandbox defects. |
| Approval / PR policy bypass | 29 | `lib/keeper/keeper_shell_bash.ml` | Preserve the pre-exec policy block; classify separately from runtime shell failures. |

## Adjacent Surface Fixes

`masc_code_shell` had a separate allowlist from `keeper_bash`, so safe inspection
commands could fail even when the same read shape was accepted elsewhere. The
top observed class was `command_not_allowed`; safe inspection commands such as
`sed -n ...` and `pwd` are now in the code-shell allowlist, and the tool schema
now matches the validator: allowlisted pipelines are supported, but shell
chaining remains blocked.

## Verification

Focused tests:

```bash
scripts/dune-local.sh build test/test_keeper_bash_safety.exe
scripts/dune-local.sh build test/test_keeper_tool_call_log.exe
```

Runtime remeasure:

```bash
scripts/analyze-keeper-bash-failures.sh /Users/dancer/me 240
```

The same command now emits both the Bash-specific census and a
`[surface summary]`/`[surface failure categories]` section for
`keeper_bash`, `keeper_shell`, `masc_code_shell`, `masc_code_edit`, and public
`Edit`/`Write`, so the `<10%` target can be checked across the related shell
and code-edit surfaces after the PR is merged and a fresh runtime window exists.
