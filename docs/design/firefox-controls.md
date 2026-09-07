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
Firefox measurements must be recorded independently. Screenshots, frame/shadow
root targeting, dialogs and download/upload workflows are separate capability
increments; this document does not claim them implemented.
