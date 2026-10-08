# Machine activity admission and retained state

The validated `[machines.msx]` / `[machines.dos]` flags travel with the Runtime
atomic publication. Owner entrypoints consult the activity once before work.
Off or unavailable configuration refuses new mutations; accepted work finishes.
Reads, checkpoint saving, eject and releasing DOS control remain available.
Inventory activity and publication are independent readings.

The MSX spectator distinguishes an explicit activity refusal from a lost
mutation response. A refused tick retains pixels and switches to activity/live
reads; observing On allows the next cadence to advance again. Unknown mutation
outcomes still require explicit observation. Refused keyboard input remains
visible as a notice.

## Focused owner verification

Run from the checkout with OCaml 5.5.1 and the packages named in the script:

```sh
python3 docs/evidence/2026-10-05-machine-lane-activity/check-owners.py .
```

`owner-provenance.json` pins each source, compiler/package lookup, command and
exit code. `owners.txt` is the completed output (trailing whitespace normalized).
The harness compiles the actual sources in scratch space; it does not provide
substitute implementations for product dependencies.

- Four MSX/configuration scenarios compiled, linked and ran against the installed
  machine core: strict settings/defaults, Off preserving machine/checkpoint state
  while refusing mutations, unavailable configuration allowing inspection, and
  an already admitted press finishing key release after activity turns Off.
- The actual DOS owner and its three new scenarios compiled against the actual
  checkpoint interface and installed DOS core. They were **not linked or run**;
  the checkpoint implementation requires a broader native dependency closure.
- Existing Runtime configuration publication checks were extended for Machines
  across boot, preview/save, commit durability uncertainty and snapshot restore.
  These, server serialization, DOS tool classification and the migrated native
  fixtures are source tests awaiting native execution. The MCP seat-profile
  fixtures use a local DOS module alias; independent review caught these two
  additional lifecycle sites and their activity setup/cleanup was repaired.

The first compile exposed a private DOS activity-feed name shadowing the new
public activity function; the private feed was renamed. The first link needed
`digestif.c` rather than its interface-only package. The initial MSX press test
wrongly treated `step_frames` as extra frames; it was corrected to the owner's
existing total-frame contract. Initial logs/provenance remain alongside the
final successful run. Findlib reports duplicate Digestif interface directories;
the final compiler/link/execution commands all exit zero.

## Direct consumer coverage and limits

| Changed contract | Direct consumers | Evidence |
| --- | --- | --- |
| Machines TOML namespace/configuration | Runtime schema, parse, materialize and atomic publication | Actual leaf parser executed; Runtime source test extended, not run |
| MSX/DOS typed activity refusal | Tools, MSX HTTP, DOS Play/controller | Actual owners typechecked; MSX executed; native route/tool tests not run |
| Required inventory activity | Server serializer, TUI decoder/display, Web decoder/component | [Readout checks](../../../dashboard/evidence/2026-10-05-machine-lane-activity/README.md) |

`syntax.json` records parsing of all changed OCaml sources with 5.5.1. It does
not establish full type compatibility or linking.

[MSX tick response evidence](../2026-10-05-msx-tick-activity/README.md) records six
actual tick-decoder/policy checks with OCaml 5.5.1 and the native route scenarios
that were authored but not executed. Source review also caught an authority-change
branch that could release the unknown-outcome guard; the final handler derives
terminal policy before filtering stale presentation.

Readout evidence separately records 16 isolated TUI decoder/display checks,
82 Web checks, TypeScript/lint and seven Chromium synthetic-HTTP observations.
These do not establish actual Runtime publication or server integration.

Dedicated TUI/Web machine editors remain later work. This unit is not the full
F3 feature's completion. No full native build, Dune, PTY, CI, deployment or main
integration was performed. Review and PR identity are recorded separately in the
local progress report after the candidate is frozen.
