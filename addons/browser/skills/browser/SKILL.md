---
name: browser
description: Use the installed browser Add-on to observe pages and perform guarded browser interactions.
---

Use the host browser tools: `BrowserTabs`, `BrowserRead`, `BrowserSession`,
`BrowserGoto`, `BrowserAct`, `BrowserInteract` and `BrowserInstruct` in a
Keeper, `masc_browser_*` over MCP. The available `browser-lanes` skill
describes their fields. The Add-on worker's own command port is called by the
host only and is not one of your tools.

With no tab or document binding, the host chooses from the available browsers
without opening or navigating one. Keep `browserSelection.lane` and
`browserSelection.clientId` from the returned receipt and repeat that identity
for all work on its tabs/documents. An unavailable selection must not be
replaced silently.

When browser workers are ambiguous, call `BrowserTabs` with
`{"mode":"connections"}` alone. This reads worker metadata across the
installations visible to you, without Page calls or opening a session. Inspect
`inventoryIssues` and `inventoryComplete`, then name the observed live UUID for
tab discovery and later work. Duplicate UUIDs are excluded from selectable
clients. An incomplete list is not evidence that no browser exists. These
sequential observations do not grant control; later explicit calls revalidate
the original connection. Do not mix this mode with a lane, tab or requirements.

For initial discovery, give `BrowserTabs`, or `BrowserSession` with
`action = "open"`, the `requiredActions` the work needs, such as `["hover","pointer_drag"]`. The host
chooses a compatible available connection or refuses before dispatch; it checks
explicit connections too. This capability declaration does not prove that a
page accepted an interaction. An explicitly named live connection must include
its observed client ID before creating a tab.

When the selected client's transport is `ego_task_space`, start with
`BrowserRead` `mode = "snapshot"` (`snapshotScope = "viewport"`, the default),
and reuse its refs or
observed Ego locators for input. Ego owns locator resolution, actionability,
automatic scrolling and frame/shadow traversal; do not resolve a native target
to coordinates or add a separate selector wait. After page changes or a stale
ref, read a fresh snapshot on the same page.

For actions already determined from that observation, use one `BrowserInteract`
`action = "workflow"` with `tabId`, initial `expectedUrl` and `steps`. Each step
names a native `method` such as `fill`, `click`, `waitForURL` or
`waitForSelector`, with that method's fields. The SDK executes the known
sequence and returns one final snapshot. Split the call when intermediate
results require a new decision. Retain `completed` progress on failure and
never replay the sequence after uncertain effects.

The current SDK's `keyboard.type` returns no action receipt, whether typing ran
to its end or a dialog interrupted it. A native workflow reads the Page's event
buffer around that step. With no `Page.javascriptDialogOpening` event the step
completes with receipt `null` and the workflow continues. With one, even when
the dialog is already closed, the workflow stops at that step, excludes it from
`completed` and leaves input release unconfirmed. Answer the dialog and read the
page, then use the private operator recovery described below before a distinct
next input. Do not repeat typing or silently substitute another input method.
A later `events` step still returns the events the workflow read for this check.

When the work needs the page's markup, `BrowserRead` `mode = "html"` returns
the top document's source (`outerHTML`) for an observed `tabId`, without
`maxChars`. It is never cut: when the JSON reply would pass 1 MiB, `html` is
`null` with `htmlComplete: false` and
`htmlUnavailableReason = "document_html_exceeds_1_mib"`.
A live extension or BiDi connection and automation Firefox serve it; ego and
Stagehand refuse it before dispatch.

Use `BrowserRead` `mode = "scene"` or `"screenshot"` before coordinate input.
`BrowserInteract` retains URL, document and viewport guards; `BrowserAct` serves
the closed tab/frame action set. Inputs, clicks, hover, drag, scrolling and keys
all use the same selected browser. There is no JavaScript or raw debug protocol
command.

Owned Gecko can answer `BrowserInstruct` `action = "observe"` when this
installation selects the `locate` Exact Output. Repeat its observed
`lane = "automation"` and `tabId`; supply an optional `instruction`. The model
chooses only observed node IDs. The worker checks the original document and
target meaning again and returns fresh node observations with a separate
`inference` explanation. A match is not a click or permission to act. Preserve
its documentId/nodeId and perform the normal guarded interaction only when the
user's task authorizes it. A truncated scene does not establish that every match
was found. If locate is disabled or its model route is unavailable, inspect that
configuration rather than moving the tab to another browser. Model-backed
`BrowserInstruct` `act`/`extract` require the observed `lane = "stagehand"` and
this installation's selected `stagehand` Exact Output. They do not move an
existing Gecko or live tab to Chrome. Availability depends on the configured
backend and host model route.

Read the entire result before deciding the next action. `isError`, private
refusal disposition and backend partial-effect payloads have distinct meanings.
After a lost reply or unknown outcome, observe the original page before further
input. Never repeat a click, drag or tab creation merely because its reply failed.

Available work depends on the connected adapter and attached installation.
Native hosts connect through the authenticated workspace HTTP bridge; configured
owned Firefox, Gecko and Chrome backends start inside the attached worker.
Inspect inventory and configuration issues before choosing a connection.

Uploads use `BrowserAct` `action = "upload"` on an owned Gecko tab
(`lane = "automation"`) or on a live ego connection (`lane = "live"` with its
observed `clientId`), with the observed `tabId`. Other connections refuse it
before any effect. The host must first authorize and snapshot the requested files through the
Keeper's file-read context. A raw path is not that authority. Never invent an
`uploadId` or reuse a grant from another call.

For owned Gecko or Ego downloads, read `page.downloads` with the observed
lane/client and tab ID, or use BrowserRead with `mode = "downloads"`. Read completed
files only when their row contains a finalized artifact; invoke its returned
`keeper_artifact_read` reader and arguments. Completion without that reference
does not prove that bytes were retained. Pending or failed downloads are not
completed artifacts; worker paths are not file-read grants.

An Ego workflow `fetch` step can set `options.saveAs` to an artifact filename
such as `report.pdf`, without a directory or control characters. Ego performs
the browser-context fetch and binary save to a fresh private path. The step
receipt returns `source: "fetch"`, `downloadId` and the requested
`suggestedFilename`; it exposes no saved host path. Retrieve that ID through
the same connection/tab's download reader and use only its finalized artifact.
A saved HTTP error response still has `ok: false`; inspect the HTTP status.
If a later step or final snapshot fails, an already completed save remains in
that SDK process's download inventory. Read it without repeating fetch.
An interrupted save has no completed artifact. Registry recovery after SDK
process/worker replacement is not implemented; retained files alone are not
proof of completion or permission to adopt them.

Input validation, successful-output validation and model outputs are selected
independently by the installation. Turning these optional middleware off does
not change caller, upload, artifact, document, viewport or cleanup authority.
Source support and advertised capabilities do not prove that the current page
accepted an action. Confirm its result on the original connection.

To inspect who owns the already bound Ego Space, send `page.act` with
`{"action":"space_status"}` on that exact live client. It reads native Space
metadata only, even when delegated to the operator, without Page calls, claim,
takeover or input reset. The receipt carries current SDK name/ownership and
`observedAt`; these observations do not establish permission or login success.
The private operator form displays the last cached SDK observation and its date.
Control-changing calls and failed refreshes invalidate that cache.

After the operator explicitly completes a handed-off step, `take_over` on the
same client returns the native user-boundary Page as `activeTabId`/`egoPage`.
It can be unmanaged (`label:null`); explicitly `adopt_tab` the observed ID
before reading it. Takeover does not adopt, read a document, clear uncertain
input or prove login/current focus. An absent boundary Page stays absent.
A changed or lost boundary result does not authorize another active tab,
another Space or automatic takeover replay. Confirm login with a fresh read
of the intended managed Page. Explicit input/navigation/activation can
then use an adopted native Page without changing its origin.

If an Ego result says input release is unconfirmed, keep the original connection
and do not replay its command. Answer any JavaScript dialog separately. Ask the
operator to check/reset key and button state in that Space and use this Browser
installation's private operator controls to confirm completion. The confirmation
applies only to the pending input generation; `inputReadiness=operator_asserted`
identifies its source on subsequent receipts. It is not SDK cleanup proof,
login completion, takeover permission or a model-callable reset action. After a lost
confirmation reply, inspect the original installation and read its form if the
same worker is still available. Never apply its old confirmation to a replacement
connection or replay browser input.
