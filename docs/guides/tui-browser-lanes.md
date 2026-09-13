# Browser Lane in the TUI

Open `:` → `go Browser Lane`, or press `B` from Connectors. Browser starts with
a live Firefox or Zen connection and lists its open tabs. Select any page by title and URL; websites
have no dedicated views or filters. The reader occupies the full content width
and shows the source in its context row. Keeper panels and the composer return
when leaving the reader.

Press `Ctrl-^` (Ctrl-Shift-6) to show or hide Browser. Hiding returns to the
previous surface and restores its search and composer focus. The selected tab,
scroll and unsent chat draft survive the toggle within this TUI session.

Entering Browser ends continuous voice mode and discards any capture in flight,
including a transcript awaiting delivery. An existing Keeper draft is preserved.

| Key | Action |
| --- | --- |
| `l` / `a` | Live / automation browser |
| `[` / `]` | Previous / next tab and read its page |
| `1` … `9` | Select the corresponding observed tab directly when it is listed |
| `j` / `k`, arrows | Scroll page text |
| `J` / `K` | Scroll the observed browser page by one viewport, then refresh the same scene |
| Page Up / Page Down, Home | Page scroll / top |
| `r` | Rediscover tabs and refresh the page |
| `m` | Observe semantic landmarks, then focus the unique `main` (or fallback `article`) region |
| `N` / `P` | Select the next / previous observed `article` region or article ancestor |
| `Ctrl-O` | Open the selected tab screenshot; Esc or q returns |
| `g` | Enter a URL in automation; Enter opens it, Esc cancels |
| `o` / `x` | Open / close the automation session |
| Ctrl-^ / Esc / Left | Hide the reader and return to the previous surface |

Browser belongs to Config. Its title shows the source and latest HTTP request
status. Coordinator connectivity and workspace warnings are labeled separately.
Reads show latency, tab count, selected title, URL, character count and truncation.
A failed or pending refresh retains content labeled as a previous read. Switching
source clears that content; generation-stamped replies reject earlier requests.
Reads happen on entry, source or tab selection, navigation, and explicit refresh.

The URL editor accepts bracketed paste, Unicode backspace and Ctrl-U. Typing
belongs to the editor and cannot trigger Browser commands or the Keeper composer.
The URL editor controls the isolated automation session. Keepers can separately
use `BrowserInteract` to click, fill, or scroll an explicitly selected live tab;
the TUI scene supports observed-element clicks, and the screenshot view supports
mouse clicks and scrolling. Text entry into the page remains a Keeper tool action.

Requests use the authenticated TUI HTTP client. Reading allows 45 seconds for
the tab-list and page-read phases; automation startup and navigation allow 65.
Requests run in switch-owned Eio daemon fibers and return through the TUI mailbox.

`Ctrl-O` captures the explicitly selected tab through the authenticated screenshot
endpoint. The preview keeps the source, tab, text position, and URL draft. A closed tab produces a visible failure rather
than capturing a different active tab. Use `r` to rediscover available tabs.
The image is not staged or sent to a Keeper. PNG preview uses the terminal's
existing image support; unsupported terminals receive an explanation in Browser.

In screenshot view, click a visible link to activate it. Mouse wheel, arrows and
`j`/`k` scroll the actual page, and `r` refreshes the screenshot. The automation
lane also supports pressing the left button, moving, and releasing to drag with
trusted browser pointer actions. Live drag reports that automation is required.
Each completed action captures the resulting page again in the same Lane.

Mouse coordinates require the terminal's measured cell size. If that measurement
is unavailable, the footer explains that click/drag is unavailable; scrolling
and refresh remain usable. Inputs retain the captured document identity, viewport
size, scroll position and URL. A changed observation requires a fresh screenshot
before another pointer action can execute.

See [setup and Keeper usage](../design/browser-lane-examples.md).

## Verification

`test/test_browser_surface.ml` covers page selection, empty browsers and failures.
`test/test_tui_browser_lane.ml` covers decoding, source changes, stale replies and
retained evidence. Related TUI tests cover URL input and multiline text projection.
`scripts/capture-browser-proof.py` captures a public page and automation session
recovery on a scratch runtime. Use a binary built from the changed source;
historical captures are not evidence of the current UI.

### Native browser selection

Live Browser Lane discovers the server's active native connections on entry and
`r`. A single fresh connection is selected automatically. With several connections,
choose Firefox or Zen using `b`, `j/k`, and Enter. The chooser displays the backend's
browser identity and each connection UUID; the reader header names the selected
browser. `r` inside the chooser reloads connections, and Esc returns to the reader.

Each live read and Ctrl-O screenshot pins that connection UUID. Switching browsers
clears the previous tab, text, and scroll before reading the new browser. A missing
selected connection opens the chooser without silently rebinding to another browser,
even when only one remains or both browsers use the same tab number. Select a
connection explicitly to recover. Automation retains its separate browser session. Its label stays generic because
the automation response does not report the browser brand.

Validation: the production pure Browser state module was interpreted against 14
fixtures, including equal tab IDs across clients, stale discovery, disconnected pins,
and screenshot ownership. PTY scenarios cover two-client choice and explicit recovery;
they run in the existing browser-screenshot CI test alias. No local Dune build was run.


## Gecko scene view

After reading a connected Firefox or Zen tab, press `s` to observe its viewport
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

Scene support requires the updated coordinator/native host and extension 0.5.0
in the selected browser profile: 0.5.0 is the first version whose injected
script sends the `view` and `scope` a scene read is answered against, and a
0.4.0 build fails every scene read with `scene missing view`. 0.5.0 also carries
live `scroll_at`. After upgrading, reload the extension in `about:debugging`
and confirm its version there. The
Browser Lane client list reports the browser version, not the extension version.
Source changes and script-level Gecko evidence
alone do not establish that an installed TUI has been updated.


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

The builtin browser-design, frontend-implement and frontend-verify packages cover
visual intent, verified source editing and browser evidence. They are discoverable
skills; users need not name a skill for an ordinary UI request. Newly built MASC
installs seed missing packages through the existing builtin-skill installer.

In screenshot view, the mouse wheel scrolls the area under the pointer, allowing
message lists and sidebars to scroll independently. `j/k` and the up/down keys
scroll the area at the center of the viewport. When terminal cell geometry is
unavailable, the wheel also uses the center and the footer shows `wheel:center`.
The automation lane sends native browser wheel input; the live lane finds the
scrollable DOM ancestor under the pointer. After scrolling, MASC captures the
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

Extension 0.6.0 adds `BrowserInteract action=activate_tab` for an explicit live
clientId/tabId with required expectedUrl. It selects the tab without focusing its
browser window or changing/reloading its URL. This is a tool action; reads do not
automatically activate tabs and no TUI shortcut is added. A successful receipt
includes active=true, but callers must read again to verify rendered content.
Automation rejects activation before selecting a tab.

Action traversal follows [w3m's hyperlink navigation](https://w3m.sourceforge.net/eng/MANUAL.html)
and the [agent-browser interactive snapshot pattern](https://agent-browser.dev/snapshots):
select from observed actionable elements, then operate on their references. The
full scene remains available for reading and copying context.
