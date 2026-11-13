# Package input and display contracts

## Primary navigation category

A package may declare one top-level `ui_category` in its `lane.toml`:

```toml
ui_category = "memory_judgment"
```

The closed values are `memory_judgment`, `browser`, `external_communications`,
`voice_media`, `execution_environment` and `analysis`. Omission means unclassified.
Unknown values, padded strings, other types and duplicate declarations are errors;
they are never guessed from package IDs, titles, tool names or model routes.
Packages with several roles select one primary category and keep their original
contributions, capabilities and outputs independently.

Category is navigation metadata. It grants no capability, execution, credential,
Required-service exemption or permission to switch a service Off. Browser engines
and transports remain details of a browser service; exact-output model routes
remain bindings of individual named outputs. They are not sibling package roles.

Catalog and preview responses contain the current manifest's optional category.
Inspect's `configuration.declarations[].ui_category` describes the last valid
declaration reading. Its worker-input revision excludes only this new category,
so editing it preserves the same live incarnation, tool owner and original
request authority. Each worker's `package.ui_category` remains its immutable
original declaration, including in retained history. Current-installation views
use the matching current declaration's category; unreadable or unresolved
declarations must not borrow an old worker's category. Missing category fields
are omitted from JSON, while an explicitly invalid value is refused.
The common Lane inventory also carries the category separately on valid
declarations and on original instances; its typed TUI decoder preserves both.
An invalid, absent or unobserved declaration stays in that original state,
even when its previous worker has a category.

This metadata contract does not itself implement TUI or Dashboard grouping.

## Input and reading contracts

An optional `[interface]` table in `lane.toml` declares JSON text in
`binding_schema` and `presentation`. The binding schema uses the same enforceable
JSON Schema subset as Lane actions. It must describe an object, including the
package's `sources` connections. Both declaration saves and direct attach validate
the binding before starting a worker. Unsupported schema keywords are errors.

```toml
[interface]
presentation = '''{
  "description": "Compare retained project observations",
  "readings": [
    {"lane_id":"quality", "path":["missing"], "label":"Missing records",
     "unit":"records", "format":"number"}
  ]
}'''
```

Reading paths address fields in a row, in declared display order. `lane_id` is
package-local; the host resolves it within the owning instance. The same order
places the lanes: the TUI Results view opens on the lane the first reading
names, and Left/Right move in the order readings first name lanes. Lanes no
reading names follow, by name. Reordering readings therefore changes which lane
Results opens on. Supported formats
are `text`, `number`, `boolean`, and `json`. Missing or wrongly typed values are
shown as unavailable, never zero or success. Original fields and evidence remain
available in technical detail. Display metadata grants no action authority.

`presentation.actions` declares row actions. Each entry is
`{"lane_id", "label", "fixed", "from_row"}` and offers one lane action on the
rows of `lane_id`: `fixed` members carry the package's values, `from_row` maps
members to paths in the row's fields, and the operator fills the members left.
The filled action goes through the same `lane_act` validation and authority, so
a row action is a shorter way to write an action, not a new permission. At load
a row action must read at least one member from the row, may not name a member
in both `fixed` and `from_row`, keeps its label unique within its lane, needs
`world.actions.tool`, and must name a selected output lane unless the package
emits every lane. Once the worker advertises its action schema, the host judges
each row action and publishes the verdicts in order as the instance's
`row_actions`. The action must be one closed object, or an object `oneOf` of
closed objects of which exactly one declares every fixed and row member and
accepts every fixed value. A package without row actions keeps its declaration
revision.

The Dashboard renders declared readings in the observation list and selected
observation detail, scoped to the exact owning instance. Package descriptions
appear beside the installation, and the package input/display contracts remain
inspectable in a separate detail. A number `0` and boolean `false` are real
readings; missing or incorrectly typed values are explicitly unavailable.
Integer number readings outside JavaScript’s exact range are also unavailable
rather than displayed as rounded counts.
Multiline text is escaped as text, while original fields and evidence stay in
the observation details.

The common package JSON includes both contracts. A display-only package can omit
`binding_schema`; a package without display metadata uses the generic row view.
The shipped `dos-world`, `value-difference` and `output-statistics` packages
declare one, so their checked-in declarations are validated by
`test_lane_addon_config` and a guided installer can build their bindings from
the schema instead of a hand-written TOML file.
The current contract does not claim that an image is installed or that a source
has supplied complete observations. Those remain separate installation and
coverage states.

`interface.refresh_policy` optionally declares `every_hint` (the default) or
`source_changes`. The latter opts a package into suppression of equal automatic
file captures; it never suppresses explicit observation requests. See
[source refresh semantics](lane-addon-refresh.md) for source interests and the
limits of this policy.
