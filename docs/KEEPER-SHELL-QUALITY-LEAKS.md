# Keeper Shell Quality Leaks

Runtime baseline: `/Users/dancer/me/.masc/tool_calls`, `2026-05-09T01:31:26+0900`
through `2026-05-19T01:31:26+0900`.

Baseline command:

```bash
scripts/analyze-keeper-bash-failures.sh /Users/dancer/me 240
```

Baseline result:

| Metric | Count |
|---|---:|
| Bash calls | 19,802 |
| Failed or semantic-failed Bash calls | 8,376 |
| Failure rate | 42.30% |

Release target: after the improvement PR is merged and keepers have generated a
fresh 240h sample, the same script should report `failure_pct < 10.00`.

## Leak Map

| Leak class | Baseline count | Code boundary | Current fix path |
|---|---:|---|---|
| `shape_block:unknown` / chaining | 3,224 | `lib/keeper/keeper_shell_bash.ml` | Normalize safe read-only fallbacks. `cd repos/... && <read-only>` is treated like a cwd-scoped read instead of a hard shape failure. |
| Missing path or wrong cwd | 1,548 | `lib/worker_dev_tools.ml`, `lib/keeper/keeper_shell_docker.ml` | Preserve path validation, but make public `Bash` expose `cwd`, make retry hints use the public `Bash { command, cwd }` shape, and allow the safe `/dev/null` sentinel instead of treating `cat /dev/null` as an out-of-whitelist path. |
| Non-zero command exits | 831 | `lib/exec_core.ml`, `lib/keeper_tool_call_log.ml` | Treat structured `ok=true` and `semantic_status=no_match` as semantic success even when the transport-level call was marked failed. |
| `shape_block:pipe_or_redirect` | 681 | `lib/keeper/keeper_shell_bash.ml` | Keep unsafe pipelines blocked, but split safe read-only `|| echo` and stderr-dev-null fallbacks into deterministic primary commands. |
| `other` / unclassified failures | 543 | `lib/keeper_tool_call_log.ml`, `lib/dashboard/dashboard_http_tool_quality.ml` | Promote structured `semantic_status`, `shape_block`, and diagnosis fields into stable failure categories. |
| Path syntax blocked | 537 | `lib/worker_dev_tools.ml`, `lib/keeper/keeper_path_check_error.ml` | Keep the safety gate; measure it distinctly instead of collapsing it into generic structured errors. |
| Multi-repo cwd required | 282 | `lib/keeper/keeper_shell_docker.ml`, `lib/keeper/keeper_tool_alias.ml` | Parse command tokens with the Bash parser and return a public `Bash` retry shape including `cwd`. |
| Timeout | 275 | `lib/exec_core.ml`, Docker shell runtime | Classify as `semantic_status:timeout` for the quality loop; command scoping remains the caller-side correction. |
| Repeat/streak gates | 202 | OAS retry cache, keeper tool diversity gates | Measure separately as `repeat_or_streak_gate` so retries are not mistaken for new Bash defects. |
| Docker image missing | 108 | Docker sandbox runtime | Measure separately from command-shape failures; this is an infrastructure/runtime availability class. |
| Wrong tool channel | 59 | `lib/keeper/keeper_shell_bash.ml` | Preserve the pre-exec block, expose it as `wrong_tool_channel`, and keep the tool suggestion visible. |
| Command usage or regex errors | 58 | command-specific handlers | Keep as caller-command defects rather than path or sandbox defects. |
| Approval / PR policy bypass | 29 | `lib/keeper/keeper_shell_bash.ml` | Preserve the pre-exec policy block; classify separately from runtime shell failures. |

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
