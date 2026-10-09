# MSX machine worker

This package owns an MSX machine in a separate stdio MCP worker. Attached
`masc_msx_*` tools expose input, checkpoints, inventory and PNG screens;
`lane_observe` publishes screen context without advancing emulation. The host
passes admitted caller identity through the private `lane_call` port and relays
machine announcements after the call leaves its authority boundary.

MSX play and observation instructions live in the declared `skills` directory.
They read the returned PNG and its frame metadata. Host activity policy controls
new execution; HTTP tick and input routes invoke the worker. Lane spectators
consume retained worker observations rather than a host emulator.

The Dockerfile expects a Linux `masc-msx-addon-worker` executable at the root of
its build context, produced from `bin/masc_msx_addon_worker.exe`. The image uses
`/state` as its persistent workspace and `/addon` as its read-only package.
See [state and media provisioning](../../docs/guides/machine-addon-state.md) for
installation, BIOS/media paths, checkpoint restore and state identity.

Worker behavior has focused remote CI coverage. The Docker image and persistent
replacement remain unverified; prepare the native executable for the target
architecture before building the image. See
[tool ownership](../../docs/design/lane-addon-tool-exports.md) for integration
status and SDK metadata limits. Public MCP version negotiation belongs to the
host; the private worker negotiates the version supported by its installed SDK.
