---
name: browser-navigate-content
description: Navigate an observed automation tab to a known HTTP(S) URL and read its landing-page visible content in one ordered composition. Use when no intermediate site decision is needed.
---

Invoke `keeper_compose_browser-navigate-content` with the observed automation
`tabId` and a URL already obtained from the page or the user's request. It is a
callable composition, not an instruction to load through `keeper_skill`.

The navigation receipt supplies the landing URL, including a redirect, to the
content read. Use the returned visible content if it answers the request. Read a fresh region map
and select a scope only when the returned coverage is insufficient. A URL acknowledgement does not prove application readiness: the site's
instruction still determines whether the title, regions and content answer the
requested context. An authentication page or unrelated redirect is unverified.

If navigation succeeded but the content read failed, retain the navigation node's
receipt. Retry only `BrowserRead` on the same automation tab; do not replay this
composition to recover a failed observation. If its URL changed again, read
without `expectedUrl`, inspect the actual destination, then pin its verified URL.

For a live browser, use the existing live-link composition after observing the
link's client/document/node identity. This composition uses an isolated
automation tab and does not attach to or create a live browser session.

```toml composition
[[compositions]]
name = "browser-navigate-content"
description = "Navigate one observed automation tab and return landing-page visible content. If only the read fails, retry BrowserRead, not navigation. Site content still needs verification."
execution = "inline"

[[compositions.params]]
name = "tabId"
type = "integer"
description = "Observed automation tab ID from BrowserTabs/Read."

[[compositions.params]]
name = "url"
type = "string"
description = "Known HTTP(S) destination from an observed link or the user."

[[compositions.nodes]]
id = "navigate"
tool = "BrowserGoto"
input = { kind = "object", fields = [
  { name = "tabId", value = { kind = "param", name = "tabId" } },
  { name = "url", value = { kind = "param", name = "url" } }
] }

[[compositions.nodes]]
id = "content"
tool = "BrowserRead"
after = ["navigate"]
input = { kind = "object", fields = [
  { name = "lane", value = { kind = "literal", value = "automation" } },
  { name = "tabId", value = { kind = "param", name = "tabId" } },
  { name = "mode", value = { kind = "literal", value = "scene" } },
  { name = "expectedUrl", value = { kind = "output", node = "navigate", pointer = "/url" } }
] }
```
