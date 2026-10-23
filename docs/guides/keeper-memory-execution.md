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
| `configuration_unreadable`, `invalid_setting` | Configuration could not be interpreted; this is not an empty installation set. |
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

## Prepare package version 0.2.3

Use the repository version containing
[`addons/keeper-librarian/lane.toml`](../../addons/keeper-librarian/lane.toml),
its `server.py` and both bundled schemas. Prepare this image through the package
image workflow, then load it into the container engine used by MASC:

```sh
docker build -f addons/keeper-librarian/Dockerfile -t masc-lane-keeper-librarian:0.2.3 addons
```

The build context is `addons`, because the image contains the shared
`protocol.py` and `exact_worker.py`. The runtime mounts the package directory.
Saving a declaration does not build or download an image. Existing installations with worker record v1 require the
[Exact worker state hard cut](EXACT-WORKER-STATE-HARD-CUT.md) before this version;
do not erase unresolved originals or reuse old worker state. A first installation
uses the host-created empty state under its declared owner identity. For an alternate
configured engine, import that same image into that engine before attaching.

Place the complete package in an operator-managed, versioned location readable
by MASC. For example, `<base-path>/.masc/packages/keeper-librarian-0.2.3/` works
with this declaration when the resolved config root is
`<base-path>/.masc/config`:

```toml
id = "keeper-librarian"
run_id = "keeper-librarian"
enabled = true
manifest_path = "../../packages/keeper-librarian-0.2.3/lane.toml"

[binding]
sources = []
```

Create it through `masc_lane_declaration_save` with `mode="create"`,
`file_name="keeper-librarian.toml"` and the complete `source_text`. An existing
installation is edited with `mode="save"` and its freshly read
`expected_source_revision`. Preserve the existing installation ID, run ID,
manifest location and persistent state when restoring an existing installation.
Resolve a relative manifest from the actual declaration directory if
`MASC_CONFIG_DIR` selects another root. Do not replace a conflicting declaration
or manual attachment by inventing a second installation.

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
official-client runtime ID. An accepted CLI ID is still checked at execution;
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
