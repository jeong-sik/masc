# Browser Lane

Browser Lane has one source, `live`: the Firefox the browser Add-on starts and
reaches over WebDriver BiDi, or an ego lite task space.

A live BiDi connection navigates only a tab it opened with `open_tab` (`BrowserGoto` with
`lane = "live"`, its `clientId` and that `tabId`). On the operator's own tabs
the live lane can follow an observed same-tab HTTP(S) anchor through
`BrowserInteract`.

Keeper browser tools use the same source state. They reject backend failures,
malformed envelopes, absent lanes and timeouts instead of reporting success.
These are Keeper tools; their in-process descriptors are separate from public
MCP tool registration.

The operator surface is authenticated independently of the connector:

| Endpoint | Request | Permission |
|---|---|---|
| POST `/api/v1/dashboard/browser-lane/read` | `lane`, optional `tabId` | Read state |
| POST `/api/v1/dashboard/browser-lane/goto` | `lane`, `clientId`, `tabId`, absolute HTTP(S) `url` | Operator admin token |

Read replies contain `tabs`, the selected `page`, `source` and measured
`elapsed_ms`. The page contains `tabId`, `url`, `title`, `text`, `chars` and
`truncated`. Text is capped at 50,000 Unicode code points by the operator
surface. Each explicit read obtains a fresh page observation.

The TUI has one `go Browser Lane` entry (`B` from Connectors). It lists all
open tabs of the selected source; `[` / `]` select a tab and `r` refreshes.
While the lane is visible, the existing TUI refresh cadence follows that
selected client and tab. It does not rediscover clients or switch to another
active tab. A scene refresh retains the operator's selected node and scroll
position while its document, URL and region remain the same. Accepted scene
observations also update the tab title and URL; returning to text reads the
current page instead of showing an earlier cached body.

A focused region is rechecked against the current region map before its body
is refreshed. If its document changed or the region is no longer observed,
the reader shows the new region map so the operator can select a current
region. It does not apply an old node reference to a replacement document.
An observation failure withdraws stale scene actions and preserves the typed
read intent for the next observation. Cadence reads are single-flight and
pause while a URL draft or client picker owns the surface. An open screenshot
uses viewport cadence instead of text/scene cadence; a held pointer pauses it.
Operator input takes priority over a cadence read. Its late result cannot
replace the operator's newer choice, and the actual in-flight request remains
tracked until completion so superseding a result cannot stack periodic reads.
The operator chooses pages by title and URL. Websites have no dedicated lanes
or app filters. Keeper tools use the same general browser capabilities.

See [Browser usage](browser-lane-examples.md) for reading logged-in work pages,
checking rendered application state, and gathering evidence across tabs.

## Browser controls

`BrowserInteract` requires an observed `tabId` and accepts these closed actions:

| Action | Observed target | Source |
|---|---|---|
| `click`, `fill` | `documentId`/`nodeId`, or one visible CSS `selector`; fill adds `text` | live |
| `follow_link` | `documentId`/`nodeId` for a same-tab HTTP(S) anchor | live |
| `scroll` | relative CSS pixels `x`/`y` | live |
| `hover` | `documentId`/`nodeId` or a unique `selector`, plus `expectedUrl`; resolves the current visible, unobstructed element without clicking | live BiDi |
| `drag_to` | `source` and `destination`, each `{documentId,nodeId}` or `{selector}`, plus `expectedUrl` | live BiDi |
| `hover_at` | normalized `point`, captured `viewport`, and `expectedUrl`; moves the trusted pointer without clicking | live BiDi |
| `click_at`, `scroll_at` | normalized `point` and captured `viewport`; scroll adds `x`/`y`; `click_at` also takes `button` (`primary` by default, `middle`, `secondary`) | live; a `middle` or `secondary` click needs live BiDi |
| `drag` | normalized `from`/`to` and captured `viewport`; trusted pointer press, move and release | live BiDi |
| `tap_at`, `swipe` | like `click_at` and `drag` (`point`, or `from`/`to` with `via` and `durationMs`), sent by a touch pointer | live BiDi |
| `set_viewport` | `expectedUrl`, and `width`/`height` in CSS pixels (100 to 4096) given together; with neither, live BiDi restores the browser's own size | live BiDi |
| `select_option` | `expectedUrl` is optional; a `selector` for one single-choice `<select>` and the exact `value` of one enabled option. A multiple select, a missing, repeated or disabled option, or a non-select element is refused before any effect. Sets the option and emits `input` and `change`; it is not a trusted click on the list | live |
| `activate_tab` | the selected live `clientId`/`tabId` | live; BiDi also focuses the window |

`BrowserRead mode=scene` supplies document-scoped node references and visible
content; `mode=regions` supplies semantic regions for a scoped scene read.
`mode=elements` supplies a control inventory when that extra detail is needed.
An optional `selector` reads explicit CSS matches, including non-control nodes
such as custom conversation rows. `within` independently limits the answer to
nodes matching a CSS scope or inside one. Both use document-level CSS semantics;
`within` is inclusive, and `:scope` refers to the document element. For example,
after observing a sidebar's selector and row semantics, read
`{"mode":"elements","within":"#inbox","selector":"[role=row]"}` with the
same lane/clientId/tabId binding. These selectors describe the fixture example,
not a contract for any particular chat application.

`selectorMatches` counts document-wide CSS matches before visibility and
`within` filtering; `withinMatches` counts scope roots. `total` counts the visible
intersection, and `elements` retains the existing 200-result cap. Zero matches
are a successful empty read. Invalid CSS is refused. Unfiltered reads still
return the control inventory. Explicit matches retain the same hidden-node,
input-value and disabled-state handling; password and file values are withheld.
A returned selector identifies an observed node and does not promise that the
page accepts a click or another action on it. Inspect the resulting page after
an interaction. Keepers must not infer selectors from names alone.

The browser must echo each requested filter and its nonnegative match count.
Live BiDi and ego use the same page observation script; their existing frame
and interaction limits still apply.

Use those observations rather than inventing selectors or node IDs. A node
reference and a CSS selector are alternative targets and cannot be combined.

Set `expectedUrl` to the observed URL to refuse an action after navigation.
Point actions also check the captured document and viewport. Semantic hover and drag resolve current rectangles and hit-test before any pointer input; they reject hidden, offscreen or obstructed targets without scrolling. Scroll and read again before retrying. Scene references reject replacement or a different document. Both drag targets must be in the same top document and current viewport. The result is an
action receipt; read or capture again to verify the site's resulting state.
Changing sources would select a different browser session and is not an
automatic fallback for a logged-in tab.

### What each live connection serves

The two live transports reach the browser differently, so each serves a
different part of the live lane's work. `Browser_lane.live_transport_serves`
is the one table; the server admits live work by it and the Keeper tools
build their rejection from it.

| Live work | Reached by | BiDi | ego |
|---|---|---|---|
| `tab_listing` | `BrowserTabs` | yes | yes, every tab in the task space |
| `text_read` | `BrowserRead mode=text` | yes | yes, only the pages the task space manages |
| `scene_read` | `BrowserRead mode=scene`/`regions` | yes | yes, only the pages the task space manages |
| `viewport_capture` | `BrowserRead mode=screenshot` | yes | yes, only the pages the task space manages |
| `element_inventory` | `BrowserRead mode=elements` | yes | yes, only the pages the task space manages |
| `document_source` | the `browser_document` Lane Add-on source | yes | yes, only the pages the task space manages |
| `dom_interaction` | `click`, `fill`, `scroll`, `follow_link` | yes | yes, on a native managed Page |
| `point_click` | `click_at` | yes, a trusted pointer | yes, on a native managed Page, ego's mouse |
| `trusted_button_click` | `click_at` with `button` `middle` or `secondary` | yes | yes, on a native managed Page |
| `trusted_double_click` | `double_click`, `double_click_at` | yes | yes, on a native managed Page |
| `trusted_keyboard` | `type_text`, `press_key` | yes | yes, on a native managed Page, ego's keyboard |
| `touch_input` | `tap_at`, `swipe` | yes | no |
| `viewport_resize` | `set_viewport` | yes | yes, a CDP override on a native managed Page that lasts while the ego SDK process that set it runs |
| `tab_history` | `back`, `forward`, `reload`, subject to the transport's Page authority | yes | yes, native managed Pages in the task space; back and forward through the page's CDP history |
| `tab_navigation` | `BrowserGoto`, subject to the transport's Page authority | yes | yes, native managed Pages in the task space |
| `tab_closing` | `close_tab`, subject to the transport's Page authority | yes | yes, only agent-created Pages; unknown-origin Pages use release_tab |
| `tab_creation` | `open_tab` | yes | yes |
| `dialog_answer` | `accept_dialog`, `dismiss_dialog`, subject to the transport's Page authority; the dialog is read from the tab's `list_tabs` row (`dialog`: type, message, defaultValue) | yes | yes, native managed Pages in the task space; an input that opens one answers with it |
| `frame_read` | `BrowserRead` text, elements and frames modes with `framePath` (observed outer-to-inner iframe selectors); a dialog is not read this way | yes | no; ego reads frames through `accessibility_snapshot` (its snapshot holds iframe content, and a subtree rooted at the iframe's ref reads one frame) and acts in them through `snapshot_target_input` |
| `download_listing` | `BrowserRead mode=downloads` with `tabId` | no, its downloads are the person's own | yes, the downloads a native managed Page started, saved in the worker's folder and returned as artifacts |
| `file_upload` | `BrowserAct upload` with the Keeper's files | no | yes, one CSS-matched file input on a native managed Page, or with `opener` the one control whose click opens the page's file chooser; the connection keeps the copies until its space ends |
| `environment_emulation` | `BrowserAct set_emulation`, `clear_emulation` | no | yes, CDP overrides of a native managed Page's location, locale (Intl only) and time zone while the ego SDK process that set them runs; a location also grants that origin geolocation in the ego profile |
| `point_scroll` | `scroll_at` | yes, a trusted wheel | yes, on a native managed Page, ego's wheel |
| `trusted_hover` | `hover`, `hover_at` | yes | yes, on a native managed Page |
| `trusted_drag` | `drag_to`, `drag` | yes | yes, zero duration on native managed Pages |
| `tab_activation` | `activate_tab` | yes, and it also focuses the window | yes, native managed Page and expectedUrl; native active/window observation without rendered UI or OS-focus proof |

The BiDi peer sends pointer and wheel input through the browser. Its
`activate_tab` uses
[`browsingContext.activate`](https://developer.mozilla.org/en-US/docs/Web/WebDriver/Reference/BiDi/Modules/browsingContext/activate),
which also gives the tab's window system focus.

The ego connection runs one fixed script per command in an ego lite task space
with `ego-browser nodejs` (RFC-browser-live-ego). Its reads run the same page
scripts as the other connections, so selectors and `within` mean the same
thing. Its tab IDs follow the page labels ego gives (`p1`, `p2`), which ego
keeps for the managed Page lifecycle. Unmanaged tabs are listed but refused
before reads or effects until explicitly adopted. Native managed Pages,
including adopted unknown-origin Pages, support input, navigation and activation
without changing their origin. Release unmanages an
unknown-origin Page without closing its tab; agent-created Pages must be closed.
All Page operations require the original agent-controlled Space, and adoption
never clears uncertain input. A load that fails after it started is answered as
a partial effect with where the tab is now. Snapshot refs can address iframe
content; explicit input frame paths remain unsupported. The page scripts the
BiDi peer runs find the target, check that
the observed document, URL and viewport are still there, and make the DOM edits,
so a selector or node means the same on both; ego's own mouse and keyboard
input clicks, hovers, scrolls at a point and types. Finding a target and acting
on it are two runs that share the command's window.

Native adapters share the semantic pointer decoder for observed geometry and
URL. BiDi and ego also share the action classification. Native drag adapters share the intermediate
waypoint calculation; each retains its own native input and release handling.

Ego serves `drag_to` and `drag` with its native mouse API on agent pages.
It visits the supplied viewport waypoints, or the midpoint for an empty route,
then the destination twice before release. `durationMs` must be zero: ego's
mouse API exposes steps, not a movement duration, so MASC adds no timing loop.
The observed URL/document/viewport guard runs before the gesture. A drag between
coordinates, or `drag_to` with waypoints or scene nodes, runs mouse calls. Button
release is attempted in `finally`, including when a button-down call fails, but
the SDK's mouse calls answer void, so the release is never confirmed. The result
is an unknown outcome and this peer refuses further input until the operator's
reset. A `drag_to` between two selectors without waypoints uses `dragAndDrop`,
which answers a receipt, and only an object receipt without `dialog` lets the next
input run. If the run loses its answer, this peer also refuses further input.
Reads and ending the task space remain available; end that space before
opening a fresh connection. This is a per-peer failure state, not a durable
cross-process recovery record. The state lives in memory and ends with the
connection: a restarted server starts a new connection with no pending input, so
check the Space before replaying the original command. A pointer receipt does not establish application
drop acceptance or general HTML5 DataTransfer support.

A request its connection does not serve is a selection failure: the server
queues no command and answers `live_transport_unsupported`. A Keeper tool's
rejection carries the refused `clientId`, its `transport` and the
`capability`. With a serving browser connected, the Keeper lists that
connection's tabs, observes the page again and retries there. With none, the
operator attaches one ([Live BiDi browser host](browser-bidi-live-host.md)).
The BiDi peer keeps its own refusals for work outside its vocabulary; the
server does not send it to the peer.

Fill supports text inputs and textareas through the native value setter plus
input/change events; it never sends Enter or calls submit. The website's own
event handlers may react. Missing, ambiguous, disabled and unsupported targets
return errors. This interface accepts no arbitrary script. `framePath` (selector-based click,
fill, select_option and scroll) is served by a live BiDi connection.
Frame reads, JS dialogs and file selection use
the separate `BrowserRead`/`BrowserAct` contracts described in the
[advanced browser instruction](../../skills/browser-lanes/references/advanced.md).

Interactions are ordered writes under the same tool permission policy as
`BrowserGoto`; live interaction uses the operator's logged-in tab. Direct URL
navigation on a live connection is limited to a tab that BiDi connection
opened.

## Shared observation and Skill composition

The TUI's `y` action copies the selected observation with its source, client,
tab, URL, document/node identities and selection context. Its `targetKind` and
`defaultAction` describe the same Enter action available to the operator: a
region is read, while a control can be clicked. Keeper continues from that
observation instead of rediscovering the tab. A copied observation is evidence
of what was displayed, not a guarantee that the page has stayed unchanged.

The generic [browser-lanes instruction](../../skills/browser-lanes/SKILL.md)
carries its site instructions as reference files under
`skills/browser-lanes/references/sites/`. Keeper reads only the file for the
requested site, through `keeper_skill` with that `file`. A separate site Skill
that appears in the Keeper's available Skills, such as one an operator added,
is read and used together with browser-lanes; where it disagrees with a bundled
site reference, the separate Skill wins. Reference files are read from disk on
each call and carry no revision a Keeper can see, so a Keeper reads a needed
reference again in a new turn.
Site instructions describe how to recognize the requested content; execution
compositions are separately advertised `keeper_compose_<name>` tools.
For an observed same-tab link, `browser-live-follow-read` with `mode=scene`
orders follow then destination scene read and passes the navigation receipt
between them. If the
follow succeeded and only its read failed, recovery reads the same tab without
replaying the follow. Site identity, heading, visible coverage and requested
facts still need to be checked against the returned content.

## Live browser connection identity

The browser Add-on worker gives each connection it runs a client UUID and
reads the browser's name and version from the browser itself. Browser identity
is observed, not guessed from a configured label.

`GET /api/v1/dashboard/browser-lane/clients` (read-state permission) returns
`{ok:true,data:{clients:[{clientId,browser,version,engineVersion,transport}]}}`.
`clients` are the live connections the browser Add-on workers hold. Browser reads, screenshots, and
interactions accept `clientId`. With no ID, only one connected live client can
be selected; multiple connections return `ambiguous_browser_clients`, and none
returns `no_live_client`. An explicit missing/retired ID returns
`selected_client_disconnected`; it never selects a replacement.

`transport` is `webdriver_bidi` or `ego_task_space`. The TUI browser picker
displays BiDi or ego beside the browser name. Tab IDs do not transfer between
connections. [What each live connection serves](#what-each-live-connection-serves)
lists what each one does.

Tab IDs belong to their selected client. The operator read resolves that client
once before listing tabs and keeps it for the subsequent page request. Successful
read, screenshot and scene replies include `clientId` and, for a live browser,
its `transport`; Keeper BrowserTabs returns an object containing `clientId`,
`transport` and `tabs`, and BrowserRead/Interact answers carry the same two
fields, the stored screenshot included. All of them take the fields from the
resolved route (`Browser_lane.target_connection_fields`); a value the page or
browser answered under those names is dropped. The stored screenshot reads them
back through `Browser_lane.connection_fields_of_json`, which refuses a client
ID without its transport. Carry that ID into subsequent operations; the
transport says which [live work](#what-each-live-connection-serves) the
connection serves before a request is refused for it.

An Ego connection also carries `browserSpace: {id, name}` in those replies and
stored screenshot metadata. Client inventories and private worker messages use
the corresponding `space` object; other transports require `space: null` there
and have no `browserSpace` in command receipts. The peer obtains both values
from the SDK on attachment. The ID binds the connection; a name is an
attachment-time observation and does not assert ownership, visibility or login.
Page-provided Space metadata is discarded with the other connection fields.
Read composition rejects a changed Space ID even if its client UUID is reused.
Missing, duplicate or cross-transport Space context is rejected at decoding.

The worker holds the connections it runs, its own Firefox over BiDi and ego.
They end when the worker disconnects them or its owner is retired. Each client
has its own queue and pending response owners, and a result from a different
client cannot settle another client's command. Closed clients release queued
payloads; only their retired IDs remain until server restart. Client UUIDs
provide routing identity, not a credential.

BrowserTabs resolution failures include the current typed `clients` inventory and
a retry instruction in both structured error data and the model-facing message.
An ambiguous or stale selection dispatches no browser command; the Keeper must
choose a returned `clientId` and retry explicitly.


## Terminal visual viewport

After choosing and reading a Browser Lane tab, `Ctrl-O` opens the browser's
rendered PNG in the terminal. The browser owns DOM, CSS layout, fonts and page
painting; MASC transports the resulting viewport via the terminal image protocol.
This is not a second CSS engine or DOM-to-terminal layout conversion.

While the viewport is open, wheel up/down or `j`/`k`/arrow keys scroll the actual
selected page by 120 CSS pixels, then capture it again. Terminal pointer presses
and releases map the displayed image to normalized click or drag coordinates.
Either live connection takes point clicks and scrolling; a drag needs the
BiDi connection.
`r` captures the same page again; `Esc` returns to the text reader. Other keys
and pastes are consumed by the viewport and cannot edit a hidden draft. Inputs
during an in-flight action are not queued. Errors are shown without replaying
actions.

Background viewport cadence follows the selected source, live client and tab,
including navigation by another actor. It accepts the returned PNG and its
document/URL/viewport together, so the next gesture uses the displayed frame.
Explicit refresh and scroll retain their expected URL checks. A background
capture yields to operator input and cannot replace a newer gesture result.
Leaving the viewport cancels presentation of a late frame; it cannot reverse
a browser action already sent.
Terminal resize redraws the cached PNG and fits its aspect ratio when terminal
cell dimensions are known. It does not resize the browser's CSS viewport.

The viewport does not forward text entry, stream video, or promise an interactive FPS.
Rendering uses the existing [Kitty graphics protocol](https://sw.kovidgoyal.net/kitty/graphics-protocol/)
or iTerm2 image path; unsupported terminals retain the explicit image diagnostic.

The [native evidence](https://github.com/jeong-sik/masc/pull/35796)
covers live Keeper navigation and shared textual TUI observations. It does not
establish live drag support, and its captured PNGs are not evidence that a model
inspected those images.


Actual live viewport evidence: [owned Firefox click and nested scroll](../evidence/browser-live-viewport-20260913/README.md). Live drag is not covered.
