---
name: browser-ego
description: Observe and operate an ego lite task space through its snapshots, refs and native workflows.
---

When the selected client's transport is `ego_task_space`, start with
`BrowserRead` `mode = "snapshot"` (`snapshotScope = "viewport"`, the default),
and reuse its refs or observed Ego locators for input. Ego owns locator
resolution, actionability, automatic scrolling and frame/shadow traversal; do
not resolve a native target to coordinates or add a separate selector wait.
After page changes or a stale ref, read a fresh snapshot on the same page.

For actions already determined from that observation, use one `BrowserInteract`
`action = "workflow"` with `tabId`, initial `expectedUrl` and `steps`. Each step
names a native `method` such as `fill`, `click`, `waitForURL` or
`waitForSelector`, with that method's fields. The SDK executes the known
sequence and returns one final snapshot. Split the call when intermediate
results require a new decision. Retain `completed` progress on failure and
never replay the sequence after uncertain effects.

Uploads use `BrowserAct` `action = "upload"` on the live ego connection
(`lane = "live"` with its observed `clientId`) and the observed `tabId`. The
host must first authorize and snapshot the requested files through the
Keeper's file-read context. A raw path is not that authority. Never invent an
`uploadId` or reuse a grant from another call.
