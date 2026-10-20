# Browser execution as an optional Lane Add-on

The optional browser Add-on owns live command queues and Gecko automation.
The Gecko driver starts only with an attached browser Add-on and a configured,
enabled `[browser.automation]`. Stagehand and the Keeper live bridge still have
server startup paths; their owned-process and model-broker migration remains.

The operator selects two independent middleware boundaries:

- Tool contracts: validate commands before dispatch and successful structured
  replies after dispatch. Input and output hooks can be selected separately.
- Model generation: route a package's declared exact output through a scoped
  host broker. The host owns provider credentials and the current route registry.

These choices do not change verified caller authority, owner/incarnation checks,
upload leases, artifact publication or cleanup requirements. No middleware may
replay a browser input after a possibly dispatched call. Error and partial-effect
receipts remain distinct from successful contract validation.

## Implementation units

1. Selectable tool-contract middleware on the existing Add-on invocation path.
   This unit implements `validate_input` and `validate_output`, selected by
   package default or installation override. It uses the existing closed schema
   subset and rejects unsupported declarations before exporting tools. It does
   not perform LLM generation or move browser processes.
2. Separate MCP admission, discovery, calls and contract hooks from container
   control. The existing container owner delegates to this shared protocol;
   only Ready publishes immutable schema/tool/hook state. Failed or cancelled
   discovery cannot admit calls or recover on a late reply. This separation
   supplies no process-cleanup evidence by itself.
3. A host-process execution specification and lifecycle, separate from container
   resource/isolation declarations. Acquire installation/profile ownership before
   spawning. Persist exact process ownership and confirm cleanup before reuse.
   The live `Lane_addon_native_worker` component now uses the shared protocol
   without a container engine. Its host switch owns a foreground process group;
   cancelled startup or calls request cleanup, and exports are revoked before
   cleanup. Release requires an exited exact child and no observed live group
   members. Its required durable admission now comes from host-owned installation
   and resource slots. Browser-profile claim selection and cleanup of
   descendants that leave that group remain to be wired.
   Package declarations now separate `Container` from `Host_process`. A
   `runtime = "host_process"` manifest declares only `resources.max_reply_bytes`;
   image, CPU, memory and PID-limit fields are rejected. Shared protocol, source
   acquisition and sampling consume the execution-independent reply envelope.
   Container entrypoints refine the execution type before issuing engine
   commands. Runtime now selects native startup for host-process installations,
   records native admission before spawn, and derives its private claim slot from
   the installation identity. Lost handles reopen that exact admission; an orphan
   reservation is retired before a fresh incarnation can start. Resource and
   action receipts distinguish actual containers from native process identities.
   Native persistent storage and observation sampling are explicitly refused
   before admission until their host-directory and broker contracts are wired.
   The separate `Native_addon_lease` library and
   `masc-native-addon-launcher` executable provide durable slot admission. The
   host prepares private installation/resource directories before launch; the
   launcher takes stable kernel file leases, persists its process incarnation,
   and execs the payload without changing PID/group. Every instance ID has a
   durable, single-admission history: replacements never make old pending,
   retired or consumed launchers reusable. Existing empty/torn history is a
   refusal, not evidence of a new instance. Partial preparation requires a fresh
   ID. Retirement fences late launchers before identity-bound TERM; settlement
   requires no holder, no original process and no live foreground group.
   The live native worker now requires this admission and the installed launcher;
   its instance ID comes only from the admission. MCP discovery and observed
   kernel ownership must both succeed before tools become visible. A stop watcher
   signals the exact owned process independently of blocked gate I/O. Retirement
   and process cleanup join before release, and only an observed settled claim
   creates a retained receipt. A late validation cannot restore a retired worker.
   Reopening admission never recreates missing records or readmits an old ID.
   The namespace and its parent directories are synchronized before admission.
   The payload must preserve inherited lease descriptors; trusted native
   execution is not container isolation. This follows
   [POSIX exec/descriptor semantics](https://pubs.opengroup.org/onlinepubs/9799919799/functions/exec.html):
   closing a descriptor for a process-owned lease inode releases its locks.
4. A browser worker that owns WebExtension/BiDi command queues and owned Gecko/
   Chrome execution. Core admission and artifact/model brokers remain host edges;
   built-in browser execution and tool fallback are removed.
   `masc-browser-addon-worker` publishes `browser_command` and `lane_observe`
   on stdio. The command requires the private host-context control port and
   uses the installation's selected input/output hooks. A host-selected private Unix socket handles concurrent
   issue/poll/result/disconnect/snapshot requests. One canonical incarnation is
   admitted per process, and every request carries it. Live execution requires
   the already-selected client ID at dispatch. The exported tool can choose an
   available browser for unbound work; tab/document operations require their
   observed selection. There is no retry. Strict codecs retain existing document, viewport, frame and
   keyboard guards plus partial-effect result bodies. A nested service switch
   owns every accepted connection so idle clients cannot prevent shutdown.
   Retirement fences admission before disconnecting clients and cancelling waits.
   Socket paths must be absent inside a canonical, same-UID 0700 directory;
   stdin EOF and termination signals retire the owner. The host supplies the
   installation's native reply bound to this second transport as well.

   The `addons/browser` manifest selects the typed `service = "browser"` contract.
   Runtime reserves immutable socket allocation intent in native admission
   history before creating a directory, then records its acquired inode before
   payload spawn. Socket/UUID arguments come only from that host reservation.
   A ready service requires both the native owner and a private-socket snapshot.
   Failed readiness stops that original worker and confirms socket cleanup.
   Service handles retain the original connection token; detach or replacement
   cannot make an old handle callable. Post-dispatch Issue cancellation withdraws
   service admission and requests exact worker cleanup without replay. Transport
   exchanges use the existing host control timeout plus the requested wait.
   Empty repeat polls and snapshots do not create observation activity.
   Runtime observations read the private snapshot rather than the serialized
   MCP command connection, so a waiting command cannot hide its running phase.
   Both observation paths use the same typed row validation before publication.
   Normal stop, orphan recovery and slot replacement all require original socket
   cleanup after native settlement. Unknown contents or changed inodes remain
   unconfirmed; a successful historical release cannot delete a resurrected path.

   Native-host HTTP polls, results and disconnects now use the Add-on. The same
   served Workspace configuration selects both the authentication token and the
   execution owner. Atomic private-directory reservation and an immutable synced
   owner record bind each client ID and full identity to its original worker
   before the first forwarded poll. An incomplete reservation is never fresh;
   competing registrations cannot replace its owner. Successful reads confirm
   durability before forwarding. Late host poll/result retries never follow a
   replacement. Inventory absence alone is unavailable, not retirement. A live
   worker's failed observation requests the existing Observe wake and returns
   unavailable to new polls, preserving the connection until recovery. Results
   and disconnects still settle on that exact original connection during an
   observation failure; the host does not resend a result after a reached HTTP
   refusal. Only typed stopping/detached authority retires it.

   `Browser_addon_host` binds the typed browser service and the advertised
   command to the same exact owner. Its call uses ordinary host-mediated tool
   execution, retaining selected hooks, visibility and reserved-name checks.
   The Dashboard `/browser-lane/command` endpoint uses this path for a shared
   installation and supplies its authorized actor outside the request body.
   It returns the complete MCP receipt, including error/effect metadata.
   A retained host handle cannot follow a replacement export or socket.

   Existing Dashboard/TUI browser inventory, observations and input routes now
   use one retained host per workflow. Inventory observes that worker directly;
   read/scene/screenshot/interact/session/goto invoke its advertised tool with
   the selected input/output hooks. A two-command page read pins the first
   command's concrete connection and refuses changed connection receipts. Bound
   tab reads require the original client before discovery. The worker issues
   selection/connection identity from its admitted target; page fields cannot
   replace it. Pure projections share the existing partial-inventory, scene,
   navigation, document, viewport and tab checks. Failed tool replies retain
   their original MCP receipt and effect metadata. None of these paths retries
   input or falls back to builtin queues. Read/admin authorization stays at the
   HTTP boundary. Installed TUI and actual browser evidence remain separate.

   Gecko automation now runs inside the native browser worker. Its driver and
   optional binary are snapshotted by the host at attachment and retained in the
   original immutable cleanup descriptor. The host writes the worker spec inside
   its per-incarnation allocation. Profiles and staged downloads belong to that
   allocation; this unit accepts no shared or operator profile. Only a ready
   driver publishes an executor, session observer and document observer. Typed
   worker inventory carries registration and the actual open/closed/unknown
   session separately, so automatic browser selection can choose this backend.
   Core Gecko startup and PID/command-line-based orphan killing are removed.

   Normal detach sends private `Retire` before native termination: admission is
   revoked, the session is closed through an independent HTTP pool, and the
   exact driver child is reaped before an incarnation-bound cleanup receipt is
   persisted. Retirement waits for this completion rather than the quick
   control timeout or the native worker's short abort grace. Stdin EOF and
   termination signals also join backend cleanup. Interrupted session creation
   and lost session authority remain sticky; later success cannot erase them.
   The host additionally requires native group settlement, the original
   allocation inode, its unchanged spec and empty profile/download directory
   trees. It removes only known regular files, the socket and empty directories.
   Missing receipts, changed identity or downloaded bytes retain the allocation
   and refuse replacement. It does not infer escaped-descendant absence from
   a process-group check or force-delete profiles after a crash. Mozilla also
   documents interrupted-session profile retention in
   [geckodriver profiles](https://firefox-source-docs.mozilla.org/testing/geckodriver/Profiles.html).
   Downloads are staged privately but publication/upload and shared persistent
   profiles still require their host brokers. Stagehand remains unavailable in
   this worker until its model and process ownership are connected.

   The tool proxy must
   preserve the exported tool's installation-selected command/result hooks;
   mandatory wire decoding does not replace those optional hooks. Upload leases, artifacts and model
   generation still require their explicit host brokers.

   The `Browser_addon_tools` adapter translates the existing public
   aliases into closed advertised commands while preserving capability filters,
   contextual reads, scene guards and Keeper screenshot projection. It keeps
   raw tool receipts and metadata when projection fails after dispatch, and
   partial effect phases pass to the existing Keeper adapter unchanged. The
   public core/Keeper dispatchers now invoke this adapter for tabs, reads,
   sessions, navigation, structured actions, interactions and instructions.
   The core derives its principal from verified runtime identity or credentials;
   a caller name or tool body is not authority. Keeper producers preserve scene
   retention, artifact manifests and scoped upload staging. Generic uploads
   without that file authority are refused before dispatch. The bundled worker
   still refuses transfers until its cross-process broker is connected.

   The observation, composition, Vision and download-provider success fixtures
   now use a shared native Runtime/launcher/MCP installation with the selected
   input/output hooks. Only browser replies are scripted. Existing retained-byte,
   manifest, target identity and partial-effect assertions remain. These fixtures
   exercise the public producer path when run; their source alone does not prove
   execution or support for actual browsers and transfers. Built-in startup and
   the remaining executor helpers still need to be removed in a following unit.

   Screenshot publication now takes the served Workspace base path explicitly.
   PNG validation, frame storage, image reads, Vision analysis and promotion use
   that same config-root resolution and Keeper identity. An operator's explicit
   config-root override still follows the existing resolver policy. The browser
   reply cannot supply a host pathname or change this storage scope. Image
   ingestion and other producers with a Workspace also forward it; callers
   without a Workspace retain process-config resolution. Checkpoint image
   eviction requires the save caller's base path, including initialization and
   history-clear saves, so a reloaded handle stays readable in that Workspace.
   The screenshot-to-Vision
   fixture uses separate ambient and served Workspaces, checks refusal from the
   other Workspace, and preserves native-image, pixel, rotation and connection
   assertions. It also saves and reloads an image-evicting checkpoint and checks
   that its bytes belong to the served Workspace. Source changes do not establish scenario execution. File-transfer
   broker and real browser evidence remain separate requirements.
5. Scoped model-generation middleware using the existing exact-output authority,
   with retained request/terminal evidence and installation-selected routes. The
   new package `exact_outputs` declarations are reused; observation-only sampling
   does not substitute for this broker.
   Installations can now override `exact_outputs` with a subset of declared
   names, independently of `tool_hooks`. Omission keeps package defaults and
   an empty list disables these model outputs. The effective package retains
   only selected names with their original schemas and canonical order; unknown,
   duplicate and malformed selections are refused. Worker input revisions include
   that effective selection. The shared retained exact-output runner is being
   developed in [#44203](https://github.com/jeong-sik/masc/pull/44203), whose current
   source admits output names from the supplied effective package. Native browser
   host-request integration and actual execution evidence are still required;
   selecting outputs alone does not enable that broker.

## Completion evidence

Use isolated test pages and profiles, without operating on personal sites.
Record attach, real browser startup, observation, input, in-flight detach,
confirmed owned-process cleanup and reattach. An old incarnation's requests,
results, tab handles and host registrations must be refused by the replacement.

Exercise WebExtension, live BiDi, owned Gecko and owned Chrome. Preserve trusted
hover, drag, clicks, typing, keys, scrolling, zoom, navigation and tab receipts.
Do not present unimplemented browser/action families as supported.

Transfer upload ownership explicitly: a pathname crossing a process boundary
does not transfer the core's in-process upload lease. Retain bytes through the
browser's actual use and release only at confirmed owner cleanup. Downloads and
screenshots cross a scoped artifact broker, never an arbitrary host-path read.

Exercise model delay/cancellation, malformed output, created-tab partial failure
and lost worker replies. A lost reply must not cause another click, input or tab
creation. Source review, focused protocol evidence, full build and installed
runtime verification are separate claims.
