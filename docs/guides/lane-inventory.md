# Lane inventory

`GET /api/v1/lanes` is an operator (`CanAdmin`) read of built-in Lane kinds and
package installations. It does not change configuration or enable/disable lanes.
The existing standalone and Lane Add-on endpoints remain available for detail
and management.

The response has `schema: "masc.lane-inventory/v1"`, a numeric Unix-second
`observed_at`, `rows`, `package_read`, and `exact_snapshot`. The latter is the
complete existing standalone snapshot, including its observed time, source count
and truncation fields. Admission is captured once for both common rows and that
snapshot; neither is decoded back from the other's JSON. Different families are
read independently, so this is not an atomic cross-family transaction.

Each row carries `id`, `label`, `purpose`, a typed `selection`, and `state`.
All built-in kinds come from `Lane_id.all_of_builtin`, rather than a separately
maintained list.

| Selection kind | Identity fields | Existing management destination |
| --- | --- | --- |
| `exact` | `lane_id` | Standalone lane detail, slot editor and retained runs |
| `browser` | `lane` (`live`, `automation`, `stagehand`) | That Browser backend |
| `machine` | `machine` (`msx`, `dos`) | That shared machine |
| `declaration` | `source_path` | The actual installation file, including invalid TOML |
| `manual_instance` | `instance_id`, `incarnation` | That exact manual Add-on instance |

Built-in row IDs use `Lane_id.to_wire`. Declaration row IDs are
`declaration/<source_path>`; manual row IDs are `instance/<instance_id>`.
Clients use `selection` for navigation, not heuristics over labels or IDs.

| State kind | Fields and meaning |
| --- | --- |
| `exact` | `configuration`: `configured` with `admitted_slots`, `cli_slots`, `declared_slots`, `declared_cli_slots`, `dropped_slots`, nullable `admission_error`; or `unconfigured`/`unavailable` with `detail` |
| `browser_clients` | `connected_clients`, counted using the existing connection deadline without pruning clients or settling requests |
| `browser_executor` | `registered`; registration does not prove a child process or browser session is alive |
| `machine` | `publication`: `no_screen`, `stable` or `running`, from the owner's Atomic publication only |
| `package` | Nullable `declaration` plus `instances`; null is a manual attachment, not a failed declaration read |

An exact registry that cannot be read, including a publication reservation, is
`unavailable`; it is not interpreted as disabled. Machine reads do not acquire
the machine lock, capture pixels or infer a controller/program. Browser reads
never invoke an executor or open a session.

Package declaration states are:

- `valid`: `enabled` (desired activity), `installation_id`, `run_id`, `package_id`, `title`, `desired_revision`.
- `invalid`: `messages` from the configuration owner, including duplicate IDs.
- `absent`: a complete inventory does not contain a still-owned file.
- `unobserved`: an incomplete read cannot establish whether the file is present.

Package `instances` carry `instance_id`, `incarnation`, `run_id`, `package_id`,
`title`, `package_revision`, `presence` (`live` or `retained`), the existing
`phase` object, and nullable `applied_revision`. A retained phase does not prove
that an old worker still runs. Unconfirmed cleanup remains visible. Confirmed
`detached` instances are history, excluded from active counts; a declared file
still keeps its row. When a complete read proves a file absent and all its
workers are detached, its active row disappears. Partial reads preserve the
known declaration path. Detached manual attachments likewise remain in the
existing Add-on history rather than crowding this active inventory.

`package_read` contains the resolved `directory`, `owner_present`, `complete`
and `issues` (`source_path`, `message`). It reads declaration files even before
the first reconcile. `owner_present: false` means this process has no package
manager yet; retained files may still exist. Individual unreadable binding files
produce issues while readable siblings remain visible. `complete` describes
read completeness, not configuration validity or successful installation.

Declaration and retained metadata filesystem reads are offloaded. This endpoint
does not create a manager/store, write or sync files, start/stop workers, settle
Browser waiters, or reconcile declarations. It is a navigation and observation
surface; actions still use their existing owners and authorization contracts.

A package declaration's `enabled` is separate from its payload revision and
worker presence. Off with a live or unresolved retained worker is an off request,
not proof of cleanup. See [package activity](lane-package-activity.md) for the
configuration-preserving control and incomplete-read behavior.
