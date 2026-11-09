# Browser Lane

Browser Lane has one source, `live`: an ego lite task space.

The ego connection navigates only a native managed Page in its task space
(`BrowserGoto` with its `clientId` and that `tabId`). A tab the
operator opened is listed and refused until it is explicitly adopted.

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
| `hover` | `documentId`/`nodeId` or a unique `selector`, plus `expectedUrl`; moves the pointer onto the element without clicking | live |
| `drag_to` | `source` and `destination`, each `{selector}`, plus `expectedUrl` | live |
| `hover_at` | normalized `point`, captured `viewport`, and `expectedUrl`; moves the trusted pointer without clicking | live |
| `click_at`, `scroll_at` | normalized `point` and captured `viewport`; scroll adds `x`/`y`; `click_at` also takes `button` (`primary` by default, `middle`, `secondary`) | live |
| `tap_at`, `swipe` | `point` like `click_at`, or normalized `from`/`to` with `via` and `durationMs`, sent by CDP touch events without touch emulation | live |
| `set_viewport` | `expectedUrl`, and `width`/`height` in CSS pixels (100 to 4096) given together; with neither, the browser's own size returns | live |
| `select_option` | `expectedUrl` is optional; a `selector` and the exact `value`, or distinct `values`. Ego passes them to native selectOption, which follows SDK selection semantics and may select disabled options. It is not a trusted click on the list | live |
| `activate_tab` | the selected live `clientId`/`tabId` | live |

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
The ego connection runs MASC's page observation script; its interaction limits
still apply.

Use those observations rather than inventing selectors or node IDs. A node
reference and a CSS selector are alternative targets and cannot be combined.

Set `expectedUrl` to the observed URL to refuse an action after navigation.
Point actions also check the captured document and viewport. Scene-reference hover and drag keep MASC's node identity and coordinate guards; a selector hover uses ego's SDK resolution and auto-scrolling. Read again before retrying. Scene references reject replacement or a different document. Both drag targets must be in the same top document and current viewport. The result is an
action receipt; read or capture again to verify the site's resulting state.
Changing connections would select a different browser session and is not an
automatic fallback for a logged-in tab.

### What each live connection serves

`Browser_lane.live_transport_serves` is the one table; the server admits live
work by it and the Keeper tools build their rejection from it.

| Live work | Reached by | ego |
|---|---|---|
| `tab_listing` | `BrowserTabs` | yes, every tab in the task space |
| `text_read` | `BrowserRead mode=text` | yes, only the pages the task space manages |
| `scene_read` | `BrowserRead mode=scene`/`regions` | yes, only the pages the task space manages |
| `viewport_capture` | `BrowserRead mode=screenshot` | yes, only the pages the task space manages |
| `element_inventory` | `BrowserRead mode=elements` | yes, only the pages the task space manages |
| `document_source` | the `browser_document` Lane Add-on source | yes, only the pages the task space manages |
| `dom_interaction` | `click`, `fill`, `scroll`, `follow_link` | yes, on a native managed Page |
| `point_click` | `click_at` | yes, on a native managed Page, ego's mouse |
| `trusted_button_click` | `click_at` with `button` `middle` or `secondary` | yes, on a native managed Page |
| `trusted_double_click` | `double_click`, `double_click_at` | yes, on a native managed Page |
| `trusted_keyboard` | `type_text`, `press_key` | yes, on a native managed Page, ego's keyboard |
| `touch_input` | `tap_at`, `swipe` | yes, CDP touch events on a native managed Page, without touch emulation |
| `viewport_resize` | `set_viewport` | yes, a CDP override on a native managed Page that lasts while the ego SDK process that set it runs |
| `tab_history` | `back`, `forward`, `reload`, subject to the transport's Page authority | yes, native managed Pages in the task space; back and forward through the page's CDP history |
| `tab_navigation` | `BrowserGoto`, subject to the transport's Page authority | yes, native managed Pages in the task space |
| `tab_closing` | `close_tab`, subject to the transport's Page authority | yes, only agent-created Pages; unknown-origin Pages use release_tab |
| `tab_creation` | `open_tab` | yes |
| `dialog_answer` | `accept_dialog`, `dismiss_dialog`, subject to the transport's Page authority; the dialog is read from the tab's `list_tabs` row (`dialog`: type, message, defaultValue) | yes, native managed Pages in the task space; an input that opens one answers with it |
| `download_listing` | `BrowserRead mode=downloads` with `tabId` | yes, the downloads a native managed Page started, saved in the worker's folder and returned as artifacts |
| `file_upload` | `BrowserAct upload` with the Keeper's files | yes, one CSS-matched file input on a native managed Page, or with `opener` the one control whose click opens the page's file chooser; the connection keeps the copies until its space ends |
| `environment_emulation` | `BrowserAct set_emulation`, `clear_emulation` | yes, CDP overrides of a native managed Page's location, locale (Intl only) and time zone while the ego SDK process that set them runs; a location also grants that origin geolocation in the ego profile |
| `request_blocking` | `BrowserAct block_requests`, `unblock_requests` | yes, a CDP setting that fails a native managed Page's subresource requests to exact hosts, and those of its same-origin frames, while the ego SDK process that set it runs; navigations and cross-site frames are not blocked |
| `storage_listing` | `BrowserRead mode=cookies` with `tabId` | yes, the names and scoping attributes of the cookies a native managed Page's top document sees, and its origin's web storage keys and IndexedDB database names; never a value, though a name can carry an account, user or session id |
| `request_listing` | `BrowserRead mode=network` with `tabId` | yes, the requests the current ego SDK process saw for a native managed Page, oldest first and at most 200, with method, address without query values, header names and state; never a header value, cookie or body |
| `console_reading` | `BrowserRead mode=console` with `tabId` | yes, what a native managed Page's current document wrote to its console and the errors it did not catch, oldest first and at most 200, each text cut at 4000 bytes and as the page wrote it, so it can carry a token; the read turns ego's console hiding off and back on in one step and says how long it was off |
| `cookie_writing` | `BrowserAct action=set_cookie` or `delete_cookie` with `tabId` | yes, sets one cookie for the host of a native managed Page's top document, or deletes every cookie of a name that document sees by its domain and path; the cookie is in the operator's ego profile, so the operator's tabs and other task spaces see it and it stays after the ego SDK process ends; the answer never carries a value |
| `point_scroll` | `scroll_at` | yes, on a native managed Page, ego's wheel |
| `trusted_hover` | `hover`, `hover_at` | yes, on a native managed Page |
| `trusted_drag` | `drag_to` | yes, selector to selector on native managed Pages |
| `tab_activation` | `activate_tab` | yes, native managed Page and expectedUrl; native active/window observation without rendered UI or OS-focus proof |

The ego connection runs one fixed script per command in an ego lite task space
with `ego-browser nodejs` (RFC-browser-live-ego). Its reads run MASC's page
scripts, so selectors and `within` mean what this document says. Its tab IDs follow the page labels ego gives (`p1`, `p2`), which ego
keeps for the managed Page lifecycle. Unmanaged tabs are listed but refused
before reads or effects until explicitly adopted. Native managed Pages,
including adopted unknown-origin Pages, support input, navigation and activation
without changing their origin. Release unmanages an
unknown-origin Page without closing its tab; agent-created Pages must be closed.
All Page operations require the original agent-controlled Space, and adoption
never clears uncertain input. A load that fails after it started is answered as
a partial effect with where the tab is now. Snapshot refs can address iframe
content. MASC's page scripts find the target, check that the observed document,
URL and viewport are still there, and make the DOM edits; ego's own mouse and
keyboard input clicks, hovers, scrolls at a point and types. Finding a target and acting
on it are two runs that share the command's window.

The ego adapter uses the shared semantic pointer decoder for observed geometry
and URL, the shared action classification and the shared intermediate waypoint
calculation; it keeps its own native input and release handling.

Ego serves `drag_to` on agent pages with the SDK's `dragAndDrop`, from one
selector onto another, after checking that the tab is still at `expectedUrl`.
`dragAndDrop` answers a receipt, and only an object receipt without `dialog` lets
the next input run. If the run loses its answer, this peer refuses further input.
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
operator attaches one (`masc browser-lane-setup --mode ego`).

Fill on a selector uses ego's native fill. Fill on a scene reference sets text
inputs and textareas through the native value setter plus input/change events.
Neither sends Enter or calls submit. The website's own event handlers may react.
Missing, ambiguous, disabled and unsupported targets return errors. This
interface accepts no arbitrary script. JS dialogs and file selection use
the separate `BrowserRead`/`BrowserAct` contracts described in the
[advanced browser instruction](../../skills/browser-lanes/references/advanced.md).

Interactions are ordered writes under the same tool permission policy as
`BrowserGoto`; live interaction uses the logins of the ego lite profile.
Direct URL navigation is limited to native managed Pages in the task space.

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

`transport` is `ego_task_space`. The TUI browser picker displays ego beside
the browser name. Tab IDs do not transfer between
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
the corresponding `space` object. The peer obtains both values
from the SDK on attachment. The ID binds the connection; a name is an
attachment-time observation and does not assert ownership, visibility or login.
Page-provided Space metadata is discarded with the other connection fields.
Read composition rejects a changed Space ID even if its client UUID is reused.
Missing or duplicate Space context is rejected at decoding.

The worker holds the ego connections it runs.
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
The ego connection takes point clicks and scrolling; the screenshot footer
says whether it takes a drag.
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


Earlier live viewport evidence, recorded on the owned Firefox connection of 2026-09-13: [click and nested scroll](../evidence/browser-live-viewport-20260913/README.md). Live drag is not covered.
