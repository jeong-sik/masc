---
status: runbook
last_verified: 2026-05-06
code_refs:
  - scripts/harness_keeper_docker_pr_lifecycle_reprobe.sh
  - scripts/harness/workload/keeper_docker_pr_lifecycle_reprobe.sh
  - scripts/audit-keeper-fleet-readiness.py
---

# Keeper Docker PR Lifecycle Reprobe

This harness is the post-merge/live proof runner for the Docker PR lifecycle
audit gates. The audit script can detect missing evidence; this reprobe runner
adds the operator action loop:

1. discover Docker keepers,
2. render a per-keeper proof prompt,
3. optionally send the prompt through `masc_keeper_msg`,
4. poll `masc_keeper_msg_result`,
5. run `audit-keeper-fleet-readiness.py --require-docker-pr-lifecycle-evidence`,
6. save artifacts under `logs/keeper_docker_pr_lifecycle/<run_id>/`.

Default mode is dry-run. It writes prompts and runs the read-only audit, but it
does not ask keepers to create branches, push, create PRs, or approve reviews.
When keeper names are not supplied, discovery initializes an MCP session, reads
runtime keepers from `masc_keeper_list(detailed=true)`, and intersects them with
`$BASE_PATH/.masc/config/keepers/*.toml` entries whose `sandbox_profile` is
`docker`. `MASC_MCP_TOKEN` is used when set; otherwise the harness reads
`$BASE_PATH/.masc/auth/codex-mcp-client.token` if it exists.
MCP `initialize` is retried until `INIT_TIMEOUT_SEC` so a warm server whose
HTTP health is up but MCP startup is still completing does not fail the run.
Transient `masc_keeper_msg_result` transport/tool errors are recorded in
`poll_errors.jsonl` and kept pending until the poll deadline instead of being
treated as terminal keeper results.
For mutation runs, the harness pins the server incarnation from `/health`
using `build.commit` plus `build.started_at`. If the server restarts or is
replaced while keeper turns are pending, the pending requests are recorded as
`server_incarnation_changed` instead of accumulating misleading
`request_id not found` poll errors from a fresh in-memory request registry.
The incarnation check classifies failures into three statuses:
`server_incarnation_changed` (real restart, terminates polling),
`server_health_unavailable` (transient `/health` HTTP failure, polling
continues), and `server_health_missing_commit` (the response was reachable
but lacked `build.commit`, also treated as transient). Only the first
status records pending requests as lost; the other two log a transient
notice and the next poll iteration retries.
When mutation is enabled, the harness sends `required_tools` with each
`masc_keeper_msg` call. By default that one-turn contract requires
`keeper_shell`, `keeper_bash`, `masc_code_git`, `keeper_pr_create`, and
`keeper_pr_review_comment`, so the runtime records `tool_surface_mismatch` if
those tools are not visible and `missing_required_tool_use` if the keeper
replies without exercising them.
The prompt reserves `keeper_shell` and `keeper_bash` for read-only inspection.
Mutating git operations must go through `masc_code_git`; otherwise the shell
guard can correctly reject `git commit`/`git push` with `write_operation_gated`
and the run will not produce Docker push evidence.
Likewise, proof-file writes should use `keeper_fs_edit`, and PR create/review
mutations should use `keeper_pr_create` / `keeper_pr_review_comment` rather
than `gh pr ...` through shell tools.
Override the CSV with `REQUIRED_TOOLS=...` for a narrower or broader proof
lane.
`MSG_TIMEOUT_SEC` only bounds the harness HTTP request to the MCP server.
The keeper's actual Agent.run budget is sent separately as
`masc_keeper_msg.timeout_sec` through `KEEPER_TURN_TIMEOUT_SEC`, which defaults
to 900 seconds so Docker git/PR proof turns are not capped by the short MCP
request timeout.

```bash
./scripts/harness_keeper_docker_pr_lifecycle_reprobe.sh
```

Live mutation requires an explicit flag:

```bash
./scripts/harness_keeper_docker_pr_lifecycle_reprobe.sh \
  --mutate \
  --expected-keepers 14 \
  --repo jeong-sik/masc-mcp \
  --board-post-id p-cdf9e0d695d723222b0e2db02f6e429b
```

Useful scoped runs:

```bash
./scripts/harness_keeper_docker_pr_lifecycle_reprobe.sh \
  --mutate \
  --keeper-names sangsu \
  --expected-keepers 14

./scripts/harness_keeper_docker_pr_lifecycle_reprobe.sh \
  --mutate \
  --keeper-names sangsu,executor,verifier \
  --max-keepers 3
```

The prompt requires keepers to stay on draft proof PRs:

- no protected branches,
- no force push,
- no ready/merge,
- no `human-approved-ready` label,
- `APPROVE` only when the PR-review tool preflight permits a draft
  agent/keeper proof PR.

The final audit remains the truth source. A successful keeper reply is useful
operator evidence, but it is not completion unless the Docker lifecycle audit
also passes for the expected fleet.
