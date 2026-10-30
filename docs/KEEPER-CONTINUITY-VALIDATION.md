# Keeper Continuity Validation

**Status**: operator validation harness
**Updated**: 2026-10-02

This validation proves per-Keeper lane continuity from typed runtime evidence.
It does not inspect assistant prose and does not require the model to echo a
state template.

## Pass Contract

A run passes only when all of the following are correlated to the same Keeper,
trace, and turn identity:

1. the Keeper is registered and its keepalive fiber is live;
2. the input event is durably queued or delivered to that Keeper lane;
3. a turn receipt records the terminal outcome;
4. the runtime manifest records the expected checkpoint load/save boundary;
5. a restart restores the saved agent core checkpoint and completes a new turn;
6. a second Keeper lane continues while the tested lane is busy or fails.

Task, goal, board, HITL, connector, scheduler, and Fusion mutations require
their own typed transition or tool-result evidence. Message text is context,
not mutation evidence.

## Commands

Plumbing-only dry run:

```bash
DRY_RUN=1 scripts/harness_keeper_continuity_validation.sh
```

Isolated live run, after preparing an isolated base with working runtime
configuration and a promoted sandbox image. This example explicitly chooses
Apple container microVMs and the host catalog's `base` image:

```bash
BASE_PATH="/path/to/prepared-isolated-base" PORT=19452 \
MASC_CONFIG_DIR="/path/to/prepared-isolated-base/.masc/config" \
KEEPER_SANDBOX_PROFILE=microvm KEEPER_SANDBOX_IMAGE=base \
KEEPER_MICROVM_BACKEND=apple_container \
scripts/harness_keeper_continuity_validation.sh
```

The harness chooses no sandbox. `KEEPER_SANDBOX_PROFILE` is required for a live
run. `docker` and `microvm` require `KEEPER_SANDBOX_IMAGE`; `microvm` also requires
an explicit `KEEPER_MICROVM_BACKEND`. `remote_ssh` requires
`KEEPER_REMOTE_ENDPOINT`, naming an endpoint in the isolated runtime config.
Product admission still validates the actual profile, backend, image and
endpoint. Missing declarations stop before starting a server. Recovery reuses
the same Keeper's persisted declaration; it does not select a new sandbox.
The scenario purpose is part of Keeper instructions, not a Keeper-up `goal` field.

`KEEPER_RUNTIME_NAME` names the runtime the test Keeper starts on; empty uses
the server's default. `TARGET_PHASES` picks from `bootstrap`, `liveness`,
`continuity` and `recovery`, joined by commas, all four by default. An unknown
name, an empty list or a stray comma stops the run with exit 2 before it
starts.

A phase counts the Keeper as live when `masc_keeper_status` reports
`keepalive_running`, `runtime.phase = "running"` and
`runtime.fiber_health = "alive"`.

Use an existing server:

```bash
START_SERVER=0 \
MCP_URL="http://127.0.0.1:19452/mcp" \
KEEPER_SANDBOX_PROFILE=microvm KEEPER_SANDBOX_IMAGE=base \
KEEPER_MICROVM_BACKEND=apple_container \
scripts/harness_keeper_continuity_validation.sh
```

`DRY_RUN=1` proves only artifact/report plumbing. It is never runtime evidence.

## Required Artifacts

The harness writes an isolated run directory under
`logs/keeper_continuity/<run_id>/`. Preserve:

- manifest rows for checkpoint load/save and terminal turn events;
- execution receipts and tool-result evidence;
- before/after Keeper status snapshots;
- restart/restore result;
- the independent-lane probe result;
- explicit errors for any missing or malformed artifact.

An absent artifact is a failed gate, not an empty success value. Historical
message bodies that contain retired protocols are preserved as ordinary text
and must not be parsed into live state.

## Result Meaning

- `PASS`: every required typed edge is present and correlated.
- `FAIL`: any edge is absent, contradictory, unparseable, or belongs to a
  different Keeper/trace/turn.

There is no partial success category for release evidence. Diagnostic runs may
report which phases completed, but production promotion remains failed until
all gates pass.

See [KEEPER-STATE-OWNERSHIP.md](./KEEPER-STATE-OWNERSHIP.md) for the normative
ownership contract.
