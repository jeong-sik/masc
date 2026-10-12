# Lane Add-on tool ownership

Attaching an MSX or DOS Add-on makes its declared tools and observation context
available. Detaching withdraws discovery and rejects subsequent calls, including
calls from an already constructed Keeper turn. The emulator projects remain
independent dependencies of their worker executables.

This document describes the source candidate. It is not evidence of a compiled,
merged, installed or running implementation.

## Package and discovery contract

```toml
[world.state]
mode = "persistent"

[world.tools]
invocation = "host_context"
export = ["masc_msx_load", "masc_msx_press", "masc_msx_screen"]
```

The worker owns schemas. Initialization requires exactly one advertised schema
for each declared export. The host rejects collisions with host tools or other
visible installations. Private observation, caller-context, controller and
input-history ports cannot be exported. Packages without exports remain valid
observation-only Add-ons; ordinary direct-invocation packages remain supported.

MCP Full and Seat discovery apply installation visibility and existing host
permissions. Keeper turns retain exact instance/schema handles in their frozen
capability surface. Calls revalidate those handles instead of resolving a stale
name to a replacement worker. Tool-list change notifications follow lifecycle
changes. Worker multimodal content and structured results cross the existing
receipt/audit and Keeper tool-result boundaries. A namespaced worker failure
record carries the producer's typed class and effect disposition; absent or
malformed records remain outcome-unknown. DOS recovery that already released a
holder promotes a later handler failure to post-effect before serialization.

Machine play and observation instructions belong to each package's declared
`world.skills.directory`. The existing Lane skill publisher adds and withdraws
these sources with installation reconciliation. MSX observation reads the PNG
returned by the attached tool; it does not require a static capture descriptor
or a host artifact-handle composition. A model unable to interpret the image
must report that limitation.

The SDK still limits Tool metadata representation. Standard icons and Tool
`_meta` preservation require an SDK upgrade. Source integration does not establish
full MCP conformance. Protocol references are the official
[tools specification](https://modelcontextprotocol.io/specification/2026-07-28/server/tools)
and [revision changelog](https://modelcontextprotocol.io/specification/2026-07-28/changelog).

## Host policy and worker effects

`Machine_addon_host` derives caller identity from verified host authority.
Model arguments cannot supply it. Host activity configuration gates new machine
execution and input; reads, checkpoints, eject and controller return remain
available while activity is off. Unavailable activity configuration refuses new
execution. Activity refusals retain typed pre-effect errors through HTTP, MCP
and Keeper adapters.

DOS credential admission covers controller snapshots, departed-holder recovery,
recipient validation and mutation admission. Workers atomically compare the
admitted holder before effects. Credential scope precedes worker RPC locking.
Lifecycle release conditionally frees only the named holder. Board events are
queued in worker response order and published after credential admission ends.

The worker owns emulator state, media, save files, checkpoint operations, pad
loading and frame rendering. Configured persistent volumes bind workspace,
logical installation and package identity; manual attachments have their own
state identity. Host build identity does not claim an emulator core identity.
`masc_dos_meta` and `masc_msx_meta` report the actual worker core.

## Observation and input evidence

Workers publish screen metadata and an explicit loaded flag. RGB live payloads
are transferred as packet artifacts, retained by the host and represented by
hash references in model-visible rows.

Each observation also captures an immutable input prefix. The private
`lane_machine_inputs` port pages that exact incarnation/count using exclusive
cursors and a JSON payload envelope. The host validates page identity and
cardinality, transfers only missing records, and durably retains the JSONL
sequence before returning the observation. Transient transfer/storage failure
cannot publish a partially retained prefix as complete.

Native `msx_capture` and `dos_capture` bindings resolve a shared attached worker's
completed observation. They preserve the existing screen and input-ledger source
envelopes without calling a host emulator. Revalidation after artifact I/O
rejects detached, replaced or superseded observations. Missing or refreshing
workers yield explicit unavailable source coverage.

Producer commits, failures and detach wake interested machine consumers.
Admission validates both configured Lane-output edges and implicit machine
edges with the same dependency predicate used by notification. Manual attach and
configuration reconciliation serialize graph validation through insertion, so
concurrent requests cannot admit opposite sides of a cycle.

## HTTP and operator surfaces

MSX input, inventory, checkpoint and tick routes invoke the attached worker.
DOS input, PNG, pad, invite-controller and seat reads use the same shared worker.
The common live endpoint reads the last completed retained artifact without
waiting for emulator RPC. It rechecks instance/sequence after I/O. In-flight
calls and observations mark cached screens as refreshing; unknown tool outcomes
invalidate the prior stable observation and schedule reconciliation.

Lane inventory reads worker publication separately from host activity settings.
Unavailable observations are distinct from an unloaded machine. `/msx/activity`
reads host policy, while worker availability is observed through the worker
surfaces. The server library no longer directly depends on MSX/DOS lane libraries.

## Remaining integration and evidence

- A traversal of repository-local Dune library declarations finds no path from
  the root or server library to either emulator lane library. Each machine
  worker reaches its own emulator and does not reach the root host library.
  Confirm this with external package dependencies and actual linked executables;
  the declaration traversal is not link-time evidence.
- Execute the migrated HTTP, Keeper composition/vision and discovery fixtures
  against their committed integration heads. Source migration alone is not proof.
- Exercise the documented [media/state provisioning](../guides/machine-addon-state.md)
  and run the package image workflow, including native worker preparation.
- Resolve SDK metadata limitations where required by the final public contract.
- Obtain compilation/typechecking and execute the changed OCaml fixtures under
  the repository workflow. Build and exercise worker images and persistent state.
- Finish independent review and integration of the submitted stack, then verify
  installed runtime, MCP/Keeper lifecycle and visible TUI behavior.

Focused remote CI has built and passed the DOS worker stdio scenario
([run 37807728889](https://github.com/jeong-sik/masc/actions/runs/37807728889)),
MSX worker/PNG fixtures (4 tests,
[run 37807943763](https://github.com/jeong-sik/masc/actions/runs/37807943763)),
and package configuration, worker lifecycle and input history (61 tests,
[run 37807732385](https://github.com/jeong-sik/masc/actions/runs/37807732385)).
These runs certify their recorded commit and fixture scope. Public host and HTTP
integration tests are separate pending checks; Docker images and installed runtime
behavior have not been verified. Earlier JavaScript and Python package checks
cover existing client/package behavior, not installed OCaml workers.
