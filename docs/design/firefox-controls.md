# Firefox interaction support

BrowserRead with `mode=elements` observes visible controls in live and automation
Firefox. It returns tab identity, page URL/title, generated CSS selectors, control
state and select options. Password and file input values are omitted. The list
is capped at 200 controls and reports truncation; this is a DOM observation, not
a screenshot or a complete accessibility tree.

BrowserAct operates automation Firefox. It defaults to `lane=automation`; the
live extension remains read-only in this increment. BrowserSession opens an
isolated Firefox profile. BrowserAct `open_tab` creates a task's tab and returns
its id. Use that id for subsequent actions and reads, and close that tab when
finished. Session close shuts down the shared browser, so callers must not close
a session another task is using.

```text
BrowserSession {"action":"open"}
BrowserAct {"action":"open_tab","url":"https://example.org/"}
BrowserRead {"lane":"automation","tabId":<returned id>,"mode":"elements"}
BrowserAct {"action":"click","tabId":<returned id>,"selector":<observed selector>}
BrowserRead {"lane":"automation","tabId":<returned id>}
```

| Action | Required fields beyond action/lane |
|---|---|
| open_tab | url (absolute HTTP(S)) |
| click | tabId, selector |
| fill | tabId, selector, text (empty clears) |
| press | tabId, selector, key |
| select | tabId, selector, value (exact option value) |
| scroll | tabId, x, y (pixel deltas) |
| back / forward / reload / close_tab | tabId |

Click/fill/press/select require exactly one matching element. Native WebDriver
click, clear and send-keys perform the interaction; strings travel as JSON
arguments. BrowserGoto now honors optional `tabId`. Each targeted automation
operation holds the session lock from tab selection through completion. Tab IDs
remain unique across session reopenings for the lifetime of the driver, so old
IDs cannot silently select a new session's tab.

Parse, closed-target and selector failures before a mutation are distinguishable
from failures after issuing a mutation. The former permit correction; a timeout
or failed mutating request can have already taken effect and must be observed
before retry. A successful interaction reports completion of the command;
BrowserRead verifies the resulting page separately.

The implementation follows the [WebDriver interaction commands](https://www.w3.org/TR/webdriver/#element-interaction)
and [window commands](https://www.w3.org/TR/webdriver/#command-contexts).
Firefox is driven through Mozilla's [geckodriver](https://firefox-source-docs.mozilla.org/testing/geckodriver/).

Validation lives in `test_browser_controls`, `test_browser_webdriver`,
`test_browser_lane`, and the tool registry tests. CI build/test results and live
Firefox measurements must be recorded independently. Frame/shadow root targeting, dialogs and download/upload workflows are separate capability
increments; this document does not claim them implemented.

## Screenshot to Vision

`BrowserRead {"lane":"automation","tabId":73,"mode":"screenshot"}` captures
the selected viewport as PNG. The same mode supports live Firefox through
`tabs.captureTab`, without switching the operator's active tab. A changed URL across
capture is rejected; same-URL page changes are not detected by this guard. The tool returns URL/title, dimensions and an
`artifact` handle; `keeper_analyze_image {"artifact":<handle>,"query":<question>}` loads
those stored pixels into the configured Vision reader. Encoded pixels do not
ride in the browser tool's text response. This does not inject screenshots
directly into the Keeper's own conversation.

The native host retains Mozilla's 1 MiB command limit and accepts bounded 8 MiB
replies, enough for the default 5 MiB Vision image after base64 encoding. The
extension rejects oversized replies before writing a frame. Vision image size
and format validation apply before persistence. This is a viewport capture,
not a stitched full-page screenshot. See [Mozilla captureTab](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/API/tabs/captureTab)
and [native message framing](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/Native_messaging).

Screenshots require the authenticated in-process Keeper context. Generic tool
dispatch does not treat an agent display name as Keeper ownership. The live
8 MiB transport bound is independent of a larger configured Vision image limit.
