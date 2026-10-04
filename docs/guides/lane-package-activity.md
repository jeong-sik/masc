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

The reconciler requires a complete declaration and retained-binding inventory
before applying changes. An unrelated unreadable file can therefore defer a
valid off request; the configuration reports that cleanup awaits a complete
reading. The observed worker remains visible. Malformed or duplicate declarations
keep the last applied worker; invalid input is never interpreted as off.

A disabled declaration still preserves its document privacy owner. Metadata
update failure is reported separately and does not prevent cleanup once the
inventory is complete. Disabling does not require an available package image or
an available upstream connection. The declaration itself must be valid, including
its manifest and binding schema.

This control covers declared packages. Exact, Browser, machine and manual
attachment lifecycle controls have separate owners and remain separate work.
