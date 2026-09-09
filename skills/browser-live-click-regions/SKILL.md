---
name: browser-live-click-regions
description: Follow an observed same-tab HTTP(S) link, then read URL-guarded regions in one ordered composition. Use after choosing a specific navigation target.
---

Invoke `keeper_compose_browser-live-click-regions` from the tool catalog with
an observed same-tab HTTP(S) anchor reference. This callable composition is not
an instruction available through keeper_skill.

Follow_link validates the actual anchor target and href before navigating
straight to that href in the pinned tab; it does not execute page click handlers.
New-window targets, downloads and non-HTTP URLs are rejected before effects.
The successor read requires the observed destinationUrl. An old URL returns a
transition error while preserving the follow receipt. Read the same pinned tab
without expectedUrl while retaining navigationSource to inspect its actual URL and regions; BrowserTabs can also
confirm the tab identity. If the URL remains urlBefore, navigation may still be
pending. A different URL may be a redirect, canonical URL or authentication page;
it is not automatically accepted as the destination. Verify workspace, channel,
title and actual content using the site instruction. Only after verification,
use the newly observed URL as expectedUrl for subsequent reads. A login page or
unrelated destination remains unverified. Never repeat the original permanently
mismatched guard or replay navigation because the read failed.

For a same-URL follow, the read also requires a different document identity
from navigationSource. Preserve that receipt with expectedUrl when retrying
BrowserRead; do not remove this guard to accept the pre-reload document.
A different destination URL may stay in the same document (SPA navigation).

A matching URL is only a URL acknowledgement. Slack may still show the previous
channel or loading content. Use slack-web instructions to verify channel title
and actual messages; reobserve without navigation until evidence identifies the
requested channel. This does not promise application readiness or complete history.

```toml composition
[[compositions]]
name = "browser-live-click-regions"
description = "Follow one observed same-tab anchor; return regions only at its intended URL. Matching URL still requires site-content verification."
execution = "inline"

[[compositions.params]]
name = "clientId"
type = "string"
description = "Observed live browser connection UUID."

[[compositions.params]]
name = "tabId"
type = "integer"
description = "Observed browser tab."

[[compositions.params]]
name = "documentId"
type = "string"
description = "Document identity of the chosen link."

[[compositions.params]]
name = "nodeId"
type = "string"
description = "Observed link identity, never a guessed CSS path."

[[compositions.params]]
name = "expectedUrl"
type = "string"
description = "Current observed URL before clicking."

[[compositions.nodes]]
id = "click"
tool = "BrowserInteract"
[compositions.nodes.input]
kind = "object"

[[compositions.nodes.input.fields]]
name = "clientId"
[compositions.nodes.input.fields.value]
kind = "param"
name = "clientId"

[[compositions.nodes.input.fields]]
name = "tabId"
[compositions.nodes.input.fields.value]
kind = "param"
name = "tabId"

[[compositions.nodes.input.fields]]
name = "documentId"
[compositions.nodes.input.fields.value]
kind = "param"
name = "documentId"

[[compositions.nodes.input.fields]]
name = "nodeId"
[compositions.nodes.input.fields.value]
kind = "param"
name = "nodeId"

[[compositions.nodes.input.fields]]
name = "expectedUrl"
[compositions.nodes.input.fields.value]
kind = "param"
name = "expectedUrl"

[[compositions.nodes.input.fields]]
name = "lane"
[compositions.nodes.input.fields.value]
kind = "literal"
value = "live"

[[compositions.nodes.input.fields]]
name = "action"
[compositions.nodes.input.fields.value]
kind = "literal"
value = "follow_link"

[[compositions.nodes]]
id = "regions"
tool = "BrowserRead"
after = ["click"]
[compositions.nodes.input]
kind = "object"

[[compositions.nodes.input.fields]]
name = "lane"
[compositions.nodes.input.fields.value]
kind = "literal"
value = "live"

[[compositions.nodes.input.fields]]
name = "clientId"
[compositions.nodes.input.fields.value]
kind = "param"
name = "clientId"

[[compositions.nodes.input.fields]]
name = "tabId"
[compositions.nodes.input.fields.value]
kind = "output"
node = "click"
pointer = "/tabId"

[[compositions.nodes.input.fields]]
name = "mode"
[compositions.nodes.input.fields.value]
kind = "literal"
value = "regions"
[[compositions.nodes.input.fields]]
name = "expectedUrl"
[compositions.nodes.input.fields.value]
kind = "output"
node = "click"
pointer = "/destinationUrl"
[[compositions.nodes.input.fields]]
name = "navigationSource"
[compositions.nodes.input.fields.value]
kind = "output"
node = "click"
pointer = "/navigationSource"
```
