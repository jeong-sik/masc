# Browser navigation with its next observation

The three-channel fixture used three `BrowserGoto` calls followed by three
`BrowserRead mode=regions` calls before the model selected each message region.
The landing acknowledgement did not need a separate model decision in this
workflow. The following scoped content read still does.

`browser-navigate-read` declares that pair through MASC's existing inline
composition grammar. It takes an observed automation tab, a known URL and a
read `mode`, then binds the navigation receipt's landing URL into the read. The model sees
the ordered node results, and the runtime retains each node's execution record.
If observation fails after navigation, the completed navigation receipt remains
the recovery source: retry only the read. A redirect or a matching URL does not
establish that the site's requested content is ready.

`mode` is a closed choice of `scene` and `regions`. `mode=regions` returns the
region map for a later scoped read. `mode=scene` reads the landing page's
visible content and serves pages whose visible body can already answer the
request. The model checks that content and asks for a region map or a scoped
read when coverage is insufficient. The two modes are alternatives selected for
the page and task; a successful content read does not require another region
read by convention. `BrowserRead` itself accepts more modes; a value outside
the two is refused by Agent-Core's input-schema check before the composition
runs any node.

The committed
[three-channel native experiment](../evidence/browser-readable-20260913/README.md)
ran an earlier declaration with the same nodes as the `mode=scene` route but a
fixed mode and its own name and description: six outer calls, three
compositions and no tool errors. It did not exercise this tool's description or
`mode` schema. Those measurements establish that route's observed behavior, not
universal speed or completeness on every site. The instruction and runtime revisions of that capture remain recorded
separately from this package change.

The `BrowserGoto` descriptor declares the `url` and `title` object produced by
`Browser_webdriver.page_summary`. Without that output contract, the Skill's
`/url` reference is rejected during catalog loading and its callable tool is
absent. The shipped Skill test parses the actual file against runtime descriptors,
then executes redirect, navigation-failure, malformed-receipt and read-failure
cases. A Skill file alone cannot supply a missing runtime output contract.

The live browser has `browser-live-follow-read`. It follows a verified
same-tab anchor and retains its source document guard. With `mode=scene` it
reads the destination body directly; with `mode=regions` it supports a
subsequent choice of scope. Site
instructions choose the needed observation and verify its content, without
guessing site selectors. These follow the href directly rather than executing
page click handlers, so their navigation semantics differ from an ordinary
control click and from automation `BrowserGoto`.

The live `mode=scene` route removes the required region-selection round trip
for a page whose visible body already answers the request. This describes the
call graph, not a measured latency improvement. Executor tests load both actual
Skill files in both modes and check pinned source identities, destination URL/document guards,
ordered dispatch, malformed receipts, and preservation of the completed follow receipt
without replaying navigation after a read failure. They do not prove that a
subsequent read retry was executed.

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
