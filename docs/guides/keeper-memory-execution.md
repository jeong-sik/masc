# Keeper Librarian execution dependencies

Automatic explicit-memory admission and completed-history derivation use the
`keeper-librarian` Lane Add-on. The host calls `admit_memory` for the `admission`
exact output and `derive_memory` for `durable`. The package proposes decisions;
source consumption, absorption, Memory commits and acknowledgements remain with
their existing host owners. The built-in `librarian_exact` lane still has other
consumers and does not supply these two Add-on routes.

The Add-on remains optional operator configuration. Missing installation,
explicit Off, an unavailable worker and a provider refusal are different states.
None of them creates a global Keeper turn gate or deletes pending input.

## Read the dependency state

`/health?full=1` includes the cached `keeper_memory_execution` section.
`/api/v1/dashboard/keeper-memory-health` includes the same observation as `execution`.
Deployment preflight prints `memory execution preflight` after it has accepted
the runtime registry; this diagnostic does not enable an installation or refuse
deployment because an optional Add-on is absent.

Each operation names its tool, output, installation and exact route table.

| State | Meaning |
| --- | --- |
| `addon_unattached` | No valid declaration for this package exists. |
| `addon_off`, `disabled`, `output_not_selected` | The operator disabled the installation, Memory Librarian, output or route. No automatic repair is requested. |
| `configuration_unreadable`, `invalid_setting` | Configuration could not be interpreted; this is not an empty installation set. For `configuration_unreadable`, each `detail` entry names the declaration's file inside the Lane directory (`declaration_file`), or says the directory itself could not be read (`source: lane_directory`). The reader's message and the full path stay in the authenticated Lane inventory. |
| `multiple_installations`, `export_conflict`, `wrong_package`, `manual_installation` | There is no unique declared owner for the required tool. |
| `route_unavailable` | The exact installation/output route is missing, off, has no admitted slots, or its registry is unavailable; `detail.reason` distinguishes them. |
| `configuration_admitted` | Preflight found the package contract and admitted routes. No worker or provider was exercised. |
| `worker_not_attached`, `worker_unready`, `declaration_not_applied` | A declaration exists but its matching worker is absent, starting, stopping, failed, or on another revision. |
| `serving` | The matching live worker exports the tool. This does not prove a provider call or Memory commit. |
| `provider_unavailable`, `provider_auth_refused`, `provider_configuration_refused` | An original request remained pending at the last completed host cycle with that typed provider cause. |
| `request_waiting`, `host_cycle_unavailable` | The last host cycle retained a waiting request or could not complete its host boundary. |

`last_cycle_at` timestamps the observation, not a deadline. Pending observations
retain original request IDs. Provider bodies, host failure details, configuration
parser messages and source paths remain in the authenticated Lane inventory.
`provider_execution` always says
`not_proven_by_availability`; inspect the original result and host commit receipt
to establish completed work. Full health aggregates actionable missing
dependencies as degraded while intentional Off remains explicit in each row.

## Install the package

This masc carries the `keeper-librarian` package: its `lane.toml`, `server.py`,
both schemas and its `Dockerfile`, and the shared `protocol.py` and
`exact_worker.py` its image is built from
([RFC](../rfc/RFC-server-carries-its-exact-worker-packages.md) 3.1).
`masc exact-addon-setup` writes the package to
`<base-path>/.masc/packages/keeper-librarian-<revision>/` and builds the image
its manifest names, labeled with this masc's digest of those image inputs:

```sh
masc exact-addon-setup --declared --base-path <base-path>
```

`--declared` installs only the packages the workspace's declarations name with
`package`; without it the command installs every package this masc carries.
`scripts/install-local-build.sh` runs it without `--declared` on every install,
and `scripts/install.sh` runs it with `--declared`. Docker must be installed.
Without Docker the package is reported as not installed, and the install goes
on.

Declare the installation by the package's name. The server finds the package
under the base path, wherever the config root is:

```toml
id = "keeper-librarian"
run_id = "keeper-librarian"
enabled = true
package = "keeper-librarian"

[binding]
sources = []
```

Create it through `masc_lane_declaration_save` with `mode="create"`,
`file_name="keeper-librarian.toml"` and the complete `source_text`. An existing
installation is edited with `mode="save"` and its freshly read
`expected_source_revision`. Preserve the existing installation ID, run ID and
persistent state when restoring an existing installation. Do not replace a
conflicting declaration or manual attachment by inventing a second installation.

On a first installation the declaration does not exist when the installer
runs, so run the command above once after saving it. Until then the server
refuses the declaration, and its message names the command. The worker starts
only from an image whose `masc.lane.carried.digest` label equals this masc's
digest, read from Docker, so a carried package runs on Docker.

Installations that still contain worker record v1 require the
[Exact worker state hard cut](EXACT-WORKER-STATE-HARD-CUT.md); do not erase
unresolved originals or attach a v1 state directory to this worker. Existing v2
state remains usable as described below. A first installation uses the
host-created empty state under its declared owner identity.

### Pin a package by path

An operator who manages the package folder declares `manifest_path` instead of
`package`, for example
`manifest_path = "../../packages/keeper-librarian-0.2.8/lane.toml"` relative to
the declaration's directory. Place the complete package in a versioned location
readable by MASC, and build or load its image from the same source revision:

```sh
docker build -f addons/keeper-librarian/Dockerfile -t masc-lane-keeper-librarian:0.2.8 addons
```

The build context is `addons`, because the image contains the shared
`protocol.py` and `exact_worker.py`; the runtime mounts the package directory.
The server reads no image label for such a declaration, so another container
engine can run the image once it is imported there. The manifest must name the
Exact protocol the server speaks (below). Select a new versioned package through
that declaration rather than editing a running package in place.

### Upgrade an existing installation

Version 0.2.8 names the Exact protocol it was written for in
`[world] exact_protocol = 1`. A server that knows the key attaches a package
with exact outputs only when its manifest names the protocol that server speaks,
and its refusal names both. It refuses 0.2.7 and every earlier manifest. A server
that does not know the key refuses the 0.2.8 manifest. No server runs a worker
written for another protocol
([RFC](../rfc/RFC-server-carries-its-exact-worker-packages.md) 3.4).

Since 0.2.7 the package lists its waiting requests in pages that carry nothing but the
requests: in rising request id order above the `after` cursor, as many as fit
one reply frame. It admits a request when the page carrying only that request
fits the frame. Other waiting requests no longer hold a new one back, and every
waiting request, including one an earlier version kept, fits a page of its own
([RFC](../rfc/RFC-librarian-read-waits-and-shrinks-no-further-than-the-refusal-says.md)
3.1 and 4.5). Its manifest declares `[world] host_request_pages = true`, which a
server that does not know the key refuses. Version 0.2.6 named the next page
with `next` instead. That key made a page 81 bytes longer than the page an
earlier version measured at admission, so a record kept within those 81 bytes
of the frame could not be listed while another request waited behind it.

A `package` declaration needs no edit. Install the new masc, whose installer
writes the new revision's folder and image beside the old ones, then restart
the server. The updated server resolves the same declaration to its own
revision. Until it restarts, the running server starts workers only from the
image its own setup built
([RFC](../rfc/RFC-server-carries-its-exact-worker-packages.md) 3.3).

To move a `manifest_path` installation to the carried package, install the new
masc and stop the server. Replace `manifest_path` with
`package = "keeper-librarian"`, run
`masc exact-addon-setup --declared --base-path <base-path>`, then start the
updated server, which reads the
[declaration file](lane-declaration-editor.md) as it starts. This order loses
nothing from any earlier version.

A version before 0.2.6 answers a submission with `capacity_wait` when its
waiting requests fill the frame. A server that includes
[#52731](https://github.com/jeong-sik/masc/pull/52731) and does not know
`exact_protocol` still attaches such a version and no longer reads that answer.
The original stays `Dispatch_pending`, its worker has no record of it, and
nothing sends it again; selecting 0.2.8 afterwards leaves it among the originals
below that still wait.

Since 0.2.5 the package accepts the ending the host delivers for a request whose
declaration was replaced: `{"status":"not_allowed","cause":"declaration_replaced"}`
([#52621](https://github.com/jeong-sik/masc/pull/52621),
[#52622](https://github.com/jeong-sik/masc/pull/52622)). The `exact_worker.py` in an installed 0.2.4 image answers
that delivery with an error and keeps the request pending. Selecting 0.2.8 is
itself a declaration change, and its replacement worker is the 0.2.8 worker, so
that worker receives those endings. A declaration change that keeps the 0.2.4
image, such as a new `run_id`, does not deliver them.

Version 0.2.4 gives the compact `refuse_body` command introduced in
[#52504](https://github.com/jeong-sik/masc/pull/52504) its own package revision and
image tag. An installed 0.2.3 image or mounted `server.py` from before that change
does not accept the command. For a `manifest_path` declaration, updating the
MASC executables does not build the Add-on image, copy its operator-managed
package or change its declaration.

For such a declaration, build or load the image and copy the complete package
from the same source revision. The image supplies `protocol.py` and `exact_worker.py`; the mounted
package supplies `server.py` and both schemas. Keep the old package and image
unchanged. Worker record version 2 is unchanged, so this update alone does not
require an empty volume. The separate v1 record hard cut linked above applies
only to installations that still have those records.

A package path, revision or image change also changes the semantic configuration
revision. Preserving the volume does not reauthorize a captured original under
the new configuration. A known unstarted declaration ending leaves the
original input unread. A history Cut can also retain a separate ending after
its actual host result, execution proof and ready same-owner replacement are
verified. A later pass reads the complete unread range under a new ID. The
old provider call may have finished; a new ID alone is not proof that effects
cannot repeat. Preserve the actual result, ending, source guards and receipts.

An ending already stored survives rollback. Linked work keeps its original
source and fence, publishes a complete child intent, and recovers that same
child after interruption. An ending or child publication does not complete
Memory publication or acknowledge its source.

Known answers continue through their actual Gate under the same owner. Unknown
floor calls, raised attempts, missing dispatch records and unready or different
owners do not gain replay authority from a configuration edit. Same-binding
history Cut recovery has a separate fenced continuation; it is not a declaration
replacement. Inspect retained originals, worker records, Exact outcomes and
proofs before switching. Follow
[the original-inventory requirements](EXACT-WORKER-STATE-HARD-CUT.md#deploy-with-a-stopped-writer).

An approved fresh-state operation stops writers and holds the workspace lease
before backing up and isolating the selected Librarian owner/body, history fence
and resolution scopes and their matching worker requests. Preserve Memory,
admission queues, raw conversations, receipts, all read cursors, Exact records
and proofs, settled archives and unrelated worker records. Do not clear the
whole volume. Run the candidate's
[stored-state audit](DURABLE-STORE-HARD-CUT.md) before starting that candidate.

For an ordinary update with no unresolved original chains, save the new manifest
path with a fresh declaration revision through the
[declaration API](lane-declaration-editor.md#keeper와-공통-api). Normal
reconciliation removes the old worker before attaching the replacement. Verify
the applied revision, actual image ID, the same owned `/state` volume, and live
`tools/list` advertising `refuse_body` on both `admit_memory` and `derive_memory`.
Then check actual Memory receipts and source acknowledgements separately.

The optional top-level `max_exact_in_flight` is how many exact requests of this
installation the host runs side by side. It is an integer of 1 or more and
defaults to 1. This one installation receives every Keeper's Librarian request,
so with 1 a slow request holds the requests behind it. The key is outside the
declaration revision: changing it does not restart the worker and does not
strand waiting requests. Keep it below the smallest `max-concurrent` among the
accounts the installation's lanes pass through, or this installation alone can
hold every place of that account. A server build that does not know the key
refuses the declaration, so add it only when every server that reads the file
knows it, and remove it first when rolling back.

## Bind the two exact outputs

Read the authenticated `GET /api/v1/runtime/config/raw`. In its source, provide
both tables under the actual declaration ID:

```toml
[runtime.addon_exact_lanes.keeper-librarian.admission]
slots = ["<an admitted exact target from this deployment>"]

[runtime.addon_exact_lanes.keeper-librarian.durable]
slots = ["<an admitted exact target from this deployment>"]
```

Those slot strings are placeholders, not defaults. Choose current admitted
targets from the deployment's runtime configuration. An intentional
official-client fallback uses the existing `cli_slots` field and an enabled
official-client runtime ID. The binding of that runtime declares
`max-concurrent`, the number of client processes the lane may run at once;
without it the file does not load. An accepted CLI ID is still checked at execution;
route admission does not establish account quota, credentials or connectivity.
Keep the existing built-in `librarian_exact` route for its other consumers.

Preview the complete edited source with
`POST /api/v1/runtime/config/raw/preview` and `{ "source_text": "..." }`.
Save with `POST /api/v1/runtime/config/raw`, providing `source_text`,
`expected_source_revision` and `expected_source_path` from the read. Reread after
a conflict. The existing publication and declaration reconciliation flows apply
the configuration and wake their consumers; no manual worker Attach is needed.
Availability changes also wake persisted Keepers that could not capture a history
request while the Add-on was absent, even when they have no explicit-memory queue.
Each existing Memory lane checks its own unread input before doing any work.

## Verify recovery on the original input

When the complete continuity walk proves an input-size refusal and selects a
smaller source, it queues the next unit on the same serial Memory lane. A held
Keeper does not need another conversation turn to make that descent. A quota
refusal alone grants no retry; the whole walk's invalid-output veto still holds.

1. Inspect desired/applied declaration revision and the actual worker's lifecycle
   in Lane Add-ons. Verify both exported tools and the two exact-output routes.
2. Read full health and Keeper memory health. Require the matching installation
   and revision; `configuration_admitted` alone is insufficient.
3. Follow an existing pending admission original and an unread completed-history
   original through their existing owners. Verify the original request, provider
   result, host Memory commit receipt and queue acknowledgement/source frontier.
   A provider refusal must retain its original request and leave that frontier
   unchanged until its owner accepts a successful result.
4. After a restart, verify original IDs, applied revision and retained results
   again. Do not clear queues, rewrite cursor files, rebind originals to a new
   installation, or mark a Memory source consumed to obtain a green result.

Source tests cover these boundaries; local package tests alone do not establish
the deployed binary, installed image, provider access or live Memory progress.
