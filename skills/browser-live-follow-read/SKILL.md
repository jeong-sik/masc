---
name: browser-live-follow-read
description: "Live lane only: follow one observed same-tab HTTP(S) anchor in the operator's browser, then read the destination in the same call. follow_link goes to the anchor's href without page click handlers; if the page needs its handler, use an ordinary BrowserInteract click. New-window targets and downloads are refused before navigating. mode=scene returns visible content; mode=regions returns landmarks whose references scope a later read. The read is pinned to the follow receipt's destinationUrl and navigationSource. If the follow succeeded and only the read failed, never call this again: retry BrowserRead alone on the same clientId/tabId with navigationSource. While a read still sees the source URL and document, the follow is still pending. For a same-URL follow keep expectedUrl too: a reload counts only with a new document identity. To inspect a redirect, drop only expectedUrl. A matching URL does not show the site is ready: check title and content; a login page or unrelated destination stays unverified."
---

This package declares the callable tool `keeper_compose_browser-live-follow-read`:
`BrowserInteract action=follow_link` on an observed anchor, then `BrowserRead`
on the same live client and tab, guarded by the follow receipt's
`destinationUrl` and `navigationSource`. The caller picks the read with `mode`.

This body is not sent to a Keeper. The tool description a Keeper reads is the
TOML `description` with the parameter descriptions. Capability search matches
and returns the frontmatter `description`, so it holds the same text. The follow
semantics and recovery rules a Keeper needs therefore live in that description.
The automation counterpart is `browser-navigate-read`; the broader navigation
guidance is in `browser-lanes/references/composition.md`.

```toml composition
[[compositions]]
name = "browser-live-follow-read"
description = "Live lane only: follow one observed same-tab HTTP(S) anchor in the operator's browser, then read the destination in the same call. follow_link goes to the anchor's href without page click handlers; if the page needs its handler, use an ordinary BrowserInteract click. New-window targets and downloads are refused before navigating. mode=scene returns visible content; mode=regions returns landmarks whose references scope a later read. The read is pinned to the follow receipt's destinationUrl and navigationSource. If the follow succeeded and only the read failed, never call this again: retry BrowserRead alone on the same clientId/tabId with navigationSource. While a read still sees the source URL and document, the follow is still pending. For a same-URL follow keep expectedUrl too: a reload counts only with a new document identity. To inspect a redirect, drop only expectedUrl. A matching URL does not show the site is ready: check title and content; a login page or unrelated destination stays unverified."
execution = "inline"

[[compositions.params]]
name = "clientId"
type = "string"
description = "Observed live browser connection UUID from BrowserTabs or BrowserRead."

[[compositions.params]]
name = "tabId"
type = "integer"
description = "Observed live tab that holds the link."

[[compositions.params]]
name = "documentId"
type = "string"
description = "Observed document identity of the page that holds the link."

[[compositions.params]]
name = "nodeId"
type = "string"
description = "Observed same-tab anchor identity from a scene read, never a guessed selector."

[[compositions.params]]
name = "expectedUrl"
type = "string"
description = "URL observed on the tab before following the link."

[[compositions.params]]
name = "mode"
type = "string"
enum = ["scene", "regions"]
description = "scene: visible content of the destination. regions: landmark map whose references scope a later BrowserRead; choose it only when a region must be picked before reading."

[[compositions.nodes]]
id = "follow"
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
id = "read"
tool = "BrowserRead"
after = ["follow"]
input = { kind = "object", fields = [
  { name = "lane", value = { kind = "literal", value = "live" } },
  { name = "clientId", value = { kind = "param", name = "clientId" } },
  { name = "tabId", value = { kind = "output", node = "follow", pointer = "/tabId" } },
  { name = "mode", value = { kind = "param", name = "mode" } },
  { name = "expectedUrl", value = { kind = "output", node = "follow", pointer = "/destinationUrl" } },
  { name = "navigationSource", value = { kind = "output", node = "follow", pointer = "/navigationSource" } }
] }
```
