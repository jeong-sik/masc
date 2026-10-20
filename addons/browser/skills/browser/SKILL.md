---
name: browser
description: Use the installed browser Add-on to observe pages and perform guarded browser interactions.
---

Use the exported `browser_command` tool. Tool arguments contain browser work,
never caller identity or a worker incarnation. The host supplies those.

Start with `{"command":{"verb":"tabs.list","args":{}}}`. With no tab or
document binding, the worker chooses from available browsers without opening or
navigating one. Keep `browserSelection.lane` and `browserSelection.clientId` from
the returned receipt. Repeat that identity for all work on its tabs/documents.
An unavailable selection must not be replaced silently.

For initial discovery, add `"requiredActions":["hover","pointer_drag"]` next to
`command` when that work is needed. The worker chooses a compatible available
connection or refuses before dispatch; it checks explicit connections too.
This capability declaration does not prove that a page accepted an interaction.
An explicitly named live connection must include its observed client ID before
creating a tab.

Commands use `{"lane":"live","clientId":"<observed UUID>","command":
{"verb":"page.read","args":{"tabId":7,"maxChars":12000}}}`. Use
`page.scene`/`page.capture` before coordinate input. `page.interact` retains URL,
document and viewport guards; `page.act` supports the closed tab/frame action
set. Inputs, clicks, hover, drag, scrolling and keys all use the same selected
browser. Do not send JavaScript or raw debug protocol commands.

Read the entire result before deciding the next action. `isError`, private
refusal disposition and backend partial-effect payloads have distinct meanings.
After a lost reply or unknown outcome, observe the original page before further
input. Never repeat a click, drag or tab creation merely because its reply failed.

Available work depends on the connected adapter. Native hosts connect through
the authenticated workspace HTTP bridge. Owned-browser startup and file-transfer
brokers are still being integrated. Upload paths and download listing are currently refused by this
tool before dispatch. This package is not yet an operator browser replacement.
