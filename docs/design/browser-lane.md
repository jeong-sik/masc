# Browser Lane

Browser Lane has two sources: `live`, the operator's Firefox/Zen
WebExtension; and `automation`, an isolated stock Firefox session controlled
by MASC's OCaml/Eio WebDriver client. See [native-firefox-lane.md](native-firefox-lane.md)
for the WebDriver endpoint configuration.

The live extension bridges typed tab reads, viewport capture and explicit-tab interaction commands through
native messaging. Its host polls `/browser-lane/poll` and returns results to
`/browser-lane/result`; these transport endpoints require the lane token.
`/browser-lane/ping` answers `{ok:true}` to the same token without registering
a client. After a failed request, a host that takes its port from the workspace
connection moves to a newly named port only when its current server no longer
answers the ping and the new address does. A result is sent again only when
its request may not have reached the server (no connection, a broken exchange
or no answer in time); a result the server answered with any status is logged
as undelivered and the host returns to polling.
They accept only `live`. Automation requires the configured in-process
WebDriver executor and reports `Lane_absent` when it is not installed.
Session management and direct URL navigation are automation-only. The live lane
can follow an observed same-tab HTTP(S) anchor through `BrowserInteract`.

Keeper browser tools use the same source state. They reject backend failures,
malformed envelopes, absent lanes and timeouts instead of reporting success.
These are Keeper tools; their in-process descriptors are separate from public
MCP tool registration.

The operator surface is authenticated independently of the connector:

| Endpoint | Request | Permission |
|---|---|---|
| POST `/api/v1/dashboard/browser-lane/read` | `lane`, optional `tabId` | Read state |
| POST `/api/v1/dashboard/browser-lane/session` | `lane`: automation/stagehand, `action`: open/close, optional `headless` | Operator admin token |
| POST `/api/v1/dashboard/browser-lane/goto` | `lane`: automation/stagehand, absolute HTTP(S) `url` | Operator admin token |

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
| `click`, `fill` | `documentId`/`nodeId`, or one visible CSS `selector`; fill adds `text` | live or automation |
| `follow_link` | `documentId`/`nodeId` for a same-tab HTTP(S) anchor | live or automation |
| `scroll` | relative CSS pixels `x`/`y` | live or automation |
| `hover_at` | normalized `point`, captured `viewport`, and `expectedUrl`; moves the trusted pointer without clicking | live BiDi or automation |
| `click_at`, `scroll_at` | normalized `point` and captured `viewport`; scroll adds `x`/`y` | live or automation |
| `drag` | normalized `from`/`to` and captured `viewport`; trusted pointer press, move and release | live BiDi or automation |
| `activate_tab` | the selected live `clientId`/`tabId` | live WebExtension only |

`BrowserRead mode=scene` supplies document-scoped node references and visible
content; `mode=regions` supplies semantic regions for a scoped scene read.
`mode=elements` supplies a control inventory when that extra detail is needed.
Use those observations rather than inventing selectors or node IDs. A node
reference and a CSS selector are alternative targets and cannot be combined.

Set `expectedUrl` to the observed URL to refuse an action after navigation.
Point actions also check the captured document and viewport. The result is an
action receipt; read or capture again to verify the site's resulting state.
On a WebExtension connection a click is DOM activation, not a trusted
hardware input event. Changing sources would select a different browser
session and is not an automatic fallback for a logged-in tab.

### What each live connection serves

The two live transports reach the browser differently, so each serves a
different part of the live lane's work. `Browser_lane.live_transport_serves`
is the one table; the server admits live work by it and the Keeper tools
build their rejection from it.

| Live work | Reached by | WebExtension | BiDi |
|---|---|---|---|
| `tab_listing` | `BrowserTabs` | yes | yes |
| `text_read` | `BrowserRead mode=text` | yes | yes |
| `scene_read` | `BrowserRead mode=scene`/`regions` | yes | yes |
| `viewport_capture` | `BrowserRead mode=screenshot` | yes | yes |
| `element_inventory` | `BrowserRead mode=elements` | yes | yes |
| `document_source` | the `browser_document` Lane Add-on source | yes | yes |
| `dom_interaction` | `click`, `fill`, `scroll`, `follow_link` | yes | yes |
| `point_click` | `click_at` | yes, the element's own `click()` | yes, a trusted pointer |
| `point_scroll` | `scroll_at` | yes | yes, a trusted wheel |
| `trusted_hover` | `hover_at` | no | yes |
| `trusted_drag` | `drag` | no | yes |
| `tab_activation` | `activate_tab` | yes | no |

The extension acts through DOM calls inside the page and has no pointer the
browser treats as the operator's. The BiDi peer sends pointer and wheel input
through the browser; it does not implement tab activation. BiDi's own
[`browsingContext.activate`](https://developer.mozilla.org/en-US/docs/Web/WebDriver/Reference/BiDi/Modules/browsingContext/activate)
also gives the tab's window focus, which `activate_tab` promises not to do.

A request its connection does not serve is a selection failure: the server
queues no command and answers `live_transport_unsupported`. A Keeper tool's
rejection carries the refused `clientId`, its `transport`, the `capability`,
the `servingTransports`, the connected `servingClients` and a `retry`
sentence. With a serving browser connected, the Keeper lists that
connection's tabs, observes the page again and retries there. With none, the
`retry` says what the operator attaches, and when BiDi serves the work the
answer also carries `bidiHost` (`state` and `message`): what the BiDi host's
own record says, for the Keeper to pass on
([Live BiDi browser host](browser-bidi-live-host.md)). The extension and the BiDi peer keep
their own refusals for work outside their vocabulary; the server does not
send it to them.

Fill supports text inputs and textareas through the native value setter plus
input/change events; it never sends Enter or calls submit. The website's own
event handlers may react. Missing, ambiguous, disabled and unsupported targets
return errors. This interface accepts no arbitrary script or `framePath`.
Automation frame reads and element actions, JS dialogs and file selection use
the separate `BrowserRead`/`BrowserAct` contracts described in the
[advanced browser instruction](../../skills/browser-lanes/references/advanced.md).

Interactions are ordered writes under the same tool permission policy as
`BrowserGoto`; live interaction uses the operator's logged-in tab. Session
creation, closure, and direct URL navigation remain automation-only.

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

Every native host process creates a fresh UUID and asks its extension for
`browser.info` before polling. Zen reports a Firefox engine name, so the host
uses the explicit `zen.version` field for Zen identity and keeps the engine
version separately. Browser identity is observed, not guessed from a manifest
location or a configured label.

`GET /api/v1/dashboard/browser-lane/clients` (read-state permission) returns
`{ok:true,data:{clients:[{clientId,browser,version,engineVersion,transport}],bidiHost:{state,record,lock_held,detail,attach,message}}}`.
`clients` are the live connections whose poll lease is current, and `bidiHost` is what the
BiDi host's record says ([Live BiDi browser host](browser-bidi-live-host.md)). Browser reads, screenshots, and
interactions accept `clientId`. With no ID, only one connected live client can
be selected; multiple connections return `ambiguous_browser_clients`, and none
returns `no_live_client`. An explicit missing/retired ID returns
`selected_client_disconnected`; it never selects a replacement. Automation
requests omit `clientId` and return it as null.

`transport` is `web_extension` or `webdriver_bidi`. The TUI browser picker
displays WebExtension or BiDi beside the browser name. When both hosts attach
to the same Firefox, select the BiDi client for trusted `hover_at` or `drag`,
then read its tabs and capture its viewport. Tab IDs do not transfer between
those connections. [What each live connection serves](#what-each-live-connection-serves)
lists the rest.

When a Keeper browser tool meets `no_live_client` or
`selected_client_disconnected`, before or after its target was resolved, its
result also carries `host`: the installed launcher (`follows_workspace` when
the installer's `launch.json` carries the SHA-256 of the `launch` beside it,
`describes_another_launcher` when it does not, `undeclared`, `unreadable` or
`not_installed`), the `workspace_port` connection.toml names, the
`serving_port` this server's listener actually bound with `polling_hosts`, the
browser hosts whose poll lease is current (both null where no bound listener
is known), and the same verdict and message the onboarding check reports.
The verdict is `connected` while a host polls this server, whatever the
launcher or file says; otherwise `aligned` only when a declared launcher's
workspace port is the bound port, `unverified` where no bound port is known,
such as `masc doctor`, and `misconfigured` for the rest. The Keeper cannot
change either side, so the retry text names what the operator does.

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

Two answers do not follow that rule. The automation lane's optional document
read keeps `clientId: "automation:<session>"`, the session its observer read,
because the document source requires that string. The interaction route the
dashboard and TUI call (`Browser_interaction.perform`) returns the browser's
receipt with neither field; its caller already named the connection.

Native transport requires `x-lane: live`, the lane token, and the identity
headers: `x-browser-client-id`, `x-browser-name`, `x-browser-version`, and
`x-browser-engine-version`. Hosts also declare `x-browser-transport` as
`web_extension` or `webdriver_bidi`; an omitted transport identifies the
WebExtension poll contract. Empty or unknown transports, missing required
identity headers, and a transport change on an existing client ID are rejected. Each client
has its own queue and pending response owners. An HTTP result from a different
client cannot settle another client's command. Native EOF attempts a bounded
`POST /browser-lane/disconnect`; after a crash without cleanup the existing
120-second poll lease detects loss. Closed/expired clients release queued
payloads; only their retired IDs remain until server restart. Retired native
hosts exit on registration rejection so the extension can reconnect with a
fresh process identity. The lane token remains the transport authorization;
client UUIDs provide routing identity, not a separate credential.

BrowserTabs resolution failures include the current typed `clients` inventory and
a retry instruction in both structured error data and the model-facing message.
An ambiguous or stale selection dispatches no browser command; the Keeper must
choose a returned `clientId` and retry explicitly.


## Terminal visual viewport

After choosing and reading a Browser Lane tab, `Ctrl-O` opens Zen/Firefox's
rendered PNG in the terminal. The browser owns DOM, CSS layout, fonts and page
painting; MASC transports the resulting viewport via the terminal image protocol.
This is not a second CSS engine or DOM-to-terminal layout conversion.

While the viewport is open, wheel up/down or `j`/`k`/arrow keys scroll the actual
selected page by 120 CSS pixels, then capture it again. Terminal pointer presses
and releases map the displayed image to normalized click or drag coordinates.
Either live connection takes point clicks and scrolling; a drag needs the
BiDi connection or automation.
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
separates live Keeper navigation/shared textual TUI observations from automation
TUI gestures. Its automation drag result does not establish live drag support,
and its captured PNGs are not evidence that a model inspected those images.


### Followed document readiness

The live extension records `follow_link` immediately and delays only the next
semantic scene read until Firefox commits a new top document. Fragment navigation
requires the source native document ID and the observed destination URL. The
existing `executeScript` call still uses `runAt: document_end`, so images and other
load-completion work do not delay visible content extraction.

Firefox native document IDs identify lifecycle events; MASC scene document IDs
identify observed DOM targets. They are separate identities. Navigation errors
can name the source document during both a successful transition and a failed
destination. Neither error text nor the first tab `complete` update determines
readiness. After commit, a rejected injection remains a read failure and the
completed follow receipt is retained. A transition with no commit or matching
fragment event can wait until the existing native transport deadline; this is
not a guarantee of immediate recovery from every navigation failure.

A follow observation is removed on consumption, completion, tab closure,
superseding follow, disconnect, or its original transport deadline. Read waiters
also use their command's remaining deadline. Cancellation during preflight is
checked before registering observations and immediately before injecting an
action. No browser action is replayed by this mechanism.

The native host now supplies `deadlineMs` from its existing extension timeout.
Install the matching host and extension together. Extension 0.7.0 adds the
`webNavigation` permission for these document events.

References: [Firefox navigation events](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/API/webNavigation),
[document replacement during injection](https://bugzilla.mozilla.org/show_bug.cgi?id=2047009).

Actual live viewport evidence: [owned Firefox click and nested scroll](../evidence/browser-live-viewport-20260913/README.md). Live drag is not covered.
