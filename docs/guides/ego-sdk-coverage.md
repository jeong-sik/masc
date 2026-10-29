# Ego SDK coverage and remaining work

This inventory compares all **74 entries** printed by the installed
`ego-browser nodejs -e 'help()'` on 2026-10-28 with the MASC Ego adapter and
native workflow. Entries include properties and returned handles, not just
independent operations. Source integration, SDK execution, installed MASC and
actual Keeper/UI behavior are separate evidence layers.
The retained [installed help inventory](../evidence/2026-10-28-ego-sdk-help/README.md) records the complete command output and its digest.

The installed `ego-browser skill` guide is v2.1.0; the live browser reports Ego
0.6.1.11. The
[harness developer guide](https://lite.ego.app/document/en/docs/custom-agent-harness),
[browser API introduction](https://lite.ego.app/document/en/docs/ego-browser),
[Space guide](https://lite.ego.app/document/en/docs/space) and
[snapshot guide](https://lite.ego.app/document/en/docs/snapshot) explain the intended
model. The public examples currently use older global helpers and seconds; the
installed guide uses TaskSpace/Page handles and milliseconds. Do not copy old
examples into the current adapter or invent Playwright methods.

The source entrypoints are
[`browser_ego_peer.ml`](../../lib/browser_ego_peer.ml),
[`browser_ego_workflow.ml`](../../lib/browser_ego_workflow.ml),
[`browser_native_workflow.mli`](../../lib/browser_lane/browser_native_workflow.mli),
and the actual
[`masc_browser_interact` schema](../../config/tools/masc_browser_interact.toml).
“Internal” below means the adapter uses an API but does not offer its full public
contract to a Keeper. “Partial” includes missing SDK options and lifecycle choices.
Neither means fully supported.

This source inventory was refreshed against the pending native stack through
`bd800dc94952b00a33efaf1751d24313ffbc2a9a`, including the strict RegExp URL
matcher, evaluation/navigation diagnostics, pending native-download cancellation
and both Dashboard browser observation repairs. Source coverage does not mean
these changes are merged, installed or exercised by a real Keeper.

The official [Space guide](https://lite.ego.app/document/en/docs/space) describes
Spaces as BrowserContexts in the same Ego browser process, rather than headless
Chrome. This architecture description does not establish that a particular
local Space is visible or that its login is complete.

## Spaces and handles

| SDK entry | Current MASC integration | Remaining boundary |
| --- | --- | --- |
| `profiles` | None | Profile selection only after explicit user request; no general profile inspection |
| `listTaskSpaces` | space_status reads the native inventory and returns only the already bound numeric Space | General Goal Space discovery and lifecycle without replacements |
| `taskSpace` | Configuration accepts a name or exact numeric ID; subsequent rounds use the bound ID. Explicit BrowserSession Goal binding pins Keeper initial discovery to an observed Space across client UUID changes. A stored Goal or unique observed client can select its original service among several browser workers, with scoped exported-tool admission and no fallback | One configured Space per worker; automatic creation, multi-Goal worker lifecycle and installed Keeper routing remain unverified |
| `claimTaskSpace` | None | Explicit approval and user-owned Space admission |
| `takeOverTaskSpace` | `page.act` take_over uses the native execution wait on the fixed original numeric Space; returns its native user-boundary Page with no active-tab replacement | Explicit operator completion, currently only configured Space; real SDK/installed login handoff remains unverified |
| `TaskSpace.spaceId` | SDK-observed ID follows client inventory, tool receipts, stored screenshots and the TUI connection identity | Installed-route proof and per-goal Space lifecycle |
| `TaskSpace.name` | Attachment name follows connection context; explicit space_status returns the native-inventory name for the same numeric ID | Per-goal lifecycle and actual visible UI proof |
| `TaskSpace.ownership` | Explicit page.act space_status reads native listTaskSpaces ownership and observation time without constructing a TaskSpace handle, Page calls or changing control; private operator form, ordinary Add-on Dashboard connection list/selected event and TUI Browser Lane selection/detail show the dated cached observation; strict host/UI decoding binds the numeric Space | Real installed Keeper/UI proof; TUI component checks are not rendered TUI evidence |
| `TaskSpace.page` | Permanent label resolution; tab inventory and document-read projection retain the observed label | Lifecycle tools and installed-route proof |
| `TaskSpace.userPage` | Native takeover freezes the managed/unmanaged boundary handle and checks its Space/target/label/origin against that same Space's tabs. The receipt returns activeTabId/egoPage; absence stays absent | Explicit adoption before unmanaged reads; no current focus, login or input-reset proof; real SDK/installed execution unverified |
| `TaskSpace.pages` | Managed pages known through tab enumeration | Direct lifecycle-aware managed inventory |
| `TaskSpace.tabs` | `tabs.list` preserves label, target ID and `agent`/`unknown` origin for readable and unavailable tabs | Per-goal scope, lifecycle and installed-route proof |
| `TaskSpace.newPage` | `page.act` open_tab | Per-goal Space and returned permanent label |
| `TaskSpace.adopt` | Explicit `page.act` adopt_tab, observed tabId and clientId; native UnmanagedPage handle and optional pageLabel/as. Native Page effects support adopted Pages while preserving origin | Real SDK/installed-route proof and per-goal scope |
| `TaskSpace.release` | Explicit `page.act` release_tab unmanages an unknown-origin Page without closing it | Real SDK/installed-route proof and per-goal scope |
| `TaskSpace.waitForControl` | `page.act` wait_for_control forwards native interval/timeout and uses the SDK clock within an agent-owned Space | Real SDK/installed-route proof; no handoff completion or takeover implied |
| `TaskSpace.handOff` | `page.act` hand_off returns same-Space ID/name; Keeper guidance composes `masc_ask` and explicit-confirmation resume. Input-reset assertions are separate and never authorize takeover | Real Keeper login handoff and current UI control-state behavior; published ownership remains a dated observation |
| `TaskSpace.finish` | Explicit finish_space with keepPages (default empty), validated native receipt, terminal Page guard and process-local no replay; retirement preserves Space/files | Automatic Goal completion, durable cross-worker reconciliation and retained-file reclamation |
| `TaskSpace.cdp` | Fixed native activate_tab uses Target activation and same-target window lookup; restores only a minimized window. No caller-supplied protocol, target or window IDs | Real SDK/installed route and visible UI proof; general Target/Browser protocol boundary and lifecycle reconciliation |
| `Page.label` | Inventory and document-read DTO retain the permanent label; TUI shows it for the selected tab | Installed/UI proof and lifecycle-aware resume |
| `Page.spaceId` | Bound connection Space accompanies inventory and read receipts | Installed-route proof |
| `Page.openedBy` | Inventory/read DTO and TUI retain the SDK `agent` or `unknown` origin; explicit managed-Page effects preserve that provenance | Lifecycle tools and installed/UI proof |
| `Page.targetId` | Inventory/read DTO retain the observed target ID, including unmanaged tabs | Advanced Target protocol lifecycle; target IDs are ephemeral |

## Page operations

| SDK entry | Current MASC integration | Remaining boundary |
| --- | --- | --- |
| `Page.goto` | `page.goto`, native workflow goto with referer/timeout/waitUntil; workflow navigation timeouts retain committed, lifecycle and optional URL/readiness diagnostics | Actual timeout path and installed MASC/Keeper route unverified |
| `Page.reload` | `page.act` reload, native workflow reload with timeout/waitUntil; workflow preserves native navigation timeout diagnostics | Actual timeout path and installed MASC/Keeper route unverified |
| `Page.snapshot` | BrowserRead and final workflow snapshot; step snapshot preserves native scope/root and action-mark/stable-locator options | New step options require real SDK and installed-route proof |
| `Page.screenshot` | `BrowserRead` screenshot / `page.capture` forwards native fullPage, clip (including clip scale), scale="css" and raw; broker owns the output path and Vision size limit. Explicit options produce a page image artifact without pointer-frame geometry | Real SDK options execution and installed MASC/Keeper route unverified |
| `Page.url` | Native workflow url returns the SDK value as a step receipt | Installed MASC/Keeper route unverified |
| `Page.waitForURL` | Native workflow string/glob or `urlRegex {source, flags?}`; native RegExp construction and SDK matching/polling, without a second host matcher | Function matcher not exposed; actual SDK and installed MASC/Keeper route unverified |
| `Page.waitForEvent` | Internal download watch | General event waits and typed handle lifecycle |
| `Page.waitForTimeout` | Native workflow explicit finite nonnegative milliseconds | Real SDK/installed-route proof; elapsed time is not state verification |
| `Page.title` | Native workflow title returns the SDK value as a step receipt | Installed MASC/Keeper route unverified |
| `Page.info` | Native workflow info returns native state; dialog stops following steps | Installed MASC/Keeper route unverified |
| `Page.acceptDialog` | `page.act` accept_dialog | Native boolean receipt and per-goal ownership evidence |
| `Page.dismissDialog` | `page.act` dismiss_dialog | Native boolean receipt and per-goal ownership evidence |
| `Page.evaluate` | Native workflow browser expression/call with JSON; structured timeout code, timeoutMs, executionStopped, mayHaveLateEffects and pageResponsive retained as diagnostics | Actual installed timeout path unverified; diagnostics never authorize replay or settle held input |
| `Page.waitForFunction` | Native workflow waitForFunction with JSON and timeout/polling | Predicates count as possible effects; installed MASC/Keeper route unverified |
| `Page.fetch` | Native workflow fetch with browser options; `saveAs` accepts an artifact filename, maps it to a fresh private path, and returns a download ID for the existing download broker | Actual SDK binary execution, installed MASC/Keeper route and registry recovery across SDK-process replacement remain unverified |
| `Page.cdp` | Fixed internal history commands only | General Page protocol calls with explicit effect and lifecycle handling |
| `Page.waitForSelector` | Native workflow waitForSelector | Native states and timeout exposed; installed MASC route unverified |
| `Page.waitForLoadState` | Native workflow with optional state, timeout/idleMs | Installed MASC/Keeper route unverified |
| `Page.events` | Native workflow events drains only this SDK process's Page buffer; consumption counts as an effect and is never replayed | Real SDK and installed-route proof; durable cross-process event history is not supplied by this method |
| `Page.click` | Selector/ref interaction; workflow forwards all native options | New option forms require real SDK and installed-route proof |
| `Page.dblclick` | Selector/ref interaction; workflow forwards all native options | New option forms require real SDK and installed-route proof |
| `Page.hover` | Selector/ref interaction; workflow forwards all native options | New option forms require real SDK and installed-route proof |
| `Page.dragAndDrop` | `drag_to`; workflow forwards native options and tracks release uncertainty | New workflow requires real SDK and installed-route proof |
| `Page.fill` | Selector/ref interaction; workflow forwards clearFirst/timeout | New option forms require real SDK and installed-route proof |
| `Page.selectOption` | Workflow selectionJson preserves string/object/array/null, including label/index | New selection forms require real SDK and installed-route proof |
| `Page.focus` | Native workflow focus | Real SDK primitive proof; installed MASC/Keeper route unverified |
| `Page.press` | Native workflow press with delay/timeout | New option forms require real SDK and installed-route proof |
| `Page.setInputFiles` | `page.act` upload through staged leases | Direct workflow integration while preserving file broker/lease boundary |
| `Page.waitForFileChooser` | Internal chooser-opener upload | Explicit chooser wait/handle/options in native workflows |
| `Page.close` | `page.act` close_tab on agent-created Pages; unknown-origin managed Pages use release_tab | Real SDK/installed-route proof and goal/Space lifecycle |

## Input and returned handles

| SDK entry | Current MASC integration | Remaining boundary |
| --- | --- | --- |
| `Page.mouse.click` | Trusted coordinates; workflow forwards button/clickCount/delay/label | New workflow requires real SDK and installed-route proof |
| `Page.mouse.move` | Hover/path internals; workflow forwards steps/label | New workflow requires real SDK and installed-route proof |
| `Page.mouse.down` | Internal coordinate-path drag presses natively; an entered raw sequence retains unknown release and blocks input pending private operator confirmation | General held-button workflows and native release settlement remain unsupported |
| `Page.mouse.up` | Internal coordinate-path drag attempts native release in finally; its void result never proves release. Selector drag delegates release to native dragAndDrop | Explicit raw release acknowledgement and automatic uncertain-pointer recovery remain unsupported |
| `Page.mouse.wheel` | Scroll at observed point; workflow forwards deltas/label | New workflow requires real SDK and installed-route proof; move over observed container first |
| `Page.keyboard.down` | None | Held-key state and cancellation/release settlement |
| `Page.keyboard.up` | None | Explicit release and uncertain-key recovery |
| `Page.keyboard.press` | Interaction chord; workflow forwards native delay | New option forms require real SDK and installed-route proof |
| `Page.keyboard.type` | Workflow forwards native text/delay, then stops on the SDK's void result with input release unconfirmed; preserves the earlier completed prefix and requires private operator recovery | Automatic continuation requires native settlement evidence; real SDK and installed-route proof remain open |
| `Page.keyboard.insertText` | Native workflow | Real SDK primitive proof; installed MASC/Keeper route unverified |
| `Page.keyboard.paste` | Native workflow plain/rich paste | Real trusted paste proof; installed MASC/Keeper route unverified |
| `FileChooser.isMultiple` | Internal chooser validation | Explicit chooser handle observation |
| `FileChooser.setFiles` | Internal upload with staged copies/leases | Explicit handle lifecycle and timeout options |
| `Download.page` | No native call; registry stores the triggering Page label | Returned handle provenance in workflow receipts |
| `Download.url` | Internal download registry | Direct handle observation |
| `Download.suggestedFilename` | Internal download registry | Direct handle observation |
| `Download.saveAs` | Internal UUID path then download broker | Explicit brokered save operation; no arbitrary host path |
| `Download.path` | None | Round-local path lifetime with broker output |
| `Download.failure` | Internal completion/interrupt observation | Explicit handle operation |
| `Download.cancel` | `download.cancel` workflow calls a pending native handle belonging to the exact Page once; strict downloadId/source/cancelReturned receipt, with no inferred transfer termination | Actual SDK/Keeper execution and complete handle lifecycle unverified; completed, Fetch and foreign-Page handles are refused |
| `Download.delete` | Internal temporary-file cleanup after save | Explicit deletion of only that handle's temporary files |

## Current evidence and next work

The current Dashboard source renders personal-browser caller/Space observations
and separate server-owned Automation/Stagehand session observations. It decodes
an Ego user-owned-name refusal without discarding healthy clients. Owned-session
registration does not imply an open browser, and those session observations do
not identify a current caller. Component tests and frontend build manifests are
not installed or rendered UI proof.

Recent local checks exercise the actual workflow/Release codecs and production
JavaScript with SDK stand-ins. Cancellation component checks also use the actual
OCaml-emitted download watcher and pinned upstream Download classes with fake
CDP/filesystem services. These confirm component contracts, not a real native
transport, current Keeper execution or login. Native evaluation/navigation
error flags remain diagnostic data and do not replace validated effect progress.


A native workflow Fetch can request binary output with
`{"method":"fetch","url":"/api/report.pdf","options":{"saveAs":"report.pdf"}}`.
The filename is metadata; no directory or host path is accepted. Ego performs
the browser-context fetch and native save. A validated receipt carries
`source="fetch"`, `downloadId` and the requested `suggestedFilename`, without
`savedPath`. Native download-event rows use `source="native_download"` instead.
The same tab's download reader verifies the saved file, then uses the existing
worker snapshot/grant and host artifact-publication path. A snapshot marker is
not a finalized artifact or a host file-read grant.

HTTP error status and completed binary save are separate observations. A later
workflow step or snapshot failure does not remove an already completed save
from the living SDK process's registry. Retrieve it without repeating Fetch.
Failed, malformed or lost save receipts never establish file completion from
path existence; partial/unknown files are retained. The in-memory registry does
not provide durable reconciliation across worker/session replacement.
Standalone tests execute production workflow JavaScript with an SDK stand-in
and actual temporary bytes, plus the actual request/receipt codecs. These do
not prove real browser CORS/auth, the full worker/host artifact route or installed
Keeper/UI behavior.

An [isolated real-model Keeper metadata probe](../evidence/ego-keeper-native-metadata/README.md)
at source `d840b7978ce01ca0afdb1f4fcdedce0d4596e991` completed one exact-client
`BrowserAct(space_status)` against installed Ego and published the actual Keeper
caller in a retained host observation. Main chat completion and this individual
metadata success are verified separately from a failed validation controller.
The candidate had no Dashboard assets; later UI-publication source, visible UI,
login and full SDK support are not proven by that probe.

The rich-input and Page-code probes run the production workflow JavaScript in an
owned real Ego Space against local fixtures. They exercise native input, browser
code and JSON separation, app-state wait, browser POST exactly once, CORS failure,
timeout and stop-before-following-step behavior. The actual OCaml codec decodes
the captured receipt against its exact request. These are not installed Keeper or
visible MASC TUI proof.

The first probe Space (24) was absent on a later SDK read. After explicit user approval,
the same ongoing Goal resumed validation in replacement Space **27**. No existing
operator or Keeper Space was adopted. Space 27 subsequently also returned
`task space not found` and was absent from `listTaskSpaces`. The probes do not
call `finish` or close their Space. The user initially reported not closing it,
and later reported one termination without identifying which loss it explains.
The local deletion cause remains unproven. After the user authorized recreating
missing Spaces, validation continued in Space **32**. That Space was handed to
the user after the operator reported that its page was absent from the Ego UI.
SDK existence and a rendered Page screenshot do not establish visible UI access.

The options/selection workflow source has standalone codec and Node forwarding
checks. After the first attempt stopped because Space 27 was absent, Space 32
executed 22 option/selection steps and five mouse/state-wait steps. See the
[captured SDK receipts and explicit limits](../evidence/2026-10-26-ego-options/README.md).
This is primitive SDK evidence; installed MASC/Keeper and visible UI results
remain unverified. It does not cover every SDK option combination.

The [public Space guide](https://lite.ego.app/document/en/docs/space) describes
the default model as a Space inside the same UI browser process, while
[Quick start](https://lite.ego.app/document/en/docs/quick-start#watch-and-take-over)
instructs the user to select a Space through the top-right management panel.
An [official-repository lifetime reply](https://github.com/citrolabs/ego-lite/issues/496#issuecomment-6291041032)
documents 30-minute idle auto-close for agent-created, unpinned, still-agent-owned
Spaces. Pinned/user-created/handed-off/completed Spaces have different policies;
listing alone is not a keepalive. Do not infer visible UI, indefinite persistence
or local deletion cause from the SDK handle alone.

MASC source now tracks reads, waits within workflows and navigation alongside
input, and retains caller-specific last results. Native Ego cursor labels cover
pointer actions. Native Ego read/wait visibility remains a gap: extra synchronous
pre/post CLI calls were rejected because they can delay command execution and
receipt delivery.

The Goal remains incomplete while any required SDK, Space, selection, recovery,
installed Keeper or actual UI evidence is missing. See
[`tui-browser-lanes.md`](tui-browser-lanes.md) for the current product flow.

The Page context contract follows the pinned SDK's
[`TabInventoryItem`](https://github.com/citrolabs/ego-lite/blob/aecc5831fc5a9ea01a078b632185992a3a7ac448/package/ego-browser/src/page-model.ts#L401).
Each Ego tab carries `egoPage: {label, targetId, openedBy}`; `label: null` means
unmanaged, and `openedBy` is exactly `agent` or `unknown`. An unknown origin does
not mean the user created the tab. The same context survives partial inventories
and document projection. These observations grant no adoption, takeover or close
authority. The TUI changes are source integration; visible behavior is unverified.

A pending input may be resumed through the private operator confirmation form.
This records a human check/reset assertion for the exact connected Space and
pending generation, not an SDK cleanup acknowledgement. It does not provide native release acknowledgement, prove login/visible UI, or
persist pending input through worker replacement. Receipt-less holding workflows
stop without inferring release from Page.info; ordinary void typing also requires
explicit operator recovery. Current exact-source build/test
receipts must be checked separately from installed Keeper and real SDK proof.
