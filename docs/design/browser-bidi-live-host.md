# Owned Firefox BiDi peer

The `browser-firefox` Lane Add-on starts a Firefox with its Remote Agent on a
loopback port and reaches it through an in-process BiDi peer. It copies no
login profile and obtains no application tokens.

## Inspecting unavailable tabs

`tabs.list` retains readable tabs when another context refuses page scripts.
A partial answer has `tabs`, `complete: false`, and `unavailableTabs`. Each
unavailable row keeps its connection-local `id`, `index`, Firefox's error,
and the URL from `browsingContext.getTree` when provided. That URL is an
inventory observation, not proof that its document can be read or controlled.
An unreadable start page does not prevent using an observed ordinary HTTP(S)
tab or opening a fresh one on the same connection. Never replace a user's
existing tab merely to make the listing complete.

## Attaching a connection

The attached `browser-firefox` Lane Add-on starts Firefox when its declaration
is enabled and the workspace's `runtime.toml` contains:

```toml
[browser.live.bidi]
firefox = "/Applications/Firefox.app/Contents/MacOS/firefox"
profile = "/Users/you/masc-keeper-firefox-profile"
# port = 9222
```

`masc browser-lane-setup --mode bidi --base-path DIR` prepares this table and
profile and declares `browser-firefox` when the workspace has no declaration of
it. Explicit `--firefox`, `--profile` and `--port` options replace their
corresponding existing values. Restart MASC to load the configuration, then
attach `browser-firefox` or detach and reattach its installation. Log in once
in that Firefox; the dedicated profile preserves its logins.

The Add-on captures this configuration in its original native reservation
before allocating the worker. It acquires a shared profile lease and a child
claim, launches a foreground process owner, and verifies that exact owner's
kernel lease, child birth/group, reported profile and `moz:processID`. A port
already in use is a refusal. An external browser is never adopted as an owned
child. A profile already in use must be closed by its operator before attachment.

The verified peer registers one client UUID directly in the original worker.
Its commands, actors and results stay on that connection. A lost or retired
client is terminal; it is never re-registered under a fresh UUID and browser
input is never replayed. Starting a configured Firefox is part of worker
readiness: startup failure prevents that installation from becoming ready and
joins its other configured backends.

Detaching revokes admission before joining the original peer and browser. An
orderly shutdown sends `browser.close` once and waits for the original owner
and native claim settlement. Failed or cancelled shutdown aborts only that
original owner and retains an unconfirmed result. Profile contents and stable
claim files are preserved. The worker log is `live-firefox.log` in its private
per-incarnation allocation; Add-on observations report readiness or failure.

The server has no independent Firefox startup job. The `browser-firefox`
declaration's `enabled = false` stops this worker; the other browser sources
keep running. Existing instances retain their captured configuration until
detached.

The peer attaches only to a browser that reports itself as `firefox`.

The BiDi connection owns its opaque context to integer tab mapping. IDs are not
recycled during the client lifetime and are never joined to URLs. Tab visibility and Firefox version are observed, not inferred from index.
Unsupported verbs fail explicitly. Fixed repository scripts provide DOM reads,
scenes, document references, and semantic interactions; command arguments are
JSON data, never supplied JavaScript.

Screenshot coordinate input uses the existing document/viewport guard followed
by BiDi pointer or wheel actions. `hover_at` uses one `pointerMove`, with no
button press, on the selected live BiDi tab. Copy the
observed `expectedUrl`, `viewport` and normalized `point` from a fresh capture.
BiDi uses the native pointer action encoder. A drag moves to its
destination twice before releasing, so dragover handlers can observe it where
the browser supports HTML drag-and-drop. An accepted gesture receipt proves
the input sequence, not an application drop. Firefox's native HTML draggable
drop is affected by [Mozilla bug 1515879](https://bugzilla.mozilla.org/show_bug.cgi?id=1515879);
pointer-capture drags are a separate supported interaction. MASC does not replay
the gesture with synthetic DOM events when a drop is absent.
Pointer receipts read only the URL, title and scroll position. Screenshot
validation also reads tab metadata instead of the document body, so a large
page does not turn completed input or capture into a body-size failure.
[What each live connection serves](browser-lane.md#what-each-live-connection-serves)
is the whole table. Live-client discovery reports `transport` alongside each
`clientId`, including the ambiguity response and
`/api/v1/dashboard/browser-lane/clients`. Interaction receipts identify the
resolved tab with `tabId`.
This is not an atomic snapshot/input
transaction: the operator can still change the page after validation. There is
no write replay. An unknown outcome stops this live client. Reads and interactions
share the existing command deadline; connection setup has that same bound.
Protected pointer-release cleanup can additionally run up to one transport
deadline after the outer command deadline. A timeout is not an instantaneous
release guarantee.
Screenshot guards read URL, title and document/viewport identity together before
and after capture, without reading or serializing the document's text. A text
read that is slow or too large is therefore not a prerequisite for a screenshot.
The element inventory shares computed styles and ancestor display/opacity checks
within one synchronous observation; later observations recompute them.
Pointer receipts use the shared URL/title/scroll observation, also without a
whole-document text read after input.

A tab whose metadata cannot be read is retained in `unavailableTabs` alongside
`complete: false`; readable tabs keep their IDs. This partial listing does not
prevent an explicit read or capture of a readable tab. Implicit active-tab
selection also continues past unreadable tabs using metadata only, and includes
their refusal details when no readable active tab is found. Closing an unreadable
tab is not required to use another tab.

The peer does not implement uploads or download collection. page.elements runs the shared element script in the
requested tab, so its selectors are the ones the DOM interactions take. A
page.read with includeHtml runs the shared document helper, which
leaves the HTML out and says why when the result passes 1 MiB. Both reads
answer for the whole document, so a document the parser has not finished is
refused before effect rather than answered with the part that exists.

One socket message carries at most 8 MiB, and a larger one ends the
connection. A page script therefore measures its own answer: one longer than
2,097,152 UTF-16 units is not sent, and the command is refused as
`page_answer_exceeds_bidi_reply_limit` with the size. That is a quarter of
the limit, because a unit takes at most three bytes on the wire and the
envelope needs room. The connection stays up for the next command. The element
script does not bound a control's value or a select's options, so a page can
produce such an inventory. A successful
follow receipt does not guarantee application content is ready; existing guarded
read recovery remains necessary. A BiDi session enables browser-wide automation
and must not be exposed beyond loopback.

Validation: `test_browser_bidi_peer` exercises opaque identity, the element
inventory, the document source and the lane table against the peer.

Protocol references: [Mozilla direct connection](https://developer.mozilla.org/en-US/docs/Web/WebDriver/How_to/Create_BiDi_connection),
[BiDi input](https://developer.mozilla.org/en-US/docs/Web/WebDriver/Reference/BiDi/Modules/input/performActions),
[Remote Agent security](https://firefox-source-docs.mozilla.org/remote/Security.html).

## Agent feedback and pointer observation

BiDi interactions display a non-interactive MASC badge with the authenticated
Keeper/calling-agent label and operation. While the page channel remains available it settles to Finished, Not performed,
or Outcome unknown when the peer completes or unwinds the request. A lost
transport cannot update an existing badge; inspect the connection before treating
a retained Working badge as current. Navigation does not create a new badge for
an old request's cleanup. A page refusing
feedback does not authorize a replay or prevent the interaction.

The marker follows trusted browser pointer/wheel/drag events and displays CSS
viewport coordinates. Before any event its position is unknown; this is the browser
input pointer, not the desktop mouse cursor. The inert shadow overlay receives no
pointer input and does not add its text to the page read surface. A later command
cannot be marked finished by cleanup belonging to an earlier request.

Connection discovery reports queued/running interactions and their actors from
the server's owned queue. The TUI labels these as the last connection observation;
refresh the connection list to inspect a newer observation. It does not infer a
remote agent's state from the local TUI loading indicator.

Firefox internal start pages (`about:newtab`, `about:home`) can appear in the
context tree while rejecting `script.callFunction` with `unsupported operation`.
An inventory with only these pages has no readable tabs and reports them in
`unavailableTabs`. Open a normal site in the dedicated Keeper Firefox profile and
read the connection again. MASC does not expand Firefox system-page permissions.
BiDi errors retain the rejected command name; fixed-script exceptions retain the
browser's reason, including stale-document/viewport refusals.

## Open a tab on the selected BiDi connection

Use `masc_browser_act` with `action:"open_tab"`, `lane:"live"`, the exact
observed `clientId`, and an absolute HTTP(S) `url`.

The peer creates a background tab in the selected Firefox profile, navigates
only that new context, and returns `tabId`, `created:true`, `url`, and `title`
with the server's connection identity. Use this returned tab ID and client ID
for page reads and hover; new tabs share that profile's default user context.
Existing tabs and protected start pages are left in place. This is an explicit
request, never an automatic response to a failed start-page read.

A refused creation or a command never written is a pre-effect failure. When
creation is confirmed but navigation is refused or the page summary fails,
the response remains a failure with `effectPhase:"partial"` and a structured
`created:true`/`tabId` receipt. The server adds the selected connection identity
and keeps that receipt in the Keeper's error output. The peer keeps serving
this connection, so the caller can list or read the same tab before deciding
what to do next. This is a confirmed effect, never permission to replay creation.

A lost reply or broken session remains an unknown outcome and ends the
connection. The peer never creates another tab or closes the created context
to recover. List current connections and observe their tabs again; old
connection tab IDs must not be reused on a replacement connection.

### Trusted semantic clicks

On BiDi, `click` with one observed selector or scene
`documentId`/`nodeId` resolves a visible, unobstructed target and sends native
pointer move/down/up. This supports menus that open on trusted `pointerdown`
or `mousedown`, including a control exposed by hover. Re-observe the revealed
controls before selecting one. Disabled controls, inherited `aria-disabled`,
ambiguous selectors and stale scene references are refused before input.
Labels retain their associated-control semantics, including visible text in a
`display:contents` label. Targets outside the viewport require scrolling and a
fresh observation first.

`expectedUrl` remains optional for semantic click. If omitted, resolution
captures the current URL and the native input guard checks that URL and the
resolved viewport before dispatch. There is no DOM-click fallback or automatic
replay after native input.

### Drag movement and acceptance

`drag` and `drag_to` accept `via` (ordered normalized viewport points) and
`durationMs` (milliseconds for each move). Without a path, native BiDi visits
the midpoint before the destination so controls that activate
on initial movement receive another changed position before release. Custom
paths must come from the observed viewport; stale geometry fails before input.
A successful native input receipt proves dispatch and release, not that a page
accepted a drop. Re-read the application result before reporting success or
retrying. HTML5 `draggable`/`DataTransfer` requires separate verification from
pointer-capture dragging; Firefox's upstream issue is
[Bug 1515879](https://bugzilla.mozilla.org/show_bug.cgi?id=1515879).

### Observing hover controls

After hover, read the page again before selecting the newly visible control.
Scene output uses the requested `maxChars` text budget and its existing 1 MiB
response limit. Visible controls later in DOM order are not silently excluded
by a separate 200-node quota. Nodes are admitted against the complete JSON's
UTF-8 byte size, including their geometry and metadata. When the next node
would exceed the byte ceiling, the result keeps the admitted nodes and full
page identity with `truncated:true`. An identity envelope that cannot fit by
itself is refused rather than shortened. Check `truncated` and use an observed
region scope or the element inventory when a text or byte budget is exhausted.
A missing control in a truncated observation is not evidence that hover failed.

### Native double clicks, text, and key chords

`masc_browser_interact` supports `double_click` on an observed selector or scene
node, and `double_click_at` on a captured viewport point. BiDi sends two native
button press/release pairs in one owned input sequence. These actions use the same
visibility, disabled-control, document, viewport, and URL guards as native click.

`click_at` takes an optional `button`: `primary` (the default), `middle` or
`secondary`. BiDi presses and releases the matching pointer button
(0, 1 or 2) at the observed point. A
`secondary` click opens whatever the page binds to the context menu; observe the
page afterwards, the receipt does not say what it did.

Each `tabs.list` row carries `windowId` when Firefox's `browsingContext.getTree`
names the tab's `clientWindow` (Firefox 158 does, probed 2026-10-22). Tabs with the
same `windowId` share a window, and the distinct values are the windows. The number
is assigned by this connection in the order it first sees a window, so it is not
comparable across connections. There is no window title, size or position, and no
way to create or close a window yet.

`tap_at` and `swipe` send the same WebDriver pointer sequences as `click_at`
and `drag`, from a pointer whose `pointerType` is `touch`. Firefox 158 reported
`pointerdown`, `touchstart`, `pointerup` and `touchend` to the page for a tap,
each trusted, followed by the mouse events and a click (probed 2026-10-22), and
`pointermove` events through a swipe.

`back`, `forward`, `reload` and `close_tab` act on a top-level tab only if this
connection opened it with `open_tab`. A tab the operator opened is refused before
any browser call: it holds pages and unsaved state this peer never saw, and these
actions carry no `expectedUrl` that says which page the caller observed. The
commands are `browsingContext.traverseHistory` (delta -1 or 1),
`browsingContext.reload` (waiting for the document) and `browsingContext.close`
with `promptUnload: false`. Firefox's error codes `no such history entry`,
`invalid argument` and `no such frame` mean nothing happened. Any other error is
a result that is not known: a reload or a history step that lands on an error
page is answered with an error after the tab moved.

`set_viewport` resizes the tab's page viewport, not the browser window. A live
BiDi connection sends `browsingContext.setViewport` with the size, or with
`viewport: null` when no size is given, which gives the browser's own size back.
Firefox 158 reports the new `innerWidth` and `innerHeight` right after the
command (probed 2026-10-22), and it accepts widths of 0 and 100000 without an
error, so the lane bounds each side to 100 to 4096 CSS pixels itself. The
override stays on the tab until it is cleared. Firefox 158 keeps it after the session ends (probed 2026-10-22: a new session read the old size), so the peer gives each tab it sized its own size back when it ends the session. A peer that dies without ending its session leaves the size on the tab.

`type_text` sends Unicode text into the currently focused editable control.
`press_key` sends one named key or Unicode scalar, optionally with explicit
`Control`, `Meta`, `Alt`, and `Shift` modifiers. Both require the observed
`documentId` and `expectedUrl`; a reload of the same URL fails the document guard.
Typing additionally requires enabled editable focus. Control characters are
refused as text: use an explicit `press_key` for Enter or Tab so a text request
cannot silently change focus or submit a form. The guard never focuses a
control or dispatches events: first use an observed native click to focus it.
Use `Meta` with `a` for select-all on macOS and `Control` with `a` where appropriate.

BiDi uses native key down/up input sources and releases all held input even
after cancellation or an unanswered dispatch. Unicode scalars stay intact. W3C's
reserved special-key scalars U+E000 through U+E05D are refused as text instead of
becoming commands. An unanswered input remains uncertain and is never replayed.
Receipts report the original action and page identity without echoing typed text.

`test/fixtures/browser-native-input.html` records trusted double-click and keyboard
input for isolated native browser probes. Source tests and protocol fixtures do
not establish that an installed browser has completed these interactions.


### JavaScript dialogs on a BiDi connection

A BiDi session answers a page's `alert`, `confirm` and `prompt` itself unless it
is created with `unhandledPromptBehavior`. Probed 2026-10-22 on Firefox 158: a
session made with empty capabilities returned `false` from `confirm()` at once,
with no person involved, and `browsingContext.handleUserPrompt` then answered
`no such alert`. The peer creates the session with
`alwaysMatch.unhandledPromptBehavior.default = "ignore"`, so a dialog stays open
for the person using the browser, and subscribes to
`browsingContext.userPromptOpened` and `browsingContext.userPromptClosed`.

The two events say which dialog (`alert`, `confirm`, `prompt`, `beforeunload`),
its message and a prompt's default. The peer keeps one per context and shows it
as `dialog` on that tab's `list_tabs` row. It knows only what happened since it
subscribed: a dialog already open then is not listed. `accept_dialog` and
`dismiss_dialog` send `browsingContext.handleUserPrompt` (`accept`, and
`userText` for a prompt) and answer only for a tab this connection opened; the
person answers a dialog on their own tab. A tab with no dialog gets the
browser's `no such alert`, which the peer reports before any effect. The
receipt names the dialog that was answered. A dialog's message is page text.
