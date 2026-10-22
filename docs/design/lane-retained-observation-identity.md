# Retained observation identity and current model routes

`Lane_run_identity.t` names original logical work in retained records. It does
not name an installed Addon, select a model, or grant permission to execute.
`Standalone_lane.t` names the currently configurable builtin routes.
`Standalone_lane.run_identity` maps a current route to its observation identity;
there is no inverse configuration capability.

The observation vocabulary owns the wire IDs and labels. The Exact registry
maps its closed set of record kinds to this vocabulary and explicitly refuses
Verifier and Browser Stagehand registrations on replay. Verifier retains its
separate Task/Goal records. Current configuration parsing still enumerates only
`Standalone_lane.all`, independently of which identities history accepts.

The run endpoint's filters, registry replay, and TUI list/detail/async messages
use observation identities. Overview configuration rows join observations
through the directional mapping. Original run IDs, input/output bytes, duration
availability, provenance, and ownership do not change. History reads never need
to resolve a current model route.

This separation precedes Curator builtin retirement. The builtin Curator route
and overview row are still present in this layer. Removing them requires the
actual Addon model projection and an accessible original-observation history
entry in both UIs. An Addon's configuration scope `run_id` is not the Curator
Owner request's observation `run_id`; a UI must not infer one from the other.

The focused real-file scenario reopens persisted Curator records and passes
their filtered page and exact detail through the server projection and TUI
decoder, preserving measured and unmeasured durations. Parser checks establish
syntax only. Compiled tests, an installed executable, and visible UI use are
separate evidence.

## Dashboard navigation

The Dashboard uses `LaneNavigationTarget.kind=run_history` with the retained
`LaneRunIdentity` vocabulary. `kind=exact` continues to name current builtin
settings. A configuration row's diagnostics link converts to a history target
at navigation; it does not make a history target usable by the Runtime editor.
The existing workspace authority check applies to either target.

Internal Agents reads the selected history source even if the current
configuration matrix is absent or unavailable. Verifier still reads Task/Goal
registries, and Stagehand explicitly reports that it retains no history. A
missing current configuration row is not an error in a valid history selection.
The original record's run ID and detail endpoint are unchanged; the history
filter does not derive a run ID from an Addon installation scope.

Refresh still uses the existing combined `Promise.allSettled` barrier. This
separates history availability from configuration availability; it does not
make a slow or pending unrelated read stop delaying the refresh.

Focused Dashboard verification executes the real router and components with
mocked API responses, plus the strict API decoder suite. It is not an actual
server/browser session. The initial eight internal-agents fixture failures
were reproduced against isolated base `689369c0bc938c1056cf6a21dd0c1b67d7d5f692`:
terminal rows omitted required `completion_origin` and `usage`. Fixtures now
state producer origin and absent usage; running rows omit both. The production
parser remains strict. The four selected suites pass 91 cases; TypeScript and
changed-file lint pass. That Dashboard source does not implement TUI history
discovery or Curator builtin retirement.

## TUI navigation

The command palette offers each `Lane_run_identity` as a retained-history
destination without reading current configuration rows or installed Addons.
Selection enters the existing Lanes run list and starts the existing filtered
read, with workspace authority, generation and original run detail unchanged.
The normal inventory read is still launched independently on surface navigation;
its success is not a prerequisite for the history result.

History entry closes the transient slot editor, runtime picker and editor
notice even when navigation stays on Lanes. Otherwise their key handlers could
mutate an invisible original model configuration. Outstanding writes, retained
receipts and configuration drafts keep their original owners. The state
transition fixture covers idle, posting and receipt/read-back phases and checks
that a hidden slot deletion can no longer be planned. The palette fixture checks
typed Curator/Verifier destinations with no configuration or inventory reading.
The TUI history parent `a0d3f3197fb88005bd9f920ded9d915d2c8dccea` subsequently
completed its 65-case selected execution and a separate matching native
TUI/server build with 29 related cases. Earlier identity builds are not reused
as evidence for this navigation delta. Interactive TUI use, installation and
Curator builtin retirement remain separate work.

## Installation model observations

The common server inventory already emits each valid declaration's required
`exact_outputs`, including declared versus table-only provenance and the current
configuration result. The Dashboard decoder now preserves this contract and
rejects missing outputs, duplicate output names and unknown provenance. All
Lanes shows these readings under the actual installation ID, independently of
worker presence or package activity. A table-only output is not offered as an
executable package capability.

Curator prompt guidance names the real per-installation `classification` and
`briefing` Addon routes instead of the builtin history ID's model table. The
generic Runtime configuration link opens the existing editor; it does not
resolve a current Curator installation or fabricate an original observation ID.

[The source-bound execution receipt](../evidence/2026-10-22-addon-model-observation/README.md)
records the reproduced decoder loss, selected 37-case Dashboard execution,
TypeScript/lint and an actual Chromium component rendering with a synthetic API.
It also records the separate TUI parent's selected 65-case CI and native build.
These observations
do not prove actual provider execution, the full Dashboard lifecycle, installation
or removal of the builtin Curator route, which remain subsequent work.

## Executed identity source

Exact source `689369c0bc938c1056cf6a21dd0c1b67d7d5f692` completed
[targeted CI](https://github.com/jeong-sik/masc/actions/runs/39710832458) with
five suites and 453 passing cases, including real-file Curator replay through
the server/TUI decoders. The same source completed
[native macOS CI](https://github.com/jeong-sik/masc/actions/runs/39710835575),
building the TUI, key-reference generator and server plus two suites with 29
passing cases. The artifact receipt's source and TUI/server/key-reference
byte hashes were checked independently.

[The execution receipt](../evidence/2026-10-22-curator-original-delivery/retained-identity-execution.json)
records source versus workflow identities, exact targets, log hashes and limits.
These runs execute the identity layer, not the later Dashboard navigation
delta. Its focused 91 cases and TypeScript/lint results are separate local
evidence. No installed-runtime or visible-UI verification is claimed.
