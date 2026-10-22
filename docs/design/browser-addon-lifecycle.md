# Browser execution as an optional Lane Add-on

The optional browser Add-on owns live command queues and Gecko automation.
The Gecko driver starts only with an attached browser Add-on and a configured,
enabled `[browser.automation]`. Chrome/Stagehand also starts inside that worker,
with its original native process owner and shared Exact Output broker. The Keeper
live Firefox also starts inside that worker when `[browser.live.bidi]` is
configured and `[browser.live]` is enabled. Attaching the Add-on acquires its
browser resources; detaching it revokes input and joins their cleanup. The
configured Firefox profile keeps its logins across attachments.

The live Firefox path starts a new browser through the native process owner.
It checks the original kernel lease and child identity, the configured profile
and Firefox's `moz:processID` before publishing a connection. An occupied port
or an already used profile is a startup refusal. Existing browser processes
remain under their operator's control. Polls and results go directly to the
original worker and client UUID. Normal detach sends `browser.close` once to
that verified browser and waits for its original owner. Failed shutdown stays
unconfirmed. Persistent profile contents and shared lease files remain in place.
Failure to start a configured live Firefox prevents this worker from becoming
ready; its other backends are joined during failed-start cleanup. An unexpected
connection failure revokes that worker rather than publishing a dead client.

The external WebExtension/native-host bridge remains available independently.
Its observations describe those external hosts. Read the attached browser
Add-on's observation for the worker-owned Firefox connection and startup errors.

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
   profiles still require their host brokers. Chrome now has the owned controller
   described below, including dedicated persistent-profile admission. Gecko
   persistent profiles still require their ownership boundary.

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

   The Chrome ownership component now has a dedicated
   `masc-browser-process-owner` executable. It runs behind the native launcher
   and keeps the launcher's inherited lease descriptors in its own process;
   the browser child receives only its standard streams. Browser subprocess
   descriptor handling is explicit in Chromium's
   [LaunchOptions contract](https://chromium.googlesource.com/chromium/src/+/refs/heads/main/base/process/launch.h),
   so a browser is not required to preserve MASC's lease descriptors itself.
   This owner refuses to run outside its own foreground group. Its bootstrap
   receipt names the original instance, owner and child, but grants no authority:
   the caller must independently observe that instance's native kernel lease.

   A stdin keepalive pipe carries no commands. EOF, any byte or TERM/INT stops
   admission to the owner lifetime and requests group TERM. The owner remains
   alive through the existing five-second resource grace and then kills its
   own group, including itself. Normal browser-child exit ends that group
   promptly. The running owner occupies the group ID until the final signal;
   no recorded PID or command-line lookup authorizes orphan signalling. An
   actual child that closes extra descriptors therefore cannot drop the owner's
   lease, and losing the sole keepalive writer requests cleanup without another
   browser command. The native claim still needs durable retirement and observed
   settlement before resource reuse. A child that deliberately leaves the group
   needs its own ownership; this component is not a sandbox or proof about such
   children. Abrupt loss of the owner with a surviving group remains unconfirmed.

   Bootstrap output runs concurrently with child/keepalive/termination
   observation. Stopping cancels a backpressured bootstrap write before group
   teardown; no arbitrary timeout is added. A partial bootstrap reply does not
   establish browser readiness or a completed operation.

   The `runtest-browser-process-owner` alias defines actual launcher/owner/lease
   scenarios for TERM, keepalive-writer crash, normal child exit, non-owner
   refusal, descriptor closure, descendant cleanup and fresh admission. They
   also fill the actual stdout pipe to EAGAIN and separately exercise TERM,
   EOF and child exit without reading the bootstrap reply. They
   use Python process trees, not an actual Chrome/CDP session. The exact
   `fded0927497803bfc463324e3fcfddef51581d14` process-owner head passed all
   seven scenarios in [run 39465959754](https://github.com/jeong-sik/masc/actions/runs/39465959754).
   That result does not establish Chrome/UI or whole-stack execution.

   The host now snapshots Chrome, extension, installed native launcher and
   installed browser-process-owner paths into the original worker reservation.
   A separate stable child claim is selected per worker incarnation outside its
   disposable allocation. `stagehand.json` is pinned to that descriptor; the
   worker's `--stagehand` path creates the existing session backend under its own
   lifetime and attaches it to the Add-on owner. The selected `stagehand` Exact
   Output callback is installed on the real session. Without that selection,
   native commands remain available and model verbs, including task-required
   sentence actions during discovery/open, are refused before dispatch. The
   worker resolves no provider credentials or alternate model route.

   Each open reserves a fresh child instance before allocating its fresh private
   profile, runs the native launcher and guardian, and checks the bootstrap
   receipt against the original kernel lease before connecting CDP and loading
   Stagehand. The guardian's strict bootstrap also records its child's kernel
   start token, retained in the original process handle immediately after spawn,
   before observers or a reaper can release that PID. The guardian never builds
   that original identity from a later PID lookup. The worker checks that incarnation and its original foreground
   group, then sends only `SystemInfo.getProcessInfo` on the new CDP connection.
   Exactly one browser row must name that original child. It checks the kernel
   owner and child again after the reply, before creating the Stagehand session
   or loading its extension. Missing, duplicate or foreign browser identity
   closes the connection and leaves cleanup with the original process manager;
   a PID from CDP never authorizes signalling. Extension/model event handling
   begins only after this identity admission. The CDP PID and browser process
   row come from the [protocol definition](https://github.com/ChromeDevTools/devtools-protocol/blob/master/json/browser_protocol.json)
   and [Chromium implementation](https://github.com/chromium/chromium/blob/main/content/browser/devtools/protocol/system_info_handler.cc).

   The identity scenario uses an actual launcher/guardian/child and kernel lease
   with scripted CDP replies. It covers changed child incarnation before any
   command, a foreign PID, a valid original child and owner loss before a matching
   reply. The process-manager scenario also retains original birth through
   actual child reap and covers fast-exit and unsupported-manager handles.
   This defines behavior to execute; it is not real Chrome evidence or
   persistent-profile support. Startup and model work retain their original owner rather than
   the quick browser response clock. Startup failure stops and joins the original process group before
   returning. Close and detach fence late launchers and join the session switch;
   retirement additionally requires child-claim settlement. Normal browser
   shutdown now precedes keepalive release, as described below.
   Host recovery uses the original descriptor and child lease even after worker
   loss. It never signals a PID taken from a page or command-line match.

   After worker and child settlement and the original allocation-inode check,
   the host removes the private Chrome profile tree without following symlinks.
   It retains unknown resource types and changed configuration. The stable child
   claim files survive removal. This is trusted foreground-group ownership,
   not a sandbox or proof that a browser's escaped descendants are gone.

   The `test_browser_addon_stagehand` fixture defines host allocation, actual
   launcher/guardian/child execution, failed CDP startup, fresh admission, detach
   during blocked startup and link-safe profile cleanup. Its browser executable
   is scripted; it does not establish real Chrome, extension or provider use.
   The production core Stagehand startup/executor installation has been removed.
   The standalone Chrome probe now declares and attaches the actual bundled
   native browser Add-on, invokes public tool handlers with selected input/output
   hooks, and serves only a scripted provider through the shared Exact Output
   runner. It defines real page input, session close/reopen, detach during a held
   model command, stale-handle refusal and fresh worker reattachment. Fixture
   events and pointer feedback are observed through the fixture's loopback HTTP
   reports rather than an alternate session/evaluation path. The separate server
   opener and its PID/command-based recovery have been removed. These are
   executable scenarios passed in the scoped Chrome run recorded under
   [Completion evidence](#completion-evidence). Persistent Chrome profiles have
   the admission below; real-cookie scenarios and scoped transfers remain open.
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
   the current exact scope without closing the browser worker ahead of Retire;
   any started request with no retained outcome remains unknown.

   `test_lane_addon_exact_native` covers an actual launcher and stdio worker
   against a loopback HTTP provider, private result delivery, selection off and
   retained-answer reattachment. Protocol fixtures cover missing/duplicate ports
   and unselected-port admission; a runtime fixture holds cleanup open while
   retiring a blocked exact call. These are scenario definitions, not execution
   evidence.

   The browser worker now has a model queue and concurrent private request,
   result and availability-wait socket ports. Only selected outputs enter its
   pinned `models.json` bootstrap configuration. A request publishes an opaque
   availability revision; the host suspends on changes without a timer, apart
   from the serialized MCP command that may be waiting for that model. Original
   command cancellation withdraws only its own waiter. Before cancelling an
   active Exact scope, the host rechecks the request listing so an older event
   cannot cancel a newer dispatch. It also rechecks after registering each
   Exact cancellation scope, so a delayed listing cannot start a request whose
   withdrawal event was already processed. Detach fences the queue and wakes waiters.

   Results are checked against the selected schema and closed terminal wire
   format, then durably recorded with incarnation, original request digest,
   result digest and `model_result_received` disposition before waking the
   original waiter. Identical deliveries are acknowledged; conflicting ones
   cannot overwrite a receipt. A late result cannot wake a replacement command.
   Receipts live in the served Add-on store, outside the disposable browser
   profile allocation, and do not claim browser action completion. Neither the
   owner admission lock nor the serialized MCP channel is held during model
   waits or receipt I/O.

   Socket fixtures cover request-ready events, concurrent listing/delivery,
   schema refusal, durable receipts, cancellation and retirement. A host-cycle
   fixture covers withdrawal of a blocked Exact call and a later request in the
   same worker. These scenarios have not yet been executed.

   The bundled package now declares the fixed `locate` schema. A selected schema
   must match the worker consumer contract before publishing the Gecko backend;
   an omitted consumer is observed as unavailable independently of provider
   readiness. Owned Gecko `page.locate` reads a typed scene under the existing
   session owner, submits its observed nodes to the host Exact runner, then
   reads the original tab again. Original and fresh document/URL must agree;
   a match must occur in both scenes with unchanged observed kind, tag, text,
   ancestor region and source context. Geometry comes from the fresh scene.
   Model explanations remain separate inference; no selector, script or input
   comes from the model. A truncated scene does not claim complete matching.
   Neither the model-backed transport nor Gecko locate imposes the quick browser
   wait clock; caller cancellation and owner retirement still withdraw it.

   Public BrowserInstruct now requires the observed owned lane and tab ID.
   Automation serves observe only when locate is selected; act/extract retain
   their Stagehand requirement. The existing public native adapter fixture
   checks route/tab preservation and preflight refusals. A worker owner/queue/
   consumer fixture exercises accepted, changed-document, changed-meaning,
   invented-reference, cancelled and retired requests using a scripted
   WebDriver transport. These definitions are not executed browser/model proof.
   Actual Gecko locate/model proof, Gecko persistent-profile admission and
   scoped transfer brokers remain. Scoped Chrome/extension/shared-model
   integration evidence is recorded under [Completion evidence](#completion-evidence);
   it does not establish external-provider quality or personal-site behavior.
   The selected Stagehand schema/role adapter is connected to the worker session
   controller described above.

## Dedicated persistent Chrome profiles

`browser.stagehand.profile` selects an existing private directory for a dedicated
MASC profile. Omitting it keeps fresh private allocations. The selected persistent
directory keeps its cookies, preferences and login state; host cleanup never
recursively deletes it or clears its Chrome singleton or debugging-port files.
Chrome's default personal data directory is not an automation fallback: Chrome
136+ requires a non-default data directory for remote debugging; see
[Chrome's documented restriction](https://developer.chrome.com/blog/remote-debugging-port).

The first selection creates one private native claim slot and an exclusive,
durable anchor inside the profile. The descriptor pins the profile, slot, gate,
lease and anchor identities. Subsequent selections and startup revalidate them.
An incomplete bootstrap or a replaced synchronization inode is a refusal, not
permission to recreate admission. Claim files and the anchor must remain stable.

Each browser guardian acquires both its original child slot and this shared
profile slot through the existing native multi-resource launcher. Two MASC
installations cannot concurrently launch on that profile. Recovery, retirement
and old-owner cleanup retain a child-only view: a successor advancing the shared
profile intent cannot redirect old cleanup or make it target the successor.
The immutable child cleanup descriptor records the chosen profile lifetime.

This is cooperative ownership of a dedicated profile. Do not start an external
Chrome on the same profile concurrently. Startup refuses an existing
`SingletonLock`, `SingletonSocket` or `SingletonCookie`, including dangling links,
without interpreting their PID or deleting them. The check cannot exclude an
external start after it. Chromium's
[ProcessSingleton implementation](https://chromium.googlesource.com/chromium/src/+/HEAD/chrome/browser/process_singleton_posix.cc)
can forward a second launch or terminate an unresponsive existing browser; MASC
does not use that behavior as a recovery mechanism.

A preserved debugging-port file may name an old session. Only the pre-attachment
bootstrap can repeat read-only endpoint/`SystemInfo.getProcessInfo` observations,
within the existing startup window. Each attempt checks the original lease,
browser child and profile identity, and closes a refused CDP connection. No
extension, model callback or page input is admitted before these checks.

The preserved-profile scenario exercises real native guardian startup, shared
admission refusal, Retire during CDP startup, old cleanup after shared-slot
replacement, login-fixture preservation and refusal of a replaced gate inode.
It passed as the sole selected scenario in
[run 39487042120](https://github.com/jeong-sik/masc/actions/runs/39487042120),
composition `4854a935bba4e888e5ec84346a7df578333c5b5d`. It uses an isolated fake
Chromium endpoint, so this is native resource-lifecycle evidence rather than
actual Chrome cookie/login persistence or a whole-regression verdict.

The real Chrome probe now selects both private and dedicated persistent profiles
by default. `scripts/probe-stagehand.py --profile-mode private|persistent|both`
can select the needed scope. Each mode has its own loopback fixture, browser
workspace and reports under `private/` or `persistent/` in the output directory;
`profile-results.json` records only the selected executions. Build/source
manifests remain at the output root.

The fixture installs an expiring HTTP-only cookie through ordinary navigation.
Its uncached session page checks the cookie again after a browser close/open and
after in-flight Add-on detach/fresh-worker attachment. It installs and positively
observes a cookie before each retirement boundary, so reusing an already-empty
private profile cannot pass the fresh-worker check. A persistent profile must
retain the cookie; a private allocation must lose it. Both modes still exercise
the same input, model, cancellation and cleanup path. These new real-cookie
scenarios passed in both modes in run 39497965428, on source composition
`9ed6288ef6ba9e74105f686d6fa2a67acfd1c095`. This does not establish real login
preservation or personal-site behavior.

## Host-authorized uploads into the owned Gecko backend

The host admits uploads only from an exact pending `Browser_lane.Upload_lease`
batch produced by the Keeper's existing file-read authority. It retains the
original Add-on service, caller and bound automation command, then asks that
worker's private socket to copy the approved regular 0600 single-link files
into its own allocation. The existing per-file 16 MiB bound is shared by both
sides; file bytes do not travel inside the bounded MCP/JSON frame.

A host-minted one-use grant binds the verified actor, route and complete upload
command. The ordinary exported `browser_command` still runs the installation's
selected input/output hooks. Only its matching upload can consume the grant;
an ordinary low-level Issue with arbitrary paths is refused. The worker passes
its registered copies to the existing WebDriver upload owner, so a browser may
read them lazily after the host call and source snapshots have ended. Confirmed
session teardown releases the claimed copies. Host cleanup discards pending
grants on the same original connection, including a failed connection retained
for settlement; it never looks up a replacement or retries browser input.

Discard before or during preparation fences late grant publication. Retirement
fences new work, joins preparation and active claim scopes, then releases pending
files after backend cleanup. Snapshot deletion uses the existing descriptor-bound
parent/batch cleanup primitive; a replaced allocation remains unconfirmed. The
host's default staging uses a process-owned private anchor rather than treating
a shared system temp directory as deletion authority. This is cooperative native
ownership, not isolation from a same-UID writer bypassing those ownership rules.

The focused scenario defines public export/hooks, one-use caller binding, lazy
read lifetime, discard fencing and replacement-root refusal using the actual
owner/broker/lease modules with a scripted automation executor. It has not yet
run through linked Dune/CI, a real worker/socket or Gecko. A separate bounded
local probe executed the original upload-lease and owned-tree cleanup code and
C primitive: generic callback results, cleanup under a shared 1777 temp directory,
browser-claimed lifetime and replacement-file preservation passed. That probe
uses an exact cleanup-function re-export adapter and is not a whole Fs library,
worker or browser build. Chrome uploads and other backend transfer contracts
remain open. Owned Gecko download transfer is described below.

## Completed download artifacts

The owned Gecko BiDi producer copies a completed, session-owned file into a
private streaming snapshot. The cached producer marker names that immutable
snapshot. Each download read binds a fresh opaque grant to its original actor,
route and complete command; worker paths are removed from the response.

Normal exported calls pass through mandatory host result finalization after
invocation and before the selected output hook. This happens outside the MCP
mutex. The raw `on_result` callback retains its original receipt contract. The
finalizer uses the captured original private socket to Claim, import and Commit
the artifact, then always Release the original grant. Neither selected schema
hooks nor model/Exact Output selection can bypass this transfer boundary.

The host derives a snapshot path only from its acquired allocation and canonical
UUID. It checks the original allocation, snapshot root and opened file identity,
then streams that same descriptor through the blob store with the expected
SHA-256. No pathname is reopened during ingestion. Both copy passes and the
durable payload/parent sync must succeed. Final text and structured replies name
the existing `keeper_artifact_read` artifact; identity and metadata stay bound to
the original command. Later reads reuse the acknowledged publication.

Retire closes fresh admission but still accepts the original exact Commit and
Release. It joins active preparations and claims, including a committed claim
whose host has not released it. The worker's outer shutdown scope observes the
same cleanup when caller cancellation bypassed an orderly host Retire. Open Gecko
teardown closes the original session before joining its BiDi reader, and the
release fallback observes the same once-only close. Cleanup removes only exact
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
descriptor/digest mismatch and source replacement. The Gecko shutdown fixture
keeps a real scripted BiDi socket open across Retire. Additional download
scenarios cover metadata finalization, changed bytes with restored mtime,
identical-byte replacement, replaced parents, permission changes, duplicate
snapshots and unconfirmed-backend disposal.
[Selected run39518114697](https://github.com/jeong-sik/masc/actions/runs/39518114697)
passed nine download and one original-owner cleanup cases at composition
`3b5f93d48aeb0f320a5eddf378f0ef084f2ede1b` (feature `c492faf44d1ee836ae157da2acffb7da7dd424ce`
plus two reviewed runner files).

[Real Gecko run39518116324](https://github.com/jeong-sik/masc/actions/runs/39518116324)
failed on that feature source: the remote completed row carried
`artifactError = "download source changed while copying"`, with no artifact.
The probe's export-success label checked only remote completion, then raised
on the absent artifact. That label proves no artifact publication; downloaded
bytes and confirmed teardown were not established. The probe now retains the
completed row and requires the shared publication decoder before recording
export success. Copy refusals record original/opened/final descriptor and path
properties plus byte count, without source paths or contents. The guard and
sticky failure remain unchanged; no browser action or publication is replayed.
These diagnostic/probe changes await actual execution.

The earlier real Gecko run39514004029 failed at historical identity comparison;
diagnostic run39515749114 passed 23/23 steps with that predicate unchanged.
Neither identifies the old differing field or makes the newer failure a success.
Source review and actual selected execution remain separate.

## Completion evidence

[Real Chrome run 39497965428](https://github.com/jeong-sik/masc/actions/runs/39497965428)
passed 42/42 recorded steps in each of private and persistent modes. Its source
composition is `9ed6288ef6ba9e74105f686d6fa2a67acfd1c095`, product-equivalent to
`a4d0bb79d48dcbbd60d6ec24780bcd21c700468a` with nine CI paths; workflow commit
`d2806d092d5af57aa2d3a829c3719c0e43747033`. This includes the cookie boundaries
above. The separately selected run 39497960619 on that composition failed two
backend status cases because Closing hid the original ended reason. The frozen
clean source verdict was withdrawn. The follow-up retains the original session's
first reason through Closing and resets it only at the next successful open;
its actual regression result remains pending. These runs do not include the new
download artifact changes.

The private-profile public Add-on proof passed all 38 recorded steps in
[actual Chrome run 39488906467](https://github.com/jeong-sik/masc/actions/runs/39488906467).
The workflow commit is `d2806d092d5af57aa2d3a829c3719c0e43747033`; the explicit
source composition is `f1a39244a7eaeea3d7e48811d634b930ced70a24`, consisting of
feature head `02000a9f8a71f8b2c4e02a7fdbb2d8b6e9b988ce` plus nine separately
reviewed CI paths. The four native proof inputs built, and the recorded page
observations, trusted hover menu, click/fill/scroll, pointer and HTML5 drag,
actor/pointer feedback, shared Exact Output extract/observe/act, screenshot,
close/reopen, in-flight detach without replay, stale-handle refusal, fresh
incarnation and cleanup all passed. The provider was scripted loopback HTTP;
this establishes browser/model integration, not real-provider response quality.

The separately selected linked model scenario passed in
[run 39487998547](https://github.com/jeong-sik/masc/actions/runs/39487998547),
source composition `4a5a851f6f968877572344dc24d0b56f9729750b`. It checks the
original conversation and canonical schema turn, structured response and usage,
pre-effect refusal, uncertain outcome, no hidden retry, cancellation and detach.
It does not start a browser. Neither result includes the newer cookie scenarios,
personal sites, other browser families, full regression or installed-runtime
behavior. Lower frozen source failures and whole-stack readiness remain separate.

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

### Orderly Chrome shutdown and persistent-profile evidence

The real cookie proof in [run39490982860](https://github.com/jeong-sik/masc/actions/runs/39490982860)
passed private42/42, but persistent31/40 failed first at close/reopen: the profile
still contained SingletonLock. Stagehand runtime disposal had not requested
browser shutdown before the guardian termination path. The existing profile
identity and Singleton refusal remain; metadata is never deleted to make reuse
appear successful.

The backend now requires one shutdown callback per successfully opened original
session. Explicit close, automatic session retirement and parent stop all join
that same callback before releasing transport resources. A control cancellation
watcher ends the original lifetime; transport ownership remains protected while
startup work races that stop signal in a cancellable context. A successful opener
result wins a simultaneous stop, so an acquired session is never discarded.
Startup failure still joins its partial resources without inventing a session.

Chrome's callback verifies its original native owner and browser incarnation,
requests [Browser.close](https://github.com/ChromeDevTools/devtools-protocol/blob/master/pdl/domains/Browser.pdl)
once on the retained CDP connection, then awaits the pinned guardian process.
EOF causes no replay. Logical child retirement, native settlement and persistent
profile identity/Singleton release are checked separately. The existing
five-second resource grace bounds this teardown; it never bounds page/model
work. Unconfirmed orderly shutdown falls back to the original owned process
cleanup and remains an error even when abort cleanup succeeds.

The retained result reaches explicit close and Addon owner cleanup. Repeating
close or opening a successor cannot replace that failure with a clean receipt.
New focused backend scenarios cover parent-stop reader lifetime, cancellation of
unfinished startup and failed shutdown without replay. These source changes and
limited typing are not a linked scenario result or a repaired real-cookie proof;
that execution must use a new explicit candidate.
