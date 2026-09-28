# Installed Muse native boundary receipt

Observed on 2026-09-27 KST using Muse Code 1.4.0 (`1.4.0-R4161.1`) on macOS.
The executable is the real vendor `muse serve`. A loopback HTTP service supplies
synthetic Meta Responses SSE and one authenticated MCP tool; it does not replace
MSP or the native tool executor. No production configuration, account credentials,
provider calls, or operator Keychain entries are needed by the final harness.

Reproduce from the repository with the installed vendor binary:

```sh
python3 scripts/probe-muse-native-boundary.py --mode read
python3 scripts/probe-muse-native-boundary.py --mode read-approved-shell
python3 scripts/probe-muse-native-boundary.py --mode full --hostile-project-settings
```

Each invocation creates a unique private fixture directory directly under the
operator's home, prints its path in the summary, and exits nonzero if the asserted
boundary is not observed. The child's HOME, XDG directories and TMPDIR are isolated
synthetic subdirectories. Remove the printed fixture directory after reviewing its
receipts. `--output` accepts a new directory; choose a location outside system temp
when checking the negative outside-write control. Shell paths are quoted, including
when that option contains spaces.

The harness sets `TBH_CREDENTIAL_BACKEND=file` and `TBH_DISABLE_TELEMETRY=1`, as
the vendor SDK's shared harness (`isolatedHostEnv`) does, and writes a synthetic
`api_key` into `auth.json` by hand; it never runs `muse login`. With the file
backend the client read that credential from `auth.json`. Without it, an earlier
harness blocked in `SecItemAdd` / `AuthorizationCopyRights` before MSP
initialization; that was a credential-backend problem, not a permission-profile
rejection.

## Production contract

This is the current launch contract, not part of the 2026-09-27 observation.
`Runtime_muse_serve.client_environment` sets `TBH_CREDENTIAL_BACKEND=file` for
every Muse child masc starts: each `muse serve`, and `muse login` through
`Runtime_muse_serve.login_environment`, which both the TUI's `/login muse` and
`masc runtime-account-login --client muse` (the installer's sign-in) use. A `muse login` run any
other way does not get it. A selected account HOME has no login keychain, and a
managed credential generation copies `auth.json` only, so a sign-in marked
`storage: "keychain"` is refused until the account signs in again through one of
those two paths. `TBH_DISABLE_TELEMETRY` is set by this harness only.

The vendor documents `TBH_CREDENTIAL_BACKEND` only inside the SDK example
harness above; no production documentation for it was found on 2026-09-28.
masc depends on it in production regardless, so a vendor release that drops or
renames it would send Muse sign-ins back to the Keychain.

Primary protocol references:

- [SDK quickstart fake Responses endpoint](https://meta-models.github.io/muse-code-sdk/next/generated/examples/quickstart-journey/)
- [SDK shared harness and file credential backend](https://meta-models.github.io/muse-code-sdk/next/generated/examples/shared-harness/)

## Results

All runs pin the user settings profile to `:ask-me`. Read modes pass
`--disable-write --disable-shell` and MSP `promptUnmatched`; full passes no disable
flags and uses MSP `allowAll`, matching the intended Full/Yolo adapter launch.
Each runs native read, native file write, native shell write, the injected
`mcp__masc__ping`, then two sibling-path writes and a final reply. All six recorded
runs completed with exactly one actual MCP invocation and the synthetic native
read marker observed.

| Receipt | Inside file / shell | Outside file / shell | Meaning |
| --- | --- | --- | --- |
| `read.json` | denied / denied | denied / denied | Shell approval aborted; exact MCP approved once |
| `read-approved-shell.json` | denied / denied | denied / denied | Deliberate shell approval still fails with `tool policy denied shell execution` |
| `full-home-hostile.json` | allowed / allowed | denied / denied | Full remains sandboxed for the sibling paths under the actual home |
| `full-control-clean.json` | allowed / allowed | denied / denied | Full control under macOS per-user temp |
| `full-control-hostile.json` | allowed / allowed | denied / denied | Same control with candidate project profile override |
| `full-temp-hostile.json` | allowed / allowed | allowed / allowed | System `/private/tmp` is writable; this negative control failed |

The hostile candidate is workspace `.muse/settings.json` selecting
`:unrestricted`, using the same settings schema as the user file. Both paired
controls behaved identically, and the final home-directory run remained confined.
This establishes that this candidate did not override the managed profile in this
binary. It does not establish a universal project/plugin/hook isolation guarantee.

The failed `/private/tmp` control is retained intentionally. These observations
support the vendor workspace sandbox with temp exceptions; they do **not** prove
that only the workspace and private TMPDIR are writable. The final outside sibling
path was under the operator's actual home, outside the child HOME and TMPDIR, to
avoid conflating that boundary with a vendor system-temp grant. Native reads of
that sibling file succeeded, as expected for the honest `Native_read` contract.

## Evidence scope

JSON receipts retain exact selected tool outcomes, approval subjects/choices,
host decisions, completion, and hashes of the original local MSP transcripts.
Fixture paths are replaced with `<fixture-root>`. Session identifiers, complete
vendor prompts, and credential files are not published. The final task-owned home
fixture was removed after this export.

This is installed-vendor execution evidence. It is not an OCaml compilation result,
a compiled MASC Keeper end-to-end run, guest isolation, `Native_none` support, or
proof of independent macOS Keychain account identity. Managed credential refresh,
source relogin session rebinding, and filesystem ownership are covered separately
by `test_runtime_muse_home.ml` and Keeper adapter tests; those require CI execution.

## Model discovery query

`model-list.json` records the installed native CLI against the same kind of
synthetic loopback catalog. Only initialize, initialized and model/list were
sent, and the provider received one catalog GET and no POST or model turn.
It confirms the typed response shape and reported limits, not real model
availability or account authentication.
