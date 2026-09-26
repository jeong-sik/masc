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

The harness uses the vendor SDK's documented test-only
`TBH_CREDENTIAL_BACKEND=file` and `TBH_DISABLE_TELEMETRY=1`. The file backend avoids
synthetic credential insertion into macOS Keychain. Without it, an earlier harness
blocked in `SecItemAdd` / `AuthorizationCopyRights` before MSP initialization;
that was a harness credential-backend problem, not a permission-profile rejection.
These test environment variables are not added to the production launch contract.

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
