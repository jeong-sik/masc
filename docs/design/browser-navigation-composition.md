# Browser navigation with its next observation

The three-channel fixture used three `BrowserGoto` calls followed by three
`BrowserRead mode=regions` calls before the model selected each message region.
The landing acknowledgement did not need a separate model decision in this
workflow. The following scoped content read still does.

`browser-navigate-regions` declares that pair through MASC's existing inline
composition grammar. It takes an observed automation tab and a known URL, then
binds the navigation receipt's landing URL into the region read. The model sees
the ordered node results, and the runtime retains each node's execution record.
If observation fails after navigation, the completed navigation receipt remains
the recovery source: retry only the read. A redirect or a matching URL does not
establish that the site's requested content is ready.

`browser-navigate-content` uses the same ordered navigation boundary and reads
the landing page's visible content with `mode=scene`. It serves pages whose
visible body can already answer the request. The model checks that content and
asks for a region map or a scoped read when coverage is insufficient. The two
compositions are alternatives selected for the page and task; a successful
content read does not require another region read by convention.

This content route is the Skill used in the committed
[three-channel native experiment](../evidence/browser-readable-20260913/README.md):
six outer calls, three compositions and no tool errors. The current package
ships that previously experimental declaration. Those measurements establish
that route's observed behavior, not universal speed or completeness on every
site. The instruction and runtime revisions of that capture remain recorded
separately from this package change.

The `BrowserGoto` descriptor declares the `url` and `title` object produced by
`Browser_webdriver.page_summary`. Without that output contract, the Skill's
`/url` reference is rejected during catalog loading and its callable tool is
absent. The shipped Skill test parses the actual file against runtime descriptors,
then executes redirect, navigation-failure, malformed-receipt and read-failure
cases. A Skill file alone cannot supply a missing runtime output contract.

The live browser already has `browser-live-click-regions`, which follows a
verified same-tab anchor and retains its source document guard. Its input and
navigation semantics remain distinct. Site instructions decide what to read
from the resulting region map; neither composition guesses site selectors.

This follows [agent-browser's navigation/observation chaining](https://agent-browser.dev/quick-start)
when intermediate output needs no decision, and [Stagehand's reuse of observed
actions](https://docs.stagehand.dev/v3/basics/observe). These patterns do not by
themselves establish that one browser backend is superior.

Validation must distinguish model calls from underlying browser operations. On
the three-channel fixture the expected model-visible saving is three calls;
navigation and region observation still both execute. Measure the materialized
composition calls, ordered node records, returned scope/URL identities and actual
Keeper answer. Compare real elapsed observations without attributing model
latency differences to this composition from a single run. Slack is deferred.
