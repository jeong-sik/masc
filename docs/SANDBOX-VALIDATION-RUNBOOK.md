# Sandbox Validation Runbook

Keeper execution boundaries must be verified from the resolved contract and
the live runtime. A TOML value alone does not prove that a tool ran in the
declared boundary.

## Background

`sandbox_profile`, `network_mode`, `sandbox_image`, and `allowed_paths` are
configuration fields owned by the resolved Keeper TOML. Runtime keeper JSON is
an execution-state snapshot and deliberately does not persist those fields.
The runtime never falls back from a Docker profile to a host process.

## Resolved and live validation

Call the canonical status tool without `name` to inspect the fleet:

```text
masc_keeper_sandbox_status {
  "include_preflight": true,
  "verbose": true
}
```

Pass criteria:
- Every item reports `sandbox_profile`, `configured_network_mode`,
  `security_boundary`, and an explicit live mode.
- Valid pairs are `docker + none`, `docker + host`, and `local + host`.
  `local + none` is rejected during configuration parsing and CRUD writes.
- Docker items report typed preflight status or a visible preflight error.
- `security_boundary.execution_boundary` is `docker_container` for Docker and
  `host_process` for Local.
- `why_no_container=docker_idle` means there is no active on-demand turn or
  one-shot container; it is not a fallback or a failed start.

If an item reports `effective_meta_error`, repair the Keeper TOML through the
current Keeper CRUD surface. There is no legacy metadata migration or inferred
host execution.

## Dynamic validation — container hostname proof

For each `sandbox_profile=docker` keeper:

1. Restart the keeper so the new factory wiring takes effect:
   ```bash
   sb keeper restart <keeper-name>
   ```
2. From the masc client, dispatch `Execute` with the
   container hostname probe:
   ```text
   Execute { "executable": "cat", "argv": ["/etc/hostname"] }
   ```
3. Pass criteria — the response body must contain a hostname
   matching `masc-keeper-turn-<name>-*` (the convention from
   `Keeper_turn_sandbox_runtime.container_name_of`).
4. Fail criteria — the response contains the host machine's
   hostname (e.g. the result of `hostname` on the developer's mac).
   This means the dispatch path bypassed the sandbox; check the
   `via` field on the response — it should read `docker`, not
   `host`.

A second probe pins the cwd mapping:
```text
Execute { "executable": "pwd" }
```
The response should report a path under
`Keeper_turn_sandbox_runtime.container_root` (e.g.
`/keeper/<name>`), not the host playground root.

## Negative test — Local keeper

For one `sandbox_profile=local` keeper:
1. Same probe (`Execute { "executable": "cat", "argv": ["/etc/hostname"] }`).
2. Pass criteria — the response contains the host hostname and the
   `via` field reads `host`.  This confirms PR-3 did not over-rotate
   Local→Docker.

## Performance check (PR-3b)

PR-3b memoizes per `(in_playground, cwd)`.  Two consecutive
`Execute` calls with the same cwd should reuse the same
container:

```bash
sb keeper logs <docker-keeper-name> --tail 100 | rg 'Created container'
```

Pass criteria — exactly one `Created container` line per turn.
Multiple lines mean the factory cache is missing.

## When to escalate

Open a comment on the relevant root-fix PR (or a fresh issue if all
four are closed) when:
- Dynamic validation fails on any docker keeper after a fresh
  restart.
- A local keeper unexpectedly reports a `masc-keeper-*` hostname
  (Local→Docker over-rotation).
- The performance check shows more than one `Created container` line
  per turn (factory cache miss).

Reference threads:
- Sandbox root-fix family — #11594, #11610, #11627, #11679
- Plan SSOT — `planning/claude-plans/30m-users-dancer-downloads-provider-c-agent-greedy-pebble.md`
- TLA spec — `specs/boundary/SandboxDispatch.tla` (#11638)
