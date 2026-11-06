# Firefox interaction support

BrowserRead with `mode=elements` observes visible controls in live Firefox. It
returns tab identity, page URL/title, generated CSS selectors, control state and
select options. Password and file input values are omitted. The list is capped
at 200 controls and reports truncation; this is a DOM observation, not a
screenshot or a complete accessibility tree.

BrowserInteract carries input inside the page (click, fill, select, scroll,
keys) on an explicit live tab; see the
[action/source table](browser-lane.md#browser-controls) and
[Browser Lane examples](browser-lane-examples.md). BrowserAct carries
browser-level actions. A live BiDi connection serves `open_tab`, `open_window`,
and top-level `back`/`forward`/`reload`/`close_tab` only for a tab this
connection opened with `open_tab`. Use the returned tabId for later actions and
reads, and close that tab when finished.

Parse, closed-target and selector failures before a mutation are distinguishable
from failures after issuing a mutation. The former permit correction; a timeout
or failed mutating request can have already taken effect and must be observed
before retry. A successful interaction reports completion of the command;
BrowserRead verifies the resulting page separately.

Validation lives in `test_browser_bidi_peer`, `test_browser_interaction`,
`test_browser_lane`, and the tool registry tests. CI build/test results and live
Firefox measurements must be recorded independently. Shadow root targeting is a
separate capability increment. Frame and dialog behavior is described below.

## Read a screenshot

`BrowserRead {"lane":"live","clientId":<id>,"tabId":73,"mode":"screenshot"}`
captures the selected viewport as PNG. On the WebExtension it uses
`tabs.captureTab`, without switching the operator's active tab. A changed URL across
capture is rejected. Live capture also compares document identity, viewport
dimensions and scroll position before and after capture. Changes to pixels
without a corresponding viewport-identity change are not detected by that
guard. For a Keeper, the tool returns URL/title, dimensions and a Keeper-local
image `artifact` handle. Use that exact handle with
`keeper_image_read {"artifact":<handle>}` to load those stored pixels into the
current model's conversation without another model call. The browser
tool's text response carries the handle; a successful image read supplies the
image block. If an image block is already attached to the message, inspect it
directly.

Use `keeper_analyze_image {"artifact":<handle>,"query":<question>}` when the
current runtime capability and actual tool surface confirm that the image reader
was excluded for unavailable native image admission, after an explicit admission
rejection, or when another model's text interpretation is needed. Such exclusion
also covers deferred/discovery tools, so a rejected read is not a prerequisite.
An unloaded schema or unsuccessful tool search alone does not establish this
exclusion. Model/provider names, older skill guidance, file/artifact failures and
account quota errors do not establish unsupported image input either.

The native host retains Mozilla's 1 MiB command limit and accepts bounded 8 MiB
replies, enough for the default 5 MiB Vision image after base64 encoding. The
extension rejects oversized replies before writing a frame. Vision image size
and format validation apply before persistence. This is a viewport capture,
not a stitched full-page screenshot. See [Mozilla captureTab](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/API/tabs/captureTab)
and [native message framing](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/Native_messaging).

Screenshots require the authenticated in-process Keeper context. Generic tool
dispatch does not treat an agent display name as Keeper ownership. The live
8 MiB transport bound is independent of a larger configured Vision image limit.

## Frames and dialogs

A live BiDi `BrowserRead mode=frames` requires `tabId` and returns iframe/frame
selectors in the current document. Pass `framePath` as an outer-to-inner array of
those selectors for text/elements/frames reads and `BrowserInteract`
click/fill/select_option/scroll with a selector (there `expectedUrl` is the frame
document's URL). Each call selects its tab and frame chain itself; there is no
shared "selected frame" API. Cross-origin frames are entered through their own
BiDi browsing context. Omit the path to operate on the top-level page.
Screenshots remain whole tab viewports and do not accept framePath.

Each `list_tabs` row of a tab blocked on a JavaScript dialog carries `dialog`:
its type (alert, confirm, prompt or beforeunload), message and, for a prompt,
`defaultValue`. The message is whatever the page wrote. `BrowserAct
accept_dialog` accepts it, optionally supplying `text` for a prompt;
`dismiss_dialog` cancels it. Both apply only to a tab this connection opened
with `open_tab`: the person using the browser answers a dialog on their own tab.
They cover JavaScript dialogs, not arbitrary operating-system dialogs.
