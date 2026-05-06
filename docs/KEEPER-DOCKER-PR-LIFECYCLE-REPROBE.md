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
2. render per-keeper create/review phase prompts,
3. optionally send the prompt through `masc_keeper_msg`,
4. poll `masc_keeper_msg_result`,
5. run `audit-keeper-fleet-readiness.py --require-docker-pr-lifecycle-evidence --evidence-run-id <run_id>`,
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
When mutation is enabled, the harness sends two sequential phases. The create phase
requires `keeper_bash` and `keeper_pr_create`. Before it sends any mutation
prompt, the harness checks the run-scoped proof branches and fails closed with
`branch_collision_preflight` if a local branch, remote-tracking branch, remote
head, or local worktree already exists for the selected `--run-id`. After the
create phase, the review phase only starts when every keeper produced create
success markers for the same run id: `docker_pr_create=true`,
`docker_git_push=true`, `blocker=null`, the exact branch, and a PR URL. If a
keeper returns an error or blocker, the harness writes
`create-readiness-failures.jsonl` and skips review prompts instead of approving
stale or partially-created PRs. Per-keeper branch-collision evidence detected
upfront by `assert_no_proof_branch_collisions_for_mutate` is written to
`proof-branch-collisions.jsonl` (under the run dir) — one row per keeper with
the offending branch ref(s) so operators can clean up stale local/remote
branches before re-running. An empty file means no collisions; rows look like:
```json
{"keeper":"executor","branch":"keeper-executor-agent/<run_id>",
 "local_branch":true,"remote_tracking_branch":true,
 "remote_head":false,"worktree_branch":false,
 "blocker":"branch_collision_preflight"}
```
By default, mutation preflight also requires every selected keeper account to
have upstream `WRITE`, `MAINTAIN`, or `ADMIN` permission for the target repo. For
PUBLIC repositories, `--allow-fork-pr-for-readonly` permits `READ`/`TRIAGE`
credential lanes to push their proof branch to the keeper account's fork and
open the draft PR with `head=OWNER:BRANCH`; PR creation still goes through
`keeper_pr_create`, not raw `gh pr create`.
After collision evidence is clear, the review phase requires `keeper_pr_review_comment`.
This avoids the old single-turn shape where one keeper could wait on another
keeper's missing PR until the Agent.run timeout. The review prompt reserves
`keeper_shell` for read-only GitHub inspection, but does not put it in
`required_tools` because passive read-only tools cannot satisfy the runtime
required-tool predicate. Keepers are instructed to report `target_pr_missing`
after one failed branch lookup instead of polling in a loop.
Keepers must create/use the exact run-scoped branch produced by
`masc_worktree_create task_id=<run_id>`:
`keeper-<keeper>-agent/<run_id>`. They must write the proof file
`docs/runtime-proof/keepers/<keeper>-<run_id>.md`; older proof branches or
worktrees do not count. This branch convention matches the runtime worktree
tool contract (`{agent_name}/{task_id}`) while still keeping stale evidence
out via the run id. Proof-file creation and git add/commit/push should use
`keeper_bash` from inside the Docker playground so the route evidence is tied
to the keeper container path. If the shell guard rejects the git mutation, the
keeper must stop and report that blocker instead of falling back to host-local
credentials.
PR create/review mutations should use `keeper_pr_create` /
`keeper_pr_review_comment` rather than `gh pr ...` through shell tools.
Override the phase CSVs with `CREATE_REQUIRED_TOOLS=...` and
`REVIEW_REQUIRED_TOOLS=...` when debugging a narrower or broader proof lane.
The older `REQUIRED_TOOLS=...` override is still accepted as a legacy shortcut
and is applied to both phases only when the phase-specific variables are unset.
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

./scripts/harness_keeper_docker_pr_lifecycle_reprobe.sh \
  --mutate \
  --phase review \
  --review-resume \
  --keeper-names sangsu,verifier \
  --run-id keeper-docker-pr-lifecycle-fork-live-20260507-remat \
  --run-dir /private/tmp/keeper-docker-pr-lifecycle-fork-live-20260507-remat
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
also passes for the expected fleet. The reprobe audit is run-id scoped, so stale
PR lifecycle evidence from earlier keeper proof runs cannot satisfy a fresh
run.

Use `--phase review --review-resume` only after create proof PRs already exist
for the run id and should be reviewed without creating another proof branch.
The resume path intentionally still resolves target PRs keeper-side; if a target
PR was closed or never existed, the review phase must report a blocker instead
of manufacturing approve evidence.
