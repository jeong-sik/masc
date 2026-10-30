---
name: browser-automation
description: Use the owned Gecko automation browser for locate observations, uploads and downloads.
---

Owned Gecko can answer `BrowserInstruct` `action = "observe"` when this
installation selects the `locate` Exact Output. Repeat its observed
`lane = "automation"` and `tabId`; supply an optional `instruction`. The model
chooses only observed node IDs. The worker checks the original document and
target meaning again and returns fresh node observations with a separate
`inference` explanation. A match is not a click or permission to act. Preserve
its documentId/nodeId and perform the normal guarded interaction only when the
user's task authorizes it. A truncated scene does not establish that every match
was found. If locate is disabled or its model route is unavailable, inspect that
configuration rather than moving the tab to another browser.

Uploads use `BrowserAct` `action = "upload"` on an owned Gecko tab
(`lane = "automation"`) with the observed `tabId`. The host must first
authorize and snapshot the requested files through the Keeper's file-read
context. A raw path is not that authority. Never invent an `uploadId` or reuse
a grant from another call.

For owned Gecko downloads, use `BrowserRead` with `mode = "downloads"` and the
observed automation lane and tab ID. Read completed files only when their row
contains a finalized artifact; invoke its returned `keeper_artifact_read`
reader and arguments. Completion without that reference does not prove that
bytes were retained. Pending or failed downloads are not completed artifacts;
worker paths are not file-read grants.
