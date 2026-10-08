# DOS machine worker

This package owns a DOS machine in a separate stdio MCP worker. Attached
`masc_dos_*` tools expose the machine; `lane_observe` publishes owned screen
context. Screen calls return PNG image blocks and structured observations.
The declared `skills` directory supplies DOS play instructions.

The host uses private `lane_call`, controller snapshot and conditional release
ports. It checks credentials, holder departure and handoff targets under its
credential transaction; the worker rechecks the admitted holder before effects.
Board events are relayed after credential admission ends. These ports assume
host-owned stdio and do not authenticate a public worker endpoint.

MCP, Keeper, HTTP input, PNG/pad and invite-controller routes use the attached
worker. General spectators consume retained worker observations. Host activity
policy controls new execution. Keeper retirement conditionally releases the
named holder without executing a game move.

The Dockerfile expects a Linux `masc-dos-addon-worker` executable at the root of
its build context, produced from `bin/masc_dos_addon_worker.exe`. The image uses
`/state` as its persistent workspace and `/addon` as its read-only package.
See [state and media provisioning](../../docs/guides/machine-addon-state.md) for
programs, guest saves, checkpoints, pad layouts and replacement behavior.

Native amd64/arm64 image verification includes stdio execution, PNG output and
checkpoint restoration in a replacement worker using synthetic state; the
[state guide](../../docs/guides/machine-addon-state.md) records the exact source
and run. Actual games and installed-host reconciliation remain separate checks. See
[tool ownership](../../docs/design/lane-addon-tool-exports.md) for remaining
integration and evidence requirements.
