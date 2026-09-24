---
name: browser-navigate-read
description: "Automation lane only: navigate one observed tab to a known HTTP(S) URL, then read the landing page in the same call. Use it when no site decision is needed between navigating and reading. mode=scene returns visible content; mode=regions returns landmarks whose documentId/nodeId references scope a later BrowserRead. The read is pinned to the navigation's landing URL, redirect included. If navigation succeeded and only the read failed, do not call this again: retry BrowserRead alone on the same tab. If the URL changed again, read without expectedUrl and check the actual destination before using its URL. A matching URL does not show the site is ready or right: check title and content; a login page or unrelated redirect stays unverified. This tool does not act on the operator's live browser: to follow an observed link there, use keeper_compose_browser-live-follow-read when your tool list has it."
---

This package declares the callable tool `keeper_compose_browser-navigate-read`:
`BrowserGoto` on an observed automation tab, then `BrowserRead` on the same tab
guarded by the navigation receipt's landing URL. The caller picks the read with
`mode`.

This body is not sent to a Keeper. The tool description a Keeper reads is the
TOML `description` with the parameter descriptions. Capability search matches
and returns the frontmatter `description`, so it holds the same text. The
recovery rules a Keeper needs (retry only the read, verify site content)
therefore live in that description. The
live-browser counterpart is `browser-live-follow-read`; the broader navigation
guidance is in `browser-lanes/references/composition.md`.

```toml composition
[[compositions]]
name = "browser-navigate-read"
description = "Automation lane only: navigate one observed tab to a known HTTP(S) URL, then read the landing page in the same call. Use it when no site decision is needed between navigating and reading. mode=scene returns visible content; mode=regions returns landmarks whose documentId/nodeId references scope a later BrowserRead. The read is pinned to the navigation's landing URL, redirect included. If navigation succeeded and only the read failed, do not call this again: retry BrowserRead alone on the same tab. If the URL changed again, read without expectedUrl and check the actual destination before using its URL. A matching URL does not show the site is ready or right: check title and content; a login page or unrelated redirect stays unverified. This tool does not act on the operator's live browser: to follow an observed link there, use keeper_compose_browser-live-follow-read when your tool list has it."
execution = "inline"
# Held back from Agent Core requests until keeper_tool_search names it: used
# in few turns a week, and its schema rode every request (2026-09-24).
defer_loading = true

[[compositions.params]]
name = "tabId"
type = "integer"
description = "Observed automation tab ID from BrowserTabs or BrowserRead."

[[compositions.params]]
name = "url"
type = "string"
description = "Known HTTP(S) destination taken from an observed link or the user's request, never guessed."

[[compositions.params]]
name = "mode"
type = "string"
enum = ["scene", "regions"]
description = "scene: visible content of the landing page. regions: landmark map whose references scope a later BrowserRead; choose it only when a region must be picked before reading."

[[compositions.nodes]]
id = "navigate"
tool = "BrowserGoto"
input = { kind = "object", fields = [
  { name = "tabId", value = { kind = "param", name = "tabId" } },
  { name = "url", value = { kind = "param", name = "url" } }
] }

[[compositions.nodes]]
id = "read"
tool = "BrowserRead"
after = ["navigate"]
input = { kind = "object", fields = [
  { name = "lane", value = { kind = "literal", value = "automation" } },
  { name = "tabId", value = { kind = "param", name = "tabId" } },
  { name = "mode", value = { kind = "param", name = "mode" } },
  { name = "expectedUrl", value = { kind = "output", node = "navigate", pointer = "/url" } }
] }
```
