# Focused manual checks

Run these existing checks when changing their production boundary. They are
explicit manual checks, not an additional PR or release gate. Run commands
from the repository root and record the exact head, command, exit status and
observed scope. The constitution governs build and CI requests.

## Dune source discovery

```bash
python3 test/test_dune_source_discovery.py
```

This check requires Dune 3.22 or newer. It copies the actual root `dune` file
into temporary projects and queries `dune describe workspace`; it does not
compile MASC. Incomplete includes and invalid build stanzas under `artifacts/`
must be ignored while normal sources remain visible and their errors still
fail. Controls without the root boundary must reject the same snapshots.
The check is also included in `@runtest` and selectable as
`TARGET_SUITES=test_dune_source_discovery` in the existing Test workflow.
It does not prove a full build, runtime behavior or discovery outside the
declared output directory.

## Shell boundaries

```bash
bash test/test_monitor_system_health_paths.sh
bash test/test_deploy_preflight.sh
```

The monitor check calls the real `scripts/monitor-system-health.sh` path
resolver with an isolated base directory. It checks the default and overridden
pressure-file paths and rejects missing or relative base paths. It does not
measure host pressure, sample a running server or test pressure delivery.

The deployment check copies the actual install and preflight scripts into a
temporary repository and runs them with a controlled helper. A rejected runtime
configuration must leave the install prefix absent. Separate helper outcomes
cover missing, accepted, caller-owned and unsupported browser Add-on
declarations. This checks the shell consumer of the helper result; it does not
validate a real runtime TOML, install a built binary or start a server.

## Dashboard fixture rendering

With the dashboard dependencies installed, run the existing component cases:

```bash
pnpm --dir dashboard test src/demo/keeper-chat-interleave-contract-fixture.test.ts src/demo/keeper-chat-tool-output-failure-contract-fixture.test.ts
```

These fixtures render production `ChatTranscript` components in happy-dom.
The interleave case supplies controlled exact tool-call lookup responses; the
failure case supplies failed hydration and missing-coverage observations.
Their assertions check component rendering and interaction against fixture
state. They do not exercise a server producer, a live Keeper conversation,
SSE delivery or actual browser visibility.

For a manual Chromium rendering check of the same fixtures:

```bash
bash scripts/harness_dashboard_keeper_chat_interleave_contract_dom_smoke.sh
bash scripts/harness_dashboard_keeper_chat_tool_output_failure_contract_dom_smoke.sh
bash scripts/harness_dashboard_keeper_chat_control_status_dom_smoke.sh
```

These commands start their own local Vite process and stop it on exit. They
require pnpm, the dashboard dependencies and installed Playwright Chromium;
the failure and control-status scripts additionally use Python's Playwright
package. Their default ports are 5186, 5187 and 5188; set `PORT` for an unused
port if needed. Each prints its fixture URL and screenshot paths. The scripts
use the configured dashboard proxy target (default localhost:8935), so record
that target if investigating any network-backed component behavior.

The Chromium checks assert declared DOM attributes and fixture interactions.
Screenshots are inspection artifacts. A fixture screenshot or DOM check does
not prove the backend producer, live delivery, deployment or a current fleet.
A production-path regression claim needs the actual producer/consumer evidence
and an appropriate failing control for that path.
