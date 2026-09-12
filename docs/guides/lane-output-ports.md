# Select a package's named output through TOML

A package can publish named outputs as part of its existing `lane.toml`. Each
port selects exact package-local Lane IDs from the latest completed output:

```toml
[world.outputs.frames]
lanes = ["msx/frame"]

[world.outputs.state]
lanes = ["msx/state"]
```

An installation in the same run selects the public port by name:

```toml
[[binding.sources]]
source_id = "observed-frames"
kind = "lane_output"
installation_id = "msx-frames"
selection = "latest_completed"
output_id = "frames"
```

The host matches `instance_id + "/" + local_lane_id` exactly. Similar names,
longer paths and rows from other instances are not part of that selection. Port
and Lane names must be non-blank; duplicate ports, duplicate Lane IDs, empty
Lane lists, unknown port settings and conflicting selections are rejected.

Packages whose output Lane IDs depend on their inputs can publish a whole-output
port explicitly. The generic statistics package uses this form:

```toml
[world.outputs.statistics]
all_lanes = true
```

`lanes` and `all_lanes = true` are mutually exclusive. Omitting `output_id` from
a source still requests the whole latest completed output. Supplying an unknown
name makes that source unavailable; it never falls back to the whole output.
A known port with zero matching rows supplies an empty completed output, which
is distinct from unavailable input.

The producer capture includes its applied port declarations, actual instance,
configuration and package revisions, run and completed sequence together. The
source's `producer` coordinates retain `output_id` (`null` for a whole-output
request), `output_selection`, and `coverage_scope = "whole_producer"`. The
source observation ID keeps identifying the original completed output. The
binding's source ID and retained selection distinguish views of that output.

The evidence blob freezes those coordinates and the selected rows with their
original IDs, clocks, actors and evidence references. A later mapping edit
changes the semantic configuration revision even if the package author's
revision string stays unchanged. Previous blobs continue describing the old
selection.

Coverage remains conservative: the selected output carries **all producer
coverage**, including failures in inputs used by other ports. Selecting a port
does not prove independent completeness for that port, synchronize clocks, or
turn row counts into elapsed frames or game progress. The generic Dashboard
lists the applied public ports and their selections without package-specific
components.

The shipped MSX observer publishes `frames` (`msx/frame`), DOS world publishes
`guest` (`dos/guest`), and output-statistics publishes `statistics` (all lanes).
For the DOS installation in `addons/dos-world/install.toml`, a statistics
installation uses the same `run_id = "dos-demo"` and this source:

```toml
[[binding.sources]]
source_id = "dos-guest"
kind = "lane_output"
installation_id = "dos-demo"
selection = "latest_completed"
output_id = "guest"
```

The [MSX statistics declaration](../examples/lane-addons/output-statistics.toml)
is a complete installation example. The existing worker packet and row wire
formats are unchanged; the host selects rows before passing observations to the
consumer. Package scripts, Skills and worker ownership continue using their
existing contracts.
