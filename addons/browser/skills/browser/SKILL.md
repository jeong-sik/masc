---
name: browser
description: Use the installed browser Add-on to observe pages and perform guarded browser interactions.
---

Discover and choose browsers with the host browser tools (`BrowserTabs`,
`BrowserRead`, `BrowserSession` and the rest in a Keeper; `masc_browser_*` over
MCP). With no tab or document binding, the host chooses from the available
browsers without opening or navigating one. Keep `browserSelection.lane` and
`browserSelection.clientId` from the returned receipt and repeat that identity
for all work on its tabs/documents. An unavailable selection must not be
replaced silently.

For initial discovery, give the host tool `requiredActions` such as
`["hover","pointer_drag"]` when that work is needed. The host chooses a
compatible available connection or refuses before dispatch; it checks explicit
connections too. This capability declaration does not prove that a page
accepted an interaction. An explicitly named live connection must include its
observed client ID before creating a tab.

The exported `browser_command` tool runs one command on a browser you name:
`lane`, and for live its observed `clientId`. It chooses nothing and takes no
`requiredActions`. Tool arguments contain browser work, never caller identity
or a worker incarnation. The host supplies those.

Commands use `{"lane":"live","clientId":"<observed UUID>","command":
{"verb":"page.read","args":{"tabId":7,"maxChars":12000}}}`. Use
`page.scene`/`page.capture` before coordinate input. `page.interact` retains URL,
document and viewport guards; `page.act` supports the closed tab/frame action
set. Inputs, clicks, hover, drag, scrolling and keys all use the same selected
browser. Do not send JavaScript or raw debug protocol commands.

Owned Gecko can serve `page.locate` when this installation selects the `locate`
Exact Output. Repeat its observed `lane = "automation"` and `tabId`; supply an
optional `instruction`. The model chooses only observed node IDs. The worker
checks the original document and target meaning again and returns fresh node
observations with a separate `inference` explanation. A match is not a click or
permission to act. Preserve its documentId/nodeId and perform the normal guarded
interaction only when the user's task authorizes it. A truncated scene does not
establish that every match was found. If locate is disabled or its model route
is unavailable, inspect that configuration rather than moving the tab to another
browser. Model-backed act/extract require the observed `lane = "stagehand"`
and this installation's selected `stagehand` Exact Output. They do not move an
existing Gecko or live tab to Chrome. Availability depends on the configured
backend and host model route. These model commands are separate from native
`page.act` inputs.

Read the entire result before deciding the next action. `isError`, private
refusal disposition and backend partial-effect payloads have distinct meanings.
After a lost reply or unknown outcome, observe the original page before further
input. Never repeat a click, drag or tab creation merely because its reply failed.

Available work depends on the connected adapter and attached installation.
Native hosts connect through the authenticated workspace HTTP bridge; configured
owned Firefox, Gecko and Chrome backends start inside the attached worker.
Inspect inventory and configuration issues before choosing a connection.

Owned Gecko uploads use the public BrowserAct tool with the observed
`lane = "automation"` and `tabId`. The host must first authorize and snapshot
the requested files through the Keeper's file-read context. A raw path sent to
`browser_command` is not that authority. Never invent an `uploadId` or reuse a
grant from another call.

For owned Gecko downloads, read `page.downloads` with the observed automation
lane and tab ID, or use BrowserRead with `mode = "downloads"`. Read completed
files only when their row contains a finalized artifact; invoke its returned
`keeper_artifact_read` reader and arguments. Completion without that reference
does not prove that bytes were retained. Pending or failed downloads are not
completed artifacts; worker paths are not file-read grants.

Input validation, successful-output validation and model outputs are selected
independently by the installation. Turning these optional middleware off does
not change caller, upload, artifact, document, viewport or cleanup authority.
Source support and advertised capabilities do not prove that the current page
accepted an action. Confirm its result on the original connection.
