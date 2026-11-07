# Browser execution as optional Lane Add-ons

The browser source is the optional Lane Add-on `browser-ego` (an ego lite
connection) with its own worker. The worker runs from the `[browser.live.ego]`
table of `runtime.toml`. Whether it runs is its declaration's `enabled`.
Attaching the Add-on acquires its browser resources; detaching it revokes input
and joins their cleanup. The ego lite profile keeps its logins across
attachments.

The ego connection owns no browser process. The worker receives its command
and task space reference as startup arguments: `--live-ego-command` and either
`--live-ego-space` for a name or `--live-ego-space-id` for an existing numeric ID.
A name requests creation or resumption; a numeric ID requests exact resumption.
Missing IDs and replies with a different requested name or ID are refused.
The worker reads `ego-browser --version`, attaches
to that Space, and registers one client. One serial `ego-browser nodejs` process
serves the connection: the SDK's dialog and event state belongs to that
process. A failed or cancelled session may be replaced before a later command.
The process-state gap is measured separately for installed 0.6.0.20 and 0.6.1.11 in
[session evidence](../evidence/ego-native-session-gap/). MASC sends fixed
scripts through its private session socket; it does not expose host Node
execution to Keeper-supplied code.

Ordinary commands retain their existing reply window. Native workflows and
live uploads let SDK waits own their timeouts and use explicit cancellation
instead of a cumulative command deadline. Cancellation joins the SDK process;
a lost effect reply remains uncertain and is never replayed. Results no longer
owned by the original request are dropped, and the Keeper reobserves its page.
Screenshots pass through a private directory that run creates and removes.
Detaching stops the SDK session and preserves an unfinished Space, its tabs
and browser-backed files. Explicit `finish_space` completes a successful task;
its `keepPages` policy and native receipt identify which Pages and Space remain.
A user-owned name is published as unavailable; attachment to a user-owned
numeric ID is refused. A handed-off agent Space may attach, while Page reads
and input still require agent control.

The operator selects tool-contract hooks: validate commands before dispatch and
successful structured replies after dispatch. Input and output hooks can be
selected separately. A browser package declares no exact output and no operator
asks, so a browser worker runs no model generation.

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
4. A browser worker that owns the ego command queue. Core
   admission and artifact brokers remain host edges;
   built-in browser execution and tool fallback are removed.
   `masc-browser-addon-worker` publishes `browser_command` and `lane_observe`
   on stdio. A browser service's exports are not public tools: Keeper tool
   lists, MCP `tools/list` and lookups by name read only MCP tool packages, so
   only the browser host calls `browser_command`, by the identity of the
   installation it chose. The command requires the private host-context control port and
   uses the installation's selected input/output hooks. A host-selected private Unix socket handles concurrent
   issue/poll/result/disconnect/snapshot requests. One canonical incarnation is
   admitted per process, and every request carries it. Live execution requires
   the already-selected client ID at dispatch. The worker chooses no browser:
   the command names the lane, and for live the client ID, that the host chose
   from the worker's snapshot, and a route to a client that is not connected
   or a browser the worker does not run is refused before dispatch. There is
   no retry. Strict codecs retain existing document, viewport and
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
   read/scene/screenshot/interact/goto invoke its advertised tool with
   the selected input/output hooks. A two-command page read pins the first
   command's concrete connection and refuses changed connection receipts. Bound
   tab reads require the original client before discovery. The host chooses
   the browser from the worker's snapshot (`Browser_addon_host.issue`) and
   stamps the receipt's selection/connection identity itself; page fields
   cannot replace it. A snapshot whose reply is lost changes nothing in the
   browser, so it leaves the worker serving
   (`Browser_addon_wire.changes_nothing`). Pure projections share the existing partial-inventory, scene,
   navigation, document, viewport and tab checks. Failed tool replies retain
   their original MCP receipt and effect metadata. None of these paths retries
   input or falls back to builtin queues. Read/admin authorization stays at the
   HTTP boundary. Installed TUI and actual browser evidence remain separate.

   Normal detach sends private `Retire` before native termination: admission is
   revoked and the worker joins its source's cleanup. Retirement waits for this
   completion rather than the quick control timeout or the native worker's short
   abort grace. Stdin EOF and termination signals also join backend cleanup.
   The host additionally requires native group settlement, the original
   allocation inode and its unchanged spec. It removes only known regular
   files, the socket and empty directories. Files the browser left for the
   Keeper (downloads, their host snapshots, uploads) are not a running
   resource: once the group has settled and the inode is the original, their
   trees move by rename into `<lane-addon store>/kept-files/<instance id>`
   and the release goes on. The pass that moves them names that folder: in
   the server log when it releases, or in its unconfirmed cleanup when a
   later step fails. The host never copies, removes or reads them again; the
   operator prunes `kept-files`. A link or a multiply linked file in those
   trees, a destination that already holds a tree, a `kept-files` on another
   device, or changed identity leaves the release unconfirmed and refuses
   replacement.
   Replacement stays refused until the operator takes the retained allocation
   over with `POST /api/v1/lane-addons/retain` (operator credential only). The
   host first confirms what it can observe: the admission is already Settled,
   and the allocation keeps its
   recorded identity. Retain itself retires no claim and signals no process. It
   then records the acquisition as `retained` and the instance as detached with
   `Native_retained`. It infers nothing it cannot observe and removes nothing.
   The leftover files stay in place, and the declaration may start a new
   instance. Every later cleanup of that claim reports the allocation as
   retained, never as released, so a binding write that did not land still
   converges on `Native_retained`.

   Ownership is checked before backend payloads are interpreted. Preflight,
   cleanup and a repeated Retain validate the original descriptor envelope and
   instance-bound acquisition record, then leave an operator-retained allocation
   alone even if its backend payload no longer decodes or the operator moved
   its contents. Acquired resources still require the full
   current backend contract for automatic cleanup. An explicit released record
   requires its original path to remain absent; a missing acquisition record
   cannot bypass backend validation or silently confer retained ownership.

   The tool proxy must
   preserve the exported tool's installation-selected command/result hooks;
   mandatory wire decoding does not replace those optional hooks. Upload leases
   and artifacts still require their explicit host brokers.

   The `Browser_addon_tools` adapter translates the existing public
   aliases into closed advertised commands while preserving capability filters,
   contextual reads, scene guards and Keeper screenshot projection. It keeps
   raw tool receipts and metadata when projection fails after dispatch, and
   partial effect phases pass to the existing Keeper adapter unchanged. The
   public core/Keeper dispatchers now invoke this adapter for tabs, reads,
   sessions, navigation, structured actions and interactions.
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
   execution or support for actual browsers and transfers. The remaining live-browser
   startup and standalone probe helpers still need to move to their Add-on owners.

   Screenshot publication now takes the served Workspace base path explicitly.
   PNG validation, frame storage, image reads, Vision analysis and promotion use
   that same config-root resolution and Keeper identity. An operator's explicit
   config-root override still follows the existing resolver policy. The browser
   reply cannot supply a host pathname or change this storage scope. Image
   ingestion and other producers with a Workspace also forward it; callers
   without a Workspace retain process-config resolution. Checkpoint image
   eviction requires the save caller's base path, including initialization
   saves, so a reloaded handle stays readable in that Workspace.
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
   that effective selection. This stack reuses the common typed lane ownership,
   runtime route declarations, retained request store, failure classification,
   exact runner and host request cycle from the first seven layers of
   [stack #44172](https://github.com/jeong-sik/masc/pull/44216). Their feature
   commits retain their original provenance. The unrelated Board, Ask and
   schedule layers are outside this integration.

   Native and container workers now share discovery and invocation of private
   `lane_host_requests` / `lane_host_result` ports. The default native backend
   uses the same declared-lane runner registered at server bootstrap. Selection
   off creates no host port. Final answers survive replacement of the worker;
   changed request bodies cannot reuse a denied ID. Selection-off delivery
   refusals retain an existing original answer for later replay. Detach cancels
   the current exact scope; any started request with no retained outcome
   remains unknown.

   `test_lane_addon_exact_native` covers an actual launcher and stdio worker
   against a loopback HTTP provider, private result delivery, selection off and
   retained-answer reattachment. Protocol fixtures cover missing/duplicate ports
   and unselected-port admission; a runtime fixture holds cleanup open while
   retiring a blocked exact call. These are scenario definitions, not execution
   evidence.

   A browser package (`service = "browser"`) may not declare exact outputs or
   operator asks; the manifest is refused otherwise. The browser worker
   therefore opens no host request port.

## Completed download artifacts

The ego connection copies a completed, session-owned download into a private
streaming snapshot. The cached producer marker names that immutable
snapshot. Each download read binds a fresh opaque grant to its original actor,
route and complete command; worker paths are removed from the response.

Normal exported calls pass through mandatory host result finalization after
invocation and before the selected output hook. This happens outside the MCP
mutex. The raw `on_result` callback retains its original receipt contract. The
finalizer uses the captured original private socket to Claim, import and Commit
the artifact, then always Release the original grant. Selected schema
hooks cannot bypass this transfer boundary.

The host derives a snapshot path only from its acquired allocation and canonical
UUID. It checks the original allocation, snapshot root and opened file identity,
then streams that same descriptor through the blob store with the expected
SHA-256. No pathname is reopened during ingestion. Both copy passes and the
durable payload/parent sync must succeed. Final text and structured replies name
the existing `keeper_artifact_read` artifact; identity and metadata stay bound to
the original command. Later reads reuse the acknowledged publication.

Retire closes fresh admission but still accepts the original exact Commit and
Release. It joins local preparations. A claimed or committed grant whose holder
has not released it prevents deletion and returns a sticky failure without
waiting for the remote holder. All files and exact grant states remain; late
Commit and Release cannot clear that failure. The worker's outer shutdown scope observes the
same cleanup when caller cancellation bypassed an orderly host Retire. Cleanup removes only exact
committed original files and their snapshots after confirmed backend teardown.
The broker keeps the original read-only, close-on-exec descriptor from verified
copy through retirement, preventing original-inode reuse. Deletion requires that
pinned inode, original owner, single link, unchanged permissions and exact
published byte count and SHA-256. Historical mtime/ctime may change after copying;
current identity and metadata must remain stable across the bounded digest read
and final pathname/parent/allocation checks. Reads may change atime, which is not
part of that comparison. This relies on confirmed backend shutdown and the
original private allocation, not atomic deletion against hostile same-UID code.
Unpublished, partial, replaced or unknown files remain explicitly unconfirmed.
Every retained descriptor closes on successful or failed retirement. Unconfirmed
backend shutdown closes descriptors without deleting files, and its failure stays
sticky. Process recovery cannot rebuild this original-inode authority from a path.

The added scenarios cover the actual owner/private socket/host finalizer/blob
boundary, repeated publication, revoked admission with active settlement,
descriptor/digest mismatch and source replacement. Additional download
scenarios cover metadata finalization, changed bytes with restored mtime,
identical-byte replacement, replaced parents, permission changes, duplicate
snapshots and unconfirmed-backend disposal.
[Selected run39518114697](https://github.com/jeong-sik/masc/actions/runs/39518114697)
passed nine download and one original-owner cleanup cases at composition
`3b5f93d48aeb0f320a5eddf378f0ef084f2ede1b` (feature `c492faf44d1ee836ae157da2acffb7da7dd424ce`
plus two reviewed runner files).

## Completion evidence

### Recorded execution scope

These results prove their recorded source and scenarios, not deployment or
whole-stack merge readiness. Model providers in the browser proofs are scripted
loopback HTTP fixtures; they do not measure real-provider response quality.

| Scenario | Source | Completed evidence |
|---|---|---|
| Owned live Firefox BiDi | `f9b02ae36f661d0584ad17c0e88626b4e18a2eba` | [39514000850](https://github.com/jeong-sik/masc/actions/runs/39514000850): 28/28 steps; trusted hover/click/double-click/drag, partial tab creation, retained uncertainty, reattachment and no replay |
| Independent Hook/Exact Output selection and retained native answer | Product `ed764a999ee637ceab9b49e5e547d72d0a12133d`; composition `86309539fa67b2b24fbbb3e20b3a0c2ae2946e57` adds two CI runner files | [39516409345](https://github.com/jeong-sik/masc/actions/runs/39516409345): configuration 23/23 and native Exact Output 1/1 |
| Pinned download and failed-owner cleanup | Product `c492faf44d1ee836ae157da2acffb7da7dd424ce`; composition `3b5f93d48aeb0f320a5eddf378f0ef084f2ede1b` adds two CI runner files | [39518114697](https://github.com/jeong-sik/masc/actions/runs/39518114697): downloads 9/9 and owner cleanup 1/1 |

Source/workflow identities and the retained native executable hashes were
verified for the actual browser row.

The later [environment boundary fix](https://github.com/jeong-sik/masc/pull/44631)
at `f2d71690c8b0d1c63bad7e5e1abae2ae645fe53f` projects operational settings
before the Browser_service launcher starts. Provider credentials stay with the
host; the host environment and generic MCP worker policy are unchanged. The
worker's browser/driver children inherit the projected environment. This is
not a same-user filesystem sandbox. The older actual browser rows above do not
prove execution after this change. Its selected checks are:

- [Native runtime/Exact Output 39528969166](https://github.com/jeong-sik/masc/actions/runs/39528969166), composition `a18c0a80d4334fe7be95cb2b3ccf2ba79a139192`: the whole run failed because the native runtime fixture omitted its direct `Common` library dependency. Its environment-sentinel assertions did not execute. The separately selected native Exact Output case passed, including retained delivery without another provider call.
- [External WebExtension 39528932570](https://github.com/jeong-sik/masc/actions/runs/39528932570), exact source `f2d71690c8b0d1c63bad7e5e1abae2ae645fe53f`: 25/25 steps and 12 tool receipts; real native messaging/HTTP ingress, one witnessed click, borrowed Firefox preservation, fresh client/incarnation, stale refusal and final owned-worker cleanup. The fixture then deleted its external Firefox session and verified browser exit.

After [the direct dependency repair](https://github.com/jeong-sik/masc/pull/44636),
[native run 39530782815](https://github.com/jeong-sik/masc/actions/runs/39530782815)
compiled composition `b5570b2980a7ebc0864d9388cd641273103e1d65` (product
`f30b0253085887587e23162a894d916fe2ccaad9` plus the same two CI runner paths).
The browser-service case passed: actual Runtime launcher, Python fixture worker
and subprocess omitted both fake provider and unlisted sentinels, preserved
operational settings and left the host credential unchanged. Its ingress,
middleware, original identity, effect, cancellation and cleanup assertions also
passed. This does not introspect an actual Firefox environment. The whole run
failed: the four generic installation cases advertised an invalid action schema
and timed out before observation. The [fixture repair](https://github.com/jeong-sik/masc/pull/44642)
declares the existing closed action/context contract and reports typed lifecycle
failures immediately; it does not change product validation or timeout values.
The focused retry [39532506931](https://github.com/jeong-sik/masc/actions/runs/39532506931)
passed all five cases of `test_lane_addon_native_runtime` at composition
`cfcc25688c121f8e92cacb164d5740d6dc842dcf` (reviewed fixture source
`9304ac5f09b03c9103bd200ea7e0789ed46e3bef` plus those two runner paths).
The executed log confirms native action once-only behavior, original process
settlement before release, retained recovery, fresh configured incarnation and
installation-slot reuse, including all three interrupted-slot scenarios. The
browser case also passed its environment, middleware, ingress, original-identity,
cancellation and cleanup assertions. The original failed runs remain above;
this focused result does not establish full regression success. Later changes
only update evidence documentation, with fixture and product source unchanged.

Live BiDi [39531129073](https://github.com/jeong-sik/masc/actions/runs/39531129073)
passed 28/28 steps with 17 tool receipts. Trusted hover/click/double-click/drag,
partial tab creation, original child settlement, persistent profile and fresh
worker/client/claim passed. The held navigation arrived once; interrupted input
kept `effect_outcome_unknown` and stale input did not reach the fixture. Its log
also retains `BiDi command cancelled; download cleanup requires confirmed backend teardown`.
This is not a successful orderly backend Retire receipt: original native claim
settlement and host allocation cleanup independently confirm owned-process
cleanup. The preserved raw PNG is not a Keeper-store reread after cleanup.

The run compiled exact source `f30b0253085887587e23162a894d916fe2ccaad9`
on workflow `f14befbde7638f40c26e8e2b74138970f3cccc04`, after the common
environment projection. Source/workflow records, all four native input hashes,
actual JSON outcomes and PNGs were inspected independently. The later fixture
repair changes only its test, documentation and changelog; product and browser
probes are unchanged.

Full regression, personal-site sessions, installed TUI behavior, other browser
families, formal whole-stack approval and merge remain separate claims.

Use isolated test pages and profiles, without operating on personal sites.
Record attach, real browser startup, observation, input, in-flight detach,
confirmed owned-process cleanup and reattach. An old incarnation's requests,
results and tab handles must be refused by the replacement.

Exercise ego. Preserve trusted
hover, drag, clicks, typing, keys, scrolling, navigation and tab receipts.
Do not present unimplemented browser/action families as supported.

Transfer upload ownership explicitly: a pathname crossing a process boundary
does not transfer the core's in-process upload lease. Retain bytes through the
browser's actual use and release only at confirmed owner cleanup. Downloads and
screenshots cross a scoped artifact broker, never an arbitrary host-path read.

Exercise created-tab partial failure and lost worker replies. A lost reply must not cause another click, input or tab
creation. Source review, focused protocol evidence, full build and installed
runtime verification are separate claims.
