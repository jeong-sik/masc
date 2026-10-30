# Measured WebExtension browser zoom

An isolated temporary addon in a fresh Firefox 158.0 profile executed the exact
candidate `pageZoom` function with real `browser.tabs.getZoom`,
`getZoomSettings`, and `setZoom` APIs. It created its own loopback fixture tab.
No operator browser, production profile, MASC host, or server was changed.

[Result](firefox-result.json) records native measurements:

| Factor | CSS viewport width | devicePixelRatio | Fixture CSS box width |
| --- | --- | --- | --- |
| 1 | 1366 | 1 | 200 |
| 1.5 | 911 | 1.5 | 200 |
| 0.75 | 1821 | 0.75 | 200 |

The receipt measured automatic/per-origin scope. A stale expected URL was
refused before effect and zoom remained 0.75. The [screenshot](firefox-zoom-out.png)
shows the owned fixture after zooming out; it was inspected directly.
[Source manifest](source-manifest.json) identifies the exact copied function.
The result's `sourceSha256` is the file from which that function was extracted,
not a claim that the entire final extension or MASC server was installed.

The actual extension dispatcher protocol suite covers validation, tab/URL
binding, measured receipts, cancellation, and post-dispatch unknown outcomes
without replay. Strict fresh-domain OCaml checks and focused adapter tests cover
parsing and rejection on unsupported adapters. These checks do not establish a
whole-server build or an end-to-end installed native-messaging session.

API contract: [MDN setZoom](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/API/tabs/setZoom),
[getZoom](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/API/tabs/getZoom),
and [getZoomSettings](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/API/tabs/getZoomSettings).
