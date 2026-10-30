# Package Lane activity

An installation declaration may set a root-level boolean:

```toml
enabled = true
id = "observer"
run_id = "workspace"
manifest_path = "../packages/observer/lane.toml"

[binding]
sources = []
```

`enabled = false` requests cleanup of workers owned by this declaration. The
TOML, binding, package settings and retained observations remain. It does not
use the remove-configuration action and does not stop manual attachments of the
same package. Repeated reconciliation does not restart a disabled installation.
Re-enabling uses the existing attach path after prior cleanup is confirmed.
Cleanup errors stay visible and retry on the existing maintenance pulse.

The configuration reader first accepts this key: omission currently retains
enabled behavior. After this accepting binary is deployed, existing declarations
can be updated through the authenticated declaration API. Requiring the key is
a separate later change after operator settings have been updated; this change
does not make existing declarations fail at startup.

The payload revision describes package, identity and binding inputs. Changing
only `enabled` leaves it unchanged. File source revision changes with the bytes,
and the existing save API compares that revision before writing. Equal payload
revisions do not prove a worker is enabled, attached or cleaned up.

## TUI

Select a package declaration in Lanes and press Enter to inspect its TOML, or
open its draft with E in Add-ons. Space changes the local draft's activity flag;
`s` explicitly saves it. Comments, other settings, existing draft edits and the
source revision used for the next save remain. The switch edits the root key,
not a `binding.enabled` field. Invalid TOML or a nonboolean flag is reported and
the draft is retained for repair with E. A pending document request must finish
before Space changes the draft.

A save receipt reports file durability and pending reconciliation. `r` reads
worker state; close the draft with Esc to view the installation reading. The
common inventory and Dashboard show desired off separately from live, retained,
failed and cleanup-pending workers. A configured-off row remains discoverable.
The existing removal action still removes both configuration and worker; it is
not the activity control.

## Incomplete and rejected readings

The reconciler requires a complete declaration reading and a retained binding
directory it can list before applying changes. An unrelated unreadable
declaration file or a binding directory that cannot be listed can therefore
defer a valid off request; the configuration reports that cleanup awaits a
complete reading. The observed worker remains visible. Malformed or duplicate
declarations keep the last applied worker; invalid input is never interpreted
as off.

Each retained binding file is read on its own. A file that cannot be read
(it is not JSON, it records no read visibility or source access, or it has no
instance id or observation sequence) is reported in the configuration issues
with its path. The record is not rewritten, retired or cleaned up. What waits
depends on whose record it is:

- A record that names an installation holds back only that installation, and
  only while the record is not detached. A detached record holds no worker, so
  the installation applies. Persistent state is still checked against the
  runtime recorded in a detached record.
- A record whose configuration cannot be read could belong to any
  installation, so every enabled installation waits. A record with no
  configuration (a manual attach) holds none back.

A detached record that names an installation stays listed under the
configuration issues, and `slice` reports `complete: false` while any record
cannot be read. Moving the file away clears both. A detached record that still
states a valid `visibility` counts toward the installation's document owner. A
disabled installation does not change its document owner while a record that
may belong to it cannot be read; worker cleanup continues.

To release a held installation, repair the record by adding `visibility` and
`source_access`, or move the file away. Move only a detached file: the
container of a record that is not detached is cleaned up only through a
readable record.

Both fields are JSON objects with a `kind` field. Any other shape, an extra
field, or an empty keeper name makes the record unreadable again.

- `visibility` says who may read the instance: `{"kind": "shared"}`,
  `{"kind": "operator"}` or `{"kind": "keeper", "keeper": "<keeper name>"}`.
- `source_access` says whose authority reads the sources:
  `{"kind": "operator_configuration"}`,
  `{"kind": "keeper", "keeper": "<keeper name>"}` or
  `{"kind": "unauthenticated"}`.

Records written by v0.48.0 or earlier have neither field. List them with
`rg --files-without-match '"visibility"' <base-path>/.masc/lane-addons/bindings`
and the same command with `'"source_access"'`.

New Skill publications exclude workers that are stopping, including those whose
cleanup failed and will retry. A complete declaration reading also withdraws
Skills for an explicitly disabled owner. The worker row, retained observations,
evidence and document ownership remain available for cleanup and inspection;
already captured Skill readers keep their existing snapshot.

An ordinary observation failure does not withdraw a non-stopping worker's Skills.
An incomplete or unobserved declaration reading is not interpreted as off, and
active manual attachments keep their own Skill sources. Re-enabling an owner
does not republish its stopping incarnation; publication resumes for its
replacement after cleanup is confirmed.

A disabled declaration still preserves its document privacy owner. Metadata
update failure is reported separately and does not prevent cleanup once the
inventory is complete. Disabling does not require an available package image or
an available upstream connection. The declaration itself must be valid, including
its manifest and binding schema.

This control covers declared packages. Exact, Browser, machine and manual
attachment lifecycle controls have separate owners and remain separate work.
