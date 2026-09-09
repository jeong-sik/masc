---
name: browser-live-click-regions
description: Click an already observed live Browser Lane link and return the resulting page regions in one ordered composition. Use after choosing a specific navigation target.
---

Use this composition after `browser-lanes` and the site's instruction Skill have
identified the exact link to follow. Pass the observed client, tab, document,
node, and current URL. This performs a click: loading the Skill does not itself
select a destination or authorize unrelated effects.

The click runs once. On success, its returned tabId feeds the read node, which
lists semantic regions currently observed in that tab. If the click fails, no read is dispatched.
Inspect both receipts and choose the actual content region with the site Skill;
then use BrowserRead mode=scene with its documentId/nodeId as scope. Do not reuse
the previous page's region reference after navigation or guess a region index.

This composition is for the live lane and requires its explicit clientId. For
automation, use BrowserInteract and BrowserRead directly. A completed click is
not proof that the page reached the requested channel; verify the resulting
URL, region labels and channel content. Reload the region list if the selected
node is replaced. Never replay a click solely because the following read failed.

```toml composition
[[compositions]]
name = "browser-live-click-regions"
description = "Click one observed live target, then read semantic regions currently observed in that tab."
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
value = "click"

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
```
