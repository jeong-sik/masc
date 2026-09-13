# Package input and display contracts

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
package-local; the host resolves it within the owning instance. Supported formats
are `text`, `number`, `boolean`, and `json`. Missing or wrongly typed values are
shown as unavailable, never zero or success. Original fields and evidence remain
available in technical detail. Display metadata grants no action authority.

The common package JSON includes both contracts. A display-only package can omit
`binding_schema`; a package without display metadata uses the generic row view.
The current contract does not claim that an image is installed or that a source
has supplied complete observations. Those remain separate installation and
coverage states.

`interface.refresh_policy` optionally declares `every_hint` (the default) or
`source_changes`. The latter opts a package into suppression of equal automatic
file captures; it never suppresses explicit observation requests. See
[source refresh semantics](lane-addon-refresh.md) for source interests and the
limits of this policy.
