# DOS world package

This package owns one js-dos/WASM DOS machine. A bundled homebrew program accepts
N, increments its counter, writes `STATE.BIN`, and redraws a green bar. The same
package supplies common Lane rows, retained artifact bytes, a typed action, and a
read-only Skill. It does not use a host keyboard, Browser tab, existing MSX owner,
commercial game or downloaded ROM.

The package depends on the generic Lane `act`/`world.actions` and artifact-ingress
host slice. Those interfaces are required before installation; this package's CI
alone does not prove a frozen MASC host, Keeper continuity, or Dashboard behavior.
Actual DOS verification is pending CI until the workflow has passed for the exact
source commit.

## Install

Build and test in CI using [the package workflow](../../.github/workflows/lane-dos-package.yml).
It pins the Node base image by digest, uses `npm ci` with exact direct versions and
integrity-locked dependencies, assembles `guest/lanedemo.asm` with NASM, and runs
the actual scenario on native amd64 and arm64 runners. It retains each image and
its evidence separately as workflow artifacts. A successful artifact includes
`SOURCE_COMMIT`, Docker image identity, `BUILD_SHA256SUMS`, MCP receipts, measured
counter values, PNG captures, raw `STATE.BIN` files, and server diagnostics.

Load the CI-produced image into the Docker engine used by MASC. Place this package
directory where MASC can read its manifest and Skill, then copy
[install.toml](install.toml) into the active config root's `lane-addons/` directory.
Set `manifest_path` relative to the declaration's new location, or use its actual
absolute path. Choose a distinct installation ID and run ID. Image build/load is
explicit: the installation loader does not install npm packages or build images.

The declaration has `sources=[]` because this worker owns its environment. There
is no runtime path inference, implicit network access, environment variable, or
additional Keeper approval step. The manifest's container resource envelope
isolates this optional environment. The production server reads its image files
and uses WASM's virtual filesystem; the CI scenario runs with `--read-only` and
`--network none`, with only the independent verifier's proof directory writable.

MASC's existing TOML reconciliation applies the declaration. Desired configuration,
applied revision and current observation phase remain distinct. Removing the
declaration removes its own worker through the existing owner lifecycle. A worker
replacement starts a new DOS machine; prior evidence is preserved by the host.

## Observe and act

`lane_observe` accepts the host-provided `{instance_id, incarnation}` context plus
the empty source binding. Its initial reply may contain no rows and incomplete
coverage while the program boots. Subsequent replies return the latest verified
screen and guest state without sending input, pausing the machine, or waiting for
an outstanding action. Intermediate frame callbacks are coalesced. The clock is
explicitly a **capture sequence**, not an emulated frame or game turn.

The package advertises this action payload through MCP `tools/list`:

```json
{
  "context": {"instance_id": "<current-instance>", "incarnation": "<current-instance>"},
  "request_id": "<request-id>",
  "action": {"kind": "increment"}
}
```

Keeper calls the existing host's generic Lane action entrypoint, using the current
instance and expected incarnation. The host supplies trusted execution provenance,
validates the advertised schema, and owns durable receipts. The package's memory
cache additionally makes repeated or overlapping requests with the same ID reuse
their receipt. Unknown actions and requests for another incarnation fail before
input. The only supported action is `increment`; there is no reset or restore
within one incarnation.

`confirmed` is returned only after the observed guest counter increments modulo
65536 **and** a captured image matches that counter's green bar. A key enqueue is
insufficient. If failure occurs after input might have started, the result is
`outcome_unknown`; it must not be blindly replayed. The worker's confirmation is
still a producer assertion: CI independently decodes the returned bytes and pixels.

The output packet's artifact entries carry local IDs, MIME types and base64 bytes.
Rows reference those IDs. The host computes and retains actual artifact hashes;
it does not fetch arbitrary package-supplied file/HTTP URLs. PNGs are encoded from
the actual VGA framebuffer; the adapter does not draw a replacement screenshot.

## Qualification scope

The package test speaks real MCP stdio to the server and runs the actual assembled
program in the pinned WASM engine. It independently checks 0→1, ordinary and
overlapping duplicate requests, stale incarnation, invalid action, and read-only
observations, including concurrent action and observation requests. Either the
before or after capture is valid; the proof does not assume which response wins.
Held-action independence belongs to the host's explicit barrier tests.
It validates full image geometry and the raw guest file, rather than
accepting a success label or merely comparing screenshot hashes. The sampling
interval and outer test timeout are CI controls, not production readiness rules.

The next host-level proof must install this package after fixing the host revision,
call the generic action through existing Keeper authority, verify the retained
artifacts through host APIs, and remove it while unrelated activity continues.
This package proof does not establish strategic gameplay, productivity gains,
machine checkpoints, fork, DOS compatibility beyond this program, or a new scheduler.

Primary API references: [js-dos command interface](https://js-dos.com/command-interface.html),
[Node implementation](https://github.com/caiiiycuk/emulators/blob/8.xx/src/impl/emulators-impl.ts),
[NASM 16-bit/.COM documentation](https://www.nasm.us/doc/nasm10.html).
Use the pinned npm 8.4.2 implementation when checking behavior; moving upstream
documentation is supporting context. `emulators` supplies GPL-2.0 code and licenses
in the image; the homebrew assembly source is MIT licensed in its header.
