# Sandbox Validation Runbook

After the sandbox root-fix family lands (#11594 PR-1, #11610 PR-3,
#11627 PR-2, #11679 PR-3b), the keeper Docker isolation must be
verified end-to-end — not just at the static config layer.  This
runbook is the standard procedure.

## Background

The five reports under `~/Downloads/Kimi_Agent_샌드박스 설정 문제/`
identified three independent defects whose composition produced a
silent host-fallback bypass:

| ID | Defect | Closed by |
|----|--------|-----------|
| A  | Native dispatch route ignored sandbox carrier | #11627 (PR-2) |
| B  | `keeper_meta.json` parsing fell back to `local` on missing `sandbox_profile` | #11594 (PR-1) |
| C  | Two profile resolvers (`meta.sandbox_profile` direct vs `effective_sandbox_profile`) disagreed | #11610 (PR-3) |
| —  | `make_tool_bundle` cold-started a new container per tool call | #11679 (PR-3b) |

Static validation (counting `sandbox_profile` fields across
`~/.masc/keepers/*.json` and `<repo>/.masc/keepers/*.json`) is
necessary but not sufficient.  The dynamic check below confirms the
container actually executes the tool call.

## Static validation

```bash
for k in ~/.masc/keepers/*.json /path/to/masc-mcp/.masc/keepers/*.json; do
  name=$(basename "$k" .json)
  profile=$(jq -r '.sandbox_profile // "<missing>"' "$k" 2>/dev/null)
  network=$(jq -r '.network_mode // "<missing>"' "$k" 2>/dev/null)
  printf '%-30s %-8s %s\n' "$name" "$profile" "$network"
done
```

Pass criteria:
- Every keeper JSON declares both `sandbox_profile` and `network_mode`
  explicitly (no `<missing>`).
- Profiles are one of `local` or `docker`.
- `(profile, network)` pairs are consistent: `docker + none` (hard),
  `docker + inherit` (soft), or `local + inherit`.

If any keeper reports `<missing>`, run
`scripts/migrate-keeper-meta-sandbox.sh --apply` and restart that
keeper before continuing.

## Dynamic validation — container hostname proof

For each `sandbox_profile=docker` keeper:

1. Restart the keeper so the new factory wiring takes effect:
   ```bash
   sb keeper restart <keeper-name>
   ```
2. From the masc-mcp client, dispatch `keeper_bash` with the
   container hostname probe:
   ```text
   keeper_bash { "cmd": "cat /etc/hostname" }
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
keeper_bash { "cmd": "pwd" }
```
The response should report a path under
`Keeper_turn_sandbox_runtime.container_root` (e.g.
`/keeper/<name>`), not the host playground root.

## Negative test — Local keeper

For one `sandbox_profile=local` keeper:
1. Same probe (`keeper_bash { "cmd": "cat /etc/hostname" }`).
2. Pass criteria — the response contains the host hostname and the
   `via` field reads `host`.  This confirms PR-3 did not over-rotate
   Local→Docker.

## Performance check (PR-3b)

PR-3b memoizes per `(in_playground, cwd)`.  Two consecutive
`keeper_bash` calls with the same cwd should reuse the same
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
- Plan SSOT — `planning/claude-plans/30m-users-dancer-downloads-kimi-agent-greedy-pebble.md`
- TLA spec — `specs/boundary/SandboxDispatch.tla` (#11638)
