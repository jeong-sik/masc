# Browser navigation with its next observation

The three-channel fixture used three navigations followed by three
`BrowserRead mode=regions` calls before the model selected each message region.
The landing acknowledgement did not need a separate model decision in this
workflow. The following scoped content read still does.

The live browser has `browser-live-follow-read`, declared through MASC's
existing inline composition grammar. It follows a verified same-tab anchor and
retains its source document guard, then binds the follow receipt's
`destinationUrl` and `navigationSource` into the read. The model sees the
ordered node results, and the runtime retains each node's execution record.
If observation fails after the follow, the completed follow receipt remains the
recovery source: retry only the read. A redirect or a matching URL does not
establish that the site's requested content is ready.

`mode` is a closed choice of `scene` and `regions`. `mode=regions` returns the
region map for a later scoped read. `mode=scene` reads the destination's
visible content and serves pages whose visible body can already answer the
request. The model checks that content and asks for a region map or a scoped
read when coverage is insufficient. The two modes are alternatives selected for
the page and task; a successful content read does not require another region
read by convention. `BrowserRead` itself accepts more modes; a value outside
the two is refused by Agent-Core's input-schema check before the composition
runs any node.

Site instructions choose the needed observation and verify its content, without
guessing site selectors. The follow opens the href directly rather than
executing page click handlers, so its navigation semantics differ from an
ordinary control click.

The `mode=scene` route removes the required region-selection round trip for a
page whose visible body already answers the request. This describes the call
graph, not a measured latency improvement. Executor tests load the actual Skill
file in both modes and check pinned source identities, destination URL/document
guards, ordered dispatch, malformed receipts, and preservation of the completed
follow receipt without replaying navigation after a read failure. They do not
prove that a subsequent read retry was executed.

This follows [agent-browser's navigation/observation chaining](https://agent-browser.dev/quick-start)
when intermediate output needs no decision. The pattern does not by itself
establish that one browser backend is superior.

Validation must distinguish model calls from underlying browser operations. On
the three-channel fixture the expected model-visible saving is three calls;
navigation and region observation still both execute. Measure the materialized
composition calls, ordered node records, returned scope/URL identities and actual
Keeper answer. Compare real elapsed observations without attributing model
latency differences to this composition from a single run. Slack is deferred.
