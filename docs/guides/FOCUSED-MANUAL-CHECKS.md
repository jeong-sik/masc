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
compile MASC. Incomplete includes, invalid build stanzas and links back into
the checkout under `artifacts/` must be ignored while normal sources remain
visible and their errors still fail. Controls without the root boundary must
reject the same snapshots, and a control that reads `artifacts/` as data must
reject the link.
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

Dashboard harness scripts start and stop Vite through
`scripts/harness/lib/dashboard_dev_server.sh`. When changing that file,
run:

```bash
bash scripts/test-harness-dashboard-dev-server.sh
```

It puts a fake `node_modules/.bin/vite` behind the helper and checks that a
stop leaves no process, that a script ended by SIGINT, SIGHUP, SIGTERM or a
SIGKILL of its process group leaves no server, and that a start fails when the
server never answers or is not the only listener on the port. It needs
`python3`, `curl` and `lsof`. It does not start Vite or a browser.

A fixture DOM check does not prove the backend producer, live delivery,
deployment or a current fleet.
A production-path regression claim needs the actual producer/consumer evidence
and an appropriate failing control for that path.
