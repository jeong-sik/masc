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

For owned Gecko downloads, use `BrowserRead` with `mode = "downloads"` and the
observed automation lane and tab ID. Read completed files only when their row
contains a finalized artifact; invoke its returned `keeper_artifact_read`
reader and arguments. Completion without that reference does not prove that
bytes were retained. Pending or failed downloads are not completed artifacts;
worker paths are not file-read grants.

Input validation, successful-output validation and model outputs are selected
independently by the installation. Turning these optional middleware off does
not change caller, upload, artifact, document, viewport or cleanup authority.
Source support and advertised capabilities do not prove that the current page
accepted an action. Confirm its result on the original connection.
