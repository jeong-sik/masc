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
