# Installation and first-run audit — 2026-09-08

Scope: release candidate 0.34.0, English/Korean README, installation guide,
release evidence runbook, Firefox native host guide, installer wizard and generated
MCP client configuration. Historical evidence and RFC proposals are not presented
as current user instructions. Native release CI is separate from the checks below.

## Corrected

| Finding | Cause and correction | Evidence |
|---|---|---|
| Interactive provider menu silently selects the default | `$(prompt_provider)` captures stdout; `-t 1` therefore fails. Detect the terminal on stdin/stderr, where prompts are read/written | `test/test_installer_wizard.py`: real PTY selects second provider |
| Invalid numeric choices can fail Bash arithmetic | Match displayed menu entries instead of evaluating user input; EOF cancels | PTY cases: `08`, oversized integer, EOF |
| Explicit `--provider` ignored on existing config | Existing-config skip now respects explicit provider selection | Existing-config wizard test |
| CLI installed but not logged in reported connectivity success | Run the runtime's login probe before success | Failed login-probe behavior test |
| Missing healthcheck could be reported as passed | Treat absent check metadata as skipped | Missing healthcheck behavior test |
| Conflicting flags silently ignored | Reject `--provider --no-wizard` and `--sandbox` without `--team` before downloads | Flag behavior tests |
| Keeper README example rejected by TOML loader | Move `instructions` from `[keeper.tools]` into `[keeper]` | Both README examples parsed with Python `tomllib`; loader contract in `keeper_types_profile_toml_parser.ml` |
| Claude Desktop bridge omitted bearer header | Set `--header` using the declared environment variable in README and generated client config | `test/test_auth_login.ml` JSON assertions; native test execution delegated to CI |
| Source and browser onboarding assumes a checkout/toolchain | Document compiler switch/frontend build and tagged standalone browser installer/extension setup | Source commands compared with Release workflow; browser installer Python tests |
| Runbook and native protocol facts stale | Remove duplicated stale package version/nonexistent shortcuts and main CI artifact claim; correct incoming frame bound to 8 MiB | `release.yml`, `ci.yml`, `masc_browser_host.ml` |

Bash behavior is documented in the [official command substitution manual](https://www.gnu.org/software/bash/manual/html_node/Command-Substitution.html).
The bridge header syntax follows [mcp-remote's custom-header documentation](https://github.com/geelen/mcp-remote#custom-headers).

## Further improvements found

These are proposals, not implemented or verified product behavior.

| Priority | Gap | Completion criterion |
|---|---|---|
| Next | Installation success does not mean a Keeper is ready: roster, model and sandbox are separate | One first-run screen shows their individual states and offers explicit first-Keeper creation, then links to its first successful turn |
| Next | Credential presence and an HTTP healthcheck cannot prove model generation/tool execution | An explicit optional real model probe reports selected runtime, authentication, generation and tool execution separately; never display skipped checks as success |
| Next | Firefox temporary extension disappears after restart and needs a separate tagged download | Publish a durable extension distribution and verify reconnect after browser restart on supported platforms |
| Later | Prefix rollback excludes workspace guest shim and explicit configuration reset | Fault-injection install verifies a coherent prior shim/sidecar and configuration state after interrupted publication |

No model turn, browser extension session or fresh-machine installation was claimed
from the shell tests. Use the exact-head Release workflow's native and fresh Ubuntu
installation results before publishing the candidate.
