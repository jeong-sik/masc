---
name: browser-live-click-content
description: Follow an observed same-tab HTTP(S) anchor in a live browser and read its destination's visible content in one ordered composition. Use when the next page can be read without first choosing a region.
---

Invoke `keeper_compose_browser-live-click-content` with the observed live
`clientId`, `tabId`, `documentId`, `nodeId` and current `expectedUrl`. This is a
callable composition, not an instruction to load through `keeper_skill`.

The follow validates the actual anchor and navigates directly to its href in
that tab; it does not execute page click handlers. New-window targets,
downloads and non-HTTP(S) destinations are rejected before navigation. If the
task needs a site's click handler, use the observed control's ordinary click
action and inspect its result before deciding what to read.

The successor reads visible content at the follow receipt's `destinationUrl`,
preserving its `navigationSource`. Use the returned body when it answers the
request. When a region must be selected first, choose
`keeper_compose_browser-live-click-regions` instead. Do not invoke both by
convention. A matching URL does not establish site readiness or complete
history: the site's instruction determines whether title, target and content
match the request, and whether another scoped observation is needed.

If the follow succeeded but the read failed, retain the follow receipt and
retry only `BrowserRead` on its pinned client/tab. Preserve `navigationSource`
on every retry. For the same destination URL, preserve `expectedUrl` too: a
same-URL reload must expose a new document identity. To inspect a possible
redirect, omit only `expectedUrl` and verify the observed destination and
content before adopting its URL. An unchanged source URL/document is still
pending; an authentication page or unrelated destination is unverified.
Never replay the follow merely because observation failed.

```toml composition
[[compositions]]
name = "browser-live-click-content"
description = "Follow one observed live anchor and return URL-guarded visible content. Retry only the read after an observation failure; site content still needs verification."
execution = "inline"

[[compositions.params]]
name = "clientId"
type = "string"
description = "Observed live browser connection UUID."

[[compositions.params]]
name = "tabId"
type = "integer"
description = "Observed live browser tab."

[[compositions.params]]
name = "documentId"
type = "string"
description = "Observed document identity of the chosen link."

[[compositions.params]]
name = "nodeId"
type = "string"
description = "Observed same-tab anchor identity, never a guessed selector."

[[compositions.params]]
name = "expectedUrl"
type = "string"
description = "Current observed URL before following the link."

[[compositions.nodes]]
id = "click"
tool = "BrowserInteract"
input = { kind = "object", fields = [
  { name = "lane", value = { kind = "literal", value = "live" } },
  { name = "action", value = { kind = "literal", value = "follow_link" } },
  { name = "clientId", value = { kind = "param", name = "clientId" } },
  { name = "tabId", value = { kind = "param", name = "tabId" } },
  { name = "documentId", value = { kind = "param", name = "documentId" } },
  { name = "nodeId", value = { kind = "param", name = "nodeId" } },
  { name = "expectedUrl", value = { kind = "param", name = "expectedUrl" } }
] }

[[compositions.nodes]]
id = "content"
tool = "BrowserRead"
after = ["click"]
input = { kind = "object", fields = [
  { name = "lane", value = { kind = "literal", value = "live" } },
  { name = "clientId", value = { kind = "param", name = "clientId" } },
  { name = "tabId", value = { kind = "output", node = "click", pointer = "/tabId" } },
  { name = "mode", value = { kind = "literal", value = "scene" } },
  { name = "expectedUrl", value = { kind = "output", node = "click", pointer = "/destinationUrl" } },
  { name = "navigationSource", value = { kind = "output", node = "click", pointer = "/navigationSource" } }
] }
```
