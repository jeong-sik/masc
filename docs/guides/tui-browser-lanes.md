# Browser Lane in the TUI

Open `:` → `go Browser Lane`, or press `B` from Connectors. **Automatic** asks the
server which available browser can supply the reader, then binds the concrete
browser and lists its open tabs. Select any page by title and URL; websites have
no dedicated views or filters. Entering the reader never opens a browser window.
No available browser, ambiguous browsers and other selection refusals keep their
cause and require a choice.
The reader occupies the full content width and shows its selected browser. Keeper panels and the composer return
when leaving the reader.

Press `Ctrl-^` (Ctrl-Shift-6) to show or hide Browser. Hiding returns to the
previous surface and restores its search and composer focus. The selected tab,
scroll and unsent chat draft survive the toggle within this TUI session.

Entering Browser ends continuous voice mode and discards any capture in flight,
including a transcript awaiting delivery. An existing Keeper draft is preserved.

| Key | Action |
| --- | --- |
| `b` | Choose Automatic or a connected browser by its actual identity |
| `A` | Show transport limits in the browser picker |
| `[` / `]` | Previous / next tab and read its page |
| `1` … `9` | Select the corresponding observed tab directly when it is listed |
| `j` / `k`, arrows | Scroll page text |
| `J` / `K` | Scroll the observed browser page by one viewport, then refresh the same scene |
| Page Up / Page Down, Home | Page scroll / top |
| `r` | Rediscover tabs and refresh the page |
| `m` | Observe semantic landmarks, then focus the unique `main` (or fallback `article`) region |
| `N` / `P` | Select the next / previous observed `article` region or article ancestor |
| `Ctrl-O` | Open the selected tab screenshot; Esc or q returns |
| Ctrl-^ / Esc / Left | Hide the reader and return to the previous surface |

Browser belongs to Config. Its title shows Automatic or an explicit selection,
the actual connected browser identity, and the latest HTTP request status. Automatic uses the server's browse decision only
while unbound. Once bound, reads, captures, navigation and gestures retain that
concrete source, client and tab. A later recommendation, disconnect or unsupported
gesture never switches browsers or replays an action. Select another browser
explicitly to change that owner. A malformed automatic decision refuses automatic
selection while preserving a validated connection list for manual selection.

An explicit observed client goes to the browser Add-on whose worker lists it,
even when several browser workers are visible; a client two Add-ons list is
refused rather than sent to one of them. A Keeper's stored Goal binding resolves
its numeric Ego Space only among the connections of the Add-on installation that
published it, before initial discovery. A missing connection never authorizes a
replacement, and `BrowserSession action=goal_status` reads the stored binding
without a running browser worker. Automatic per-Goal Space allocation is not
implemented.

The connection list reads metadata sequentially from every visible browser worker.
Keeper callers can request the same inventory with `BrowserTabs {"mode":"connections"}`
alone, then retain an observed `clientId` for ordinary tab discovery and actions.
This mode accepts no lane, client, tab or required-action options and sends no
browser command. It does not read Page documents, create a Space or reclaim control.
The HTTP connection list continues to expose Shared installations only.

`inventoryIssues` reports unavailable, unreadable and unready workers. Valid
clients from other workers remain available for a manual choice; a client UUID
reported by different workers is omitted from those choices and reported as a
duplicate. Any issue refuses automatic selection, rather than reporting that no
browser exists. With multiple complete workers, browse can recommend a concrete
live UUID.
Observations grant no authority: a later explicit request revalidates the worker.
The TUI keeps the current Page and pending read while updating inventory issues.
An unreadable issue report preserves validated client rows and refuses automatic
fallback. `inventoryComplete` is the server's derived summary of its issue list.

The picker lists **Automatic** and the connected browser identities. Press `A`
in the picker to show what each connection's transport does not serve. Safari
is not currently an implemented browser choice.

The current browser is marked; choosing it again retains the current tab and
scroll. Switching to another browser clears old page and screenshot references.
Coordinator connectivity and workspace warnings are labeled separately.
Reads show latency, tab count, selected title, URL, character count and truncation.
For Ego tabs, the selected-tab row also shows the SDK Page label (or unmanaged)
and the observed agent-created or unknown origin. Unknown origin does not identify
a user-created tab. These details do not grant control or adoption permission;
unmanaged tabs still refuse document reads and input. The read result retains
`egoPage` context and the bound `browserSpace`, including unavailable tab rows.
A failed or pending refresh retains content labeled as a previous read. Switching
source clears that content; generation-stamped replies reject earlier requests.
Reads happen on entry, source or tab selection, navigation, and explicit refresh.

The selected live connection reports queued and running requests, including
reads, snapshots, waits inside a native workflow, and navigation, with their
caller and tab or space scope. The reader also shows each caller's last returned,
refused, partially performed, or unknown result. An operator's read does not erase
a Keeper's last result. These are observations from the last connection-list
read, rather than a claim that a completed request is still running. Page cadence
refreshes the activity list independently of page content, preserving the selected
connection, tab, scroll and pending read. A failed activity refresh keeps
the previous observation and displays its failure separately.

Ego's native cursor label still identifies pointer actions. This activity list
does not add a native Ego label for reads or waits; that browser-side visibility
remains a separate gap.

A live browser is reached over the owned Firefox's BiDi connection or an ego
lite task space, and the two serve different work
([the table](../design/browser-lane.md#what-each-live-connection-serves)). The
TUI reads that table in four places:

- The selected connection row names the actual browser and client identity.
  Transport names and capability differences belong to advanced details.
- The row under the picker, for the highlighted connection, names the work its
  transport does not serve and the transport that serves it.
- The screenshot footer: `drag: move` when the connection the screenshot came
  from takes a drag, and the connection that serves it when it does not.
- A pointer gesture on a screenshot whose connection does not serve it is not
  sent. The screenshot closes and a row under the status says so, with
  `b:choose browser` when a serving connection is listed. The read badge does
  not change, because nothing was requested. The rows stay through the lane's
  own refreshes and go with the next key or click.

A configured `[browser.live.bidi]` belongs to the attached `browser-firefox`
Add-on, whose observation reports its owned Firefox and in-process peer
([how](../design/browser-bidi-live-host.md)).

An ego lite connection also belongs to the attached browser Add-on. On a Mac
with ego lite installed and its onboarding finished,
`masc browser-lane-setup --mode ego --base-path <workspace>` finds `ego-browser`,
checks that it answers, and writes the table into `runtime.toml`. It refuses a
space name that a task space you made in ego lite already has, because ego
would refuse that space to masc; name another with `--ego-space`. It checks the
name the table keeps as well, and writes nothing when ego lite does not list its
spaces. Restart the
server afterwards. `masc setup` offers the same command as an unmarked row of
its tools checklist when `ego-browser` answers. Written by hand, the table is:

```toml
[browser.live.ego]
command = "/Users/me/.local/bin/ego-browser"
space = "masc-keepers"
```

If the configured name is already held by a user-owned Ego task space when
the browser Add-on starts, Ego is unavailable and the Browser view reports the
reason. The existing space is not opened, claimed or finished; other browser
connections can continue. The report is the startup observation, not a live
ownership check. It includes the observation time in the browser clients API.

Choose a different configured name, or resolve the name conflict yourself.
Save a new name through the Runtime settings editor or API; after editing
`runtime.toml` directly, restart the server so its effective configuration is
reloaded. Ego does not reconnect automatically in that worker. To recheck a declared
browser Add-on without removing its declaration, switch it off, wait until
its application reports `Inactive` and cleanup is confirmed, then switch it on
again ([package activity](lane-package-activity.md)). This restarts the whole
worker, including its managed Firefox. A list refresh alone does not restart
it. After the restart, `b` opens and refreshes the Browser connection list;
use `r` if the picker is already open.
The list reports the worker's startup observation. If the listing itself fails,
or a conflict arises after the listing, the
original startup failure behavior still applies.

The picker identifies its client UUID and the SDK-observed Space ID/name. The
name is observed when the connection attaches; renaming it does not change its
identity. A different Space ID requires a new selection even if a producer
reuses a client UUID. These are connection observations, not proof that the
operator can see the Ego window or that login has completed.
The worker, host/server and TUI must be updated together: the private client
contract requires `space` on every client, with `null` for non-Ego transports.

It reads and captures the pages
of that one task space. It opens Pages and operates on native managed Pages
there, including explicit adoption. Unknown-origin Pages are released rather
than closed. It uses Ego's native snapshots, selectors and input, including hover,
double-click, drag and option selection. Snapshot refs also address iframe
content; explicit `framePath` and touch input are not supported. Keeper workflows
can focus an editor, type or insert text, paste text/HTML through Ego's native
clipboard restoration, and wait for the result before returning a final snapshot
([what it serves](../design/browser-lane.md#what-each-live-connection-serves)).
Native workflows also expose app-state waits, Page expressions with a JSON
argument, and browser-context fetch. Page source runs only in the observed Ego
Page, and these calls count as possible effects. A Fetch step can set
`options.saveAs` to a filename such as `report.pdf`. The SDK saves binary bytes
under a fresh private UUID; the step returns a download ID and requested name.
Use BrowserRead `mode=downloads` on the same client/tab, then the row's finalized
artifact reader, to retrieve bytes. Never repeat Fetch to retrieve a completed
save after a later step or snapshot failed. This inventory lasts only for the
same SDK process. Remaining SDK/Space gaps are listed in the
[SDK inventory](ego-sdk-coverage.md).

Keepers use `BrowserInteract` to click, fill, or scroll an explicitly selected live tab;
the TUI scene supports observed-element clicks, and the screenshot view supports
mouse clicks and scrolling. Text entry into the page remains a Keeper tool action.

Requests use the authenticated TUI HTTP client. Reading allows 45 seconds for
the tab-list and page-read phases.
Requests run in switch-owned Eio daemon fibers and return through the TUI mailbox.

`Ctrl-O` captures the explicitly selected tab through the authenticated screenshot
endpoint. The preview keeps the source, tab and text position. A closed tab produces a visible failure rather
than capturing a different active tab. Use `r` to rediscover available tabs.
The image is not staged or sent to a Keeper. PNG preview uses the terminal's
existing image support; unsupported terminals receive an explanation in Browser.

In screenshot view, click a visible link to activate it. Mouse wheel, arrows and
`j`/`k` scroll the actual page, and `r` refreshes the screenshot. A live BiDi
connection also supports pressing the left button, moving, and releasing to drag
with trusted browser pointer actions; the footer says what the connection of
the screenshot on screen takes.
Each completed action captures the resulting page again in the same Lane.

Mouse coordinates require the terminal's measured cell size. If that measurement
is unavailable, the footer explains that click/drag is unavailable; scrolling
and refresh remain usable. Inputs retain the captured document identity, viewport
size, scroll position and URL. A changed observation requires a fresh screenshot
before another pointer action can execute.

See [setup and Keeper usage](../design/browser-lane-examples.md).

All Lanes shows each Browser row from its browser Add-on alone: the clients the
live worker last published. With no observation the row says why: no browser Add-on serves the
lane (not set up), every one that serves it is switched off (off), one is
declared on and its worker is not running (waiting), or the declarations could
not all be read (failing). Executable and profile paths in `runtime.toml`
apply at server startup.

A source is switched on or off from its `browser-<source>` package row in All
Lanes: `Enter` opens its declaration, `Space` changes `enabled`, and `s` saves.
`Space` on a Browser row points there. See
[per-source setup](../design/browser-lane-examples.md#출처별-설정과-켜고-끄기).

## Verification

`test/test_browser_surface.ml` covers page selection, empty browsers and failures.
`test/test_tui_browser_lane.ml` covers decoding, source changes, stale replies and
retained evidence. Related TUI tests cover multiline text projection. Use a binary
built from the changed source; historical captures are not evidence of the
current UI.

### Native browser selection

Live Browser Lane discovers the server's active native connections on entry and
`r`. A single fresh connection is selected automatically. With several connections,
choose one using `b`, `j/k`, and Enter. The chooser displays the backend's
browser identity and each connection UUID; the reader header names the selected
browser. `r` inside the chooser reloads connections, and Esc returns to the reader.

Each live read and Ctrl-O screenshot pins that connection UUID. Switching browsers
clears the previous tab, text, and scroll before reading the new browser. A missing
selected connection opens the chooser without silently rebinding to another browser,
even when only one remains or both browsers use the same tab number. Select a
connection explicitly to recover.

Validation: the production pure Browser state module was interpreted against 14
fixtures, including equal tab IDs across clients, stale discovery, disconnected pins,
and screenshot ownership. No local Dune build was run.


## Gecko scene view

After reading a connected browser tab, press `s` to observe its viewport
as real text and numbered elements. `Tab`/`Shift-Tab` move directly between enabled
clickable controls and readable regions. `n`/`p` select any observed element,
including text and images for copying context. Selection reveals the element's
first wrapped row without making a browser request. `Enter` clicks an enabled
control and reads a fresh scene, or reads the selected region. The footer names
the selected action. `v` lists page regions; the context row distinguishes page
content from a selected region. `j`/`k` scroll the terminal text, and `r` observes
the same page or region again.
`J`/`K` send a guarded top-level page scroll using the observed viewport height,
then read the same scene again. The result must retain the observed URL and
document identity; a viewport resize is reported by the fresh scene rather than
treated as a pre-action lock. Nested panes still require screenshot pointer
scroll because their scroll container is selected by the observed hit point.
The scene context row shows the observed page scroll as `x=… y=…`, so a refresh
makes the page position explicit without confusing it with pointer coordinates
or claiming that the scene is a complete document.
In a regions scene, `N`/`P` move between exact observed `article` regions;
they leave the selection unchanged on content scenes without article roles.
`Enter` follows an observed same-tab HTTP(S) link directly and reads the
destination with its follow receipt; the old region scope is never reused for
the destination. Other enabled controls use the ordinary observed click.
When `Enter` reads a region, the context row keeps the observed typed role and
label (for example, `article · Post A`) while the body is scoped. `y` includes
that same scope context with the document/node identity.
`m` is the short semantic path for a page's primary reading surface: the first
press observes `main`/`article` landmarks, and the second focuses the unique
exact-role match. Role names are classified at the observation boundary;
unknown roles remain visible but cannot become an implicit primary target.
Multiple matches stay in the region picker instead of being chosen by text, URL,
or CSS heuristics.
If the destination read is still pending or fails, the footer exposes `r`/`s`/`v`
as guarded retries so an old document cannot be accepted as the new page.
`y` copies the selected element together with its observed region, viewport,
and truncation flag, so a Keeper can preserve the same reading scope.
The scene status line also reports the observed composition, such as
`2 articles · 6 links · 1 image`; these are typed node counts, not guesses from
page text. Use the article count to choose `N`/`P` before reading the full body.
After a same-document refresh or guarded page scroll it also shows an observed
delta such as `Δ +3 new · -1 out · =8 same · 2 changed`. `new`, `out`, and
`same` count unique observed node IDs; `out` means absent from this observation,
not deleted from the site. Geometry-only movement from scrolling does not count
as a content change. A different document, URL, view, or scope starts a fresh
observation and shows no delta. The delta is a compact progress hint for the
current viewport, not evidence that a feed is complete.
Press `s` to return to the text reader or `Ctrl-O` to open the painted image.
The image viewport retains its browser scrolling controls.

The scene is DOM-order text, controls and image placeholders. CSS geometry is
available to tools; this first TUI projection does not reproduce CSS layout or
compose inline raster regions. Use image view for the browser's painted result.
Text nodes and observed controls with an observed heading ancestor are shown
with a `#` outline prefix, so article titles and section headings remain
visible while reading the DOM-order body. The scene records an `h1`–`h6`
ancestor, including text nested under a span and links whose own control node
is the observed heading target, plus an explicit `role="heading"` with
`aria-level` 1–6.
Missing or invalid ARIA levels stay plain text; the reader does not infer
headings from text, CSS, font size, or class names.
Content text, controls, and images also retain the nearest observed semantic
ancestor region. An `article` wins for feeds and threads, then `main`, then the
closest other observed landmark. The TUI emits a compact `[article] Label`
boundary when that context changes, while a scoped article read suppresses the
duplicate boundary because its scope row already names the article. This is
observed region identity and label data, not a selector or a guess from page
text. `y` includes the same ancestor region identity in copied context.
Adjacent observed text nodes inside the same semantic block are coalesced for
the reading row when the observed block identity repeats, preserving their
exact text and each node's selection number. The group closes at that verified
repeat; an unproven tail stays as separate rows. Crossing a block tag, control,
raster, heading level, or observed region starts a new row group; the
projection never merges an action target into prose.
For eligible observed block-tag nodes, a positive vertical gap from the
preceding eligible node becomes one blank TUI row. An intervening inline node
breaks that comparison, zero-gap line fixtures stay compact, and the reader
does not infer CSS display or invent spacing from a site selector.
TUI scene controls support clicking; literal text filling is available through
`masc_browser_interact` with `documentId`/`nodeId` from `masc_browser_read` mode
`scene`. A detached element or document reload requires a fresh observation.

Source changes and script-level Gecko evidence alone do not establish that an
installed TUI has been updated.


## Selected element to source

Scene view now selects text and images as well as controls. The source row shows
an original location when the page is served by the MASC development Vite server.
Press `y` to send the selected element context to the terminal clipboard, then paste
it into the Keeper conversation with the requested change. Clipboard delivery
depends on terminal OSC52 support; MASC cannot read back the terminal clipboard.

The context retains lane/client/tab, document/node identity and source SHA-256.
The Keeper verifies the chosen checkout and hash before editing. JSX locations
identify the opening element; HTM locations identify the tagged template. External
pages without instrumentation explicitly report source unavailable.

The builtin frontend-change package covers visual intent, verified source editing
and browser evidence as one design, implement and verify flow. It is a discoverable
skill; users need not name a skill for an ordinary UI request. Newly built MASC
installs seed missing packages through the existing builtin-skill installer.

In screenshot view, the mouse wheel scrolls the area under the pointer, allowing
message lists and sidebars to scroll independently. `j/k` and the up/down keys
scroll the area at the center of the viewport. When terminal cell geometry is
unavailable, the wheel also uses the center and the footer shows `wheel:center`.
The live lane finds the scrollable DOM ancestor under the pointer. After scrolling, MASC captures the
same tab again.

`v` lists the page's observed semantic regions -- `main`, `navigation`,
`region`, `article`. `n`/`p` selects a region; Enter reads only that region's
content, and `r` re-reads the same region. Pressing `v` again returns to the
region list. A stale reference is rejected once the region is replaced or the
page reloads. A connector that does not support region reading and returns
the whole page instead is not treated as success.

`N`/`P` move directly between observed `article` regions. In a content scene,
they use the first node carrying each typed article ancestor, so a feed can
jump between posts without opening the region picker first. They use observed
landmark identity; navigation, suggestions and ordinary text remain available
through `n`/`p` and `Tab`/`Shift-Tab`. If no article role or article ancestor was
observed, the shortcut leaves the current selection unchanged. In a content
scene this selects the first observed node; `Enter` still performs that node's
observed action, while region scoping remains the explicit `v` → `Enter` path.
When multiple article ancestors are visible, their compact boundaries include
the observed ordinal (for example, `[article 2/5]`); this is the current
viewport's observed count, not a claim that a feed is complete.

Keepers call `mode=scene` the same way, passing the `documentId`/`nodeId`
observed from `BrowserRead mode=regions` as `scope`. This path selects an
actually observed region rather than guessing a CSS path. It returns
per-region viewport/DOM content, not a channel-wide history collection.

### Explicit live tab activation

`BrowserInteract action=activate_tab` takes an explicit live clientId/tabId with
required expectedUrl. It selects the tab without changing or reloading its URL;
on a BiDi connection it also focuses the browser window. This is a tool action;
reads do not automatically activate tabs and no TUI shortcut is added. A successful receipt
includes active=true, but callers must read again to verify rendered content.

Action traversal follows [w3m's hyperlink navigation](https://w3m.sourceforge.net/eng/MANUAL.html)
and the [agent-browser interactive snapshot pattern](https://agent-browser.dev/snapshots):
select from observed actionable elements, then operate on their references. The
full scene remains available for reading and copying context.
