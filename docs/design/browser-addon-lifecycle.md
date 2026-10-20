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
   members. The handle does not establish durable admission/restart recovery,
   profile ownership, or cleanup of descendants that leave that group. Native
   manifest/runtime selection and those resource contracts remain to be wired.
4. A browser worker that owns WebExtension/BiDi command queues and owned Gecko/
   Chrome execution. Core admission and artifact/model brokers remain host edges;
   built-in browser execution and tool fallback are removed.
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
