# DOS world package

This package owns one js-dos/WASM DOS machine. A bundled homebrew program accepts
N, increments its counter, writes `STATE.BIN`, and redraws a green bar. The same
package supplies common Lane rows, retained artifact bytes, a typed action, and a
read-only Skill. It does not use a host keyboard, Browser tab, existing MSX owner,
commercial game or downloaded ROM.

The package depends on the generic Lane `act`/`world.actions` and artifact-ingress
host slice. Those interfaces are required before installation; this package's CI
alone does not prove a frozen MASC host, Keeper continuity, or Dashboard behavior.
Package CI and separate isolated host probes have passed for the fixed candidate
revisions recorded under [qualification scope](#qualification-scope). Those
results are distinct from later source revisions and production deployment.

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
the empty source binding. Its first call waits inside this optional worker until
the guest file and matching screen are ready, or returns a boot error. Thus an
idle host's initial observation produces data without a second wake or polling.
Subsequent replies return the latest verified
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
accepting a success label or merely comparing screenshot hashes. One initial
observation must return verified data without polling. The outer test timeout is
a CI control, not a production readiness rule.

The qualified DOS package source is
`e0d4e0c35ae9b550d53a952c3340709f2deac4c6`; its
[package CI run](https://github.com/jeong-sik/masc/actions/runs/34699775204)
exercised the actual guest on amd64 and arm64. Two separate local host probes used
host and Dashboard source `4218e1c05e2029e7b63d8847aa857a18dd6db084`, from
[native CI](https://github.com/jeong-sik/masc/actions/runs/34699821571) and
[Dashboard CI](https://github.com/jeong-sik/masc/actions/runs/34699823363).
The running native binary SHA-256 was
`9f7f6896946c51dcf0fc3bad3ef847f62dd1cd0ef5560cef5e306d070d939a0c`.
These CI links identify the tested package and host inputs; the following host
results came from isolated local executions, with retained raw API responses,
Dashboard screenshots, guest bytes, hashes and cleanup records.

The first host probe installed DOS and an independent controlled-capture observer
through TOML, with no Attach request or DOS-specific host/UI change. It read the
package's exact SKILL.md through the existing catalog/editor, then used the
common Dashboard to submit one increment request. The receipt progressed from
queued to confirmed. Independent decoding of host-retained STATE.BIN and every
VGA pixel established guest counter 0→1. The companion observer progressed through
sequences 2→3→4 and stayed active after DOS removal. DOS evidence remained readable
after detach; both owned containers and the server shut down normally. This
measured companion progress during the workflow, not a Keeper model turn or a
latency guarantee. See the [host action contract](../../docs/guides/lane-world-actions.md#qualification-boundary).

The second probe connected DOS to the generic
[output-statistics package](../output-statistics/README.md), using statistics
source `a534bd96e36106df1a2bfc6a8a352ff342b27e98` and its verified
[CI image](https://github.com/jeong-sik/masc/actions/runs/34697003041).
TOML selected the same-run producer's whole `latest_completed` output. The actual
guest changed 0→1 while the supplied-row gauge remained 1; two additional reads of
producer sequence 3 did not accumulate counts. After DOS removal, the same
statistics worker stayed active with unavailable input and no current count row.
Original DOS and statistics evidence remained hash-correct, and both workers
were removed normally. This is a gauge of supplied rows, not the guest counter
or a cumulative event statistic. See [output composition](../../docs/guides/lane-output-composition.md)
and the [DOS statistics declaration](../../docs/examples/lane-addons/dos-statistics.toml).

Both probes ran the actual DOS guest without a replacement capture fixture;
only the first probe's companion source was controlled data. They establish
bounded behavior of those frozen candidate combinations, not every later merged
head. No Keeper inference, production runtime change, strategic gameplay,
productivity gain, long-duration continuity, performance SLO, machine checkpoint,
fork or DOS compatibility beyond this program was established.

Primary API references: [js-dos command interface](https://js-dos.com/command-interface.html),
[Node implementation](https://github.com/caiiiycuk/emulators/blob/8.xx/src/impl/emulators-impl.ts),
[NASM 16-bit/.COM documentation](https://www.nasm.us/doc/nasm10.html).
Use the pinned npm 8.4.2 implementation when checking behavior; moving upstream
documentation is supporting context. `emulators` supplies GPL-2.0 code and licenses
in the image; the homebrew assembly source is MIT licensed in its header.
