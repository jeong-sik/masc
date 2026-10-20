# Browser execution as an optional Lane Add-on

The browser executor currently starts inside the MASC server. Disabling request
admission or detaching an observer does not detach that executor. The requested
change moves execution, sessions and owned processes into an optional Add-on.

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
   The foundation now provides `masc-browser-addon-worker`: stdio serves only
   `lane_observe`, while a host-selected private Unix socket handles concurrent
   issue/poll/result/disconnect/snapshot requests. One canonical incarnation is
   admitted per process, and every request carries it. Live execution requires
   the already-selected client ID; no worker-side automatic route selection or
   retry occurs. Strict codecs retain existing document, viewport, frame and
   keyboard guards plus partial-effect result bodies. A nested service switch
   owns every accepted connection so idle clients cannot prevent shutdown.
   Retirement fences admission before disconnecting clients and cancelling waits.
   Socket paths must be absent inside a canonical, same-UID 0700 directory;
   stdin EOF and termination signals retire the owner. The host supplies the
   installation's native reply bound to this second transport as well.

   This foundation has no package manifest or core proxy enabled. Existing
   built-in startup is still active. Owned backends are explicitly refused here
   until profile claims and actual descendant cleanup are connected. Next, the
   native host must select the socket/UUID arguments after owner validation and
   pin existing HTTP host registrations to that original incarnation. Late host
   poll/result retries must never be redirected to a replacement. The proxy must
   apply installation-selected command/result hooks; mandatory wire decoding
   does not replace those optional hooks. Upload leases, artifacts and model
   generation still require their explicit host brokers.
5. Scoped model-generation middleware using the existing exact-output authority,
   with retained request/terminal evidence and installation-selected routes. The
   new package `exact_outputs` declarations are reused; observation-only sampling
   does not substitute for this broker.

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
