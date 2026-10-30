# Sandbox Validation Runbook

After the sandbox root-fix family lands (#11594 PR-1, #11610 PR-3,
#11627 PR-2, #11679 PR-3b), the keeper Docker isolation must be
verified end-to-end — not just at the static config layer.  This
runbook is the standard procedure.

## Background

Three independent defects previously combined to produce a host-fallback bypass:

| ID | Defect | Closed by |
|----|--------|-----------|
| A  | Native dispatch route ignored sandbox carrier | #11627 (PR-2) |
| B  | `keeper_meta.json` parsing filled in a profile when `sandbox_profile` was missing | #11594 (PR-1) |
| C  | Two profile resolvers (`meta.sandbox_profile` direct vs `effective_sandbox_profile`) disagreed | #11610 (PR-3) |
| —  | `make_tool_bundle` cold-started a new container per tool call | #11679 (PR-3b) |

Static validation (counting `sandbox_profile` fields across
`<base-path>/.masc/keepers/*.json` and `<repo>/.masc/keepers/*.json`) is
necessary but not sufficient.  The dynamic check below confirms the
container actually executes the tool call.

## Static validation

```bash
for k in /path/to/base/.masc/keepers/*.json /path/to/masc/.masc/keepers/*.json; do
  name=$(basename "$k" .json)
  profile=$(jq -r '.sandbox_profile // "<missing>"' "$k" 2>/dev/null)
  network=$(jq -r '.network_mode // "<missing>"' "$k" 2>/dev/null)
  printf '%-30s %-8s %s\n' "$name" "$profile" "$network"
done
```

Pass criteria:
- Every keeper JSON declares both `sandbox_profile` and `network_mode`
  explicitly (no `<missing>`).
- Profiles are one of `docker` (or `docker_hardened` / `docker_with_git` in Keeper TOML), `microvm` or `remote_ssh`.
- `(profile, network)` pairs are ones the profile accepts
  (`Keeper_types_profile_sandbox.network_mode_rejection`): `docker` takes
  `none` or `inherit`, `microvm` takes `none`, `inherit` or `policy` (and when `network_mode = "inherit"` is used on a host whose `/etc/resolv.conf` only lists loopback/link-local/unspecified resolvers, `[sandbox] microvm_dns` must name a reachable upstream DNS server), and
  `remote_ssh` takes `inherit` only.

If any keeper reports `<missing>`, run
`scripts/migrate-keeper-meta-sandbox.sh --apply` and restart that
keeper before continuing.

## Dynamic validation — container hostname proof

For each `sandbox_profile=docker` keeper:

1. Restart the keeper (`masc_keeper_down` then `masc_keeper_up`) so the new factory wiring takes effect.
2. From the masc client, dispatch `Execute` with the
   container hostname probe:
   ```text
   Execute { "argv": ["cat", "/etc/hostname"] }
   ```
3. Pass criteria — the response body must contain a hostname
   matching `masc-keeper-turn-<name>-*` (the convention from
   `Keeper_sandbox_read_backend.container_name_of`).
4. Fail criteria — the response contains the host machine's
   hostname (e.g. the result of `hostname` on the developer's mac).
   This means the dispatch path bypassed the sandbox; check the
   `via` field on the response — it should read `docker`, not
   `host`.

A second probe pins the cwd mapping:
```text
Execute { "argv": ["pwd"] }
```
The response should report a path under
`Keeper_sandbox.container_root` (e.g.
`/home/keeper/playground/<name>`), not the host playground root.

## Performance check (PR-3b)

PR-3b memoizes per `(in_playground, cwd)`.  Two consecutive
`Execute` calls with the same cwd should reuse the same
container:

Pass criteria — at most one `Created container` log entry per turn.
Multiple entries mean the factory cache is missing.

## When to escalate

Open a comment on the relevant root-fix PR (or a fresh issue if all
four are closed) when:
- Dynamic validation fails on any docker keeper after a fresh
  restart.
- The performance check shows more than one `Created container` line
  per turn (factory cache miss).

Reference threads:
- Sandbox root-fix family — #11594, #11610, #11627, #11679
- TLA spec — `specs/boundary/SandboxDispatch.tla` (#11638)
