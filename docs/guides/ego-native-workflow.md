# Native Ego workflow

For a native PNG, send `BrowserRead` with `mode: "screenshot"`, the observed
`lane: "live"`, Ego `clientId`, `tabId`, and optional `screenshotOptions`:

```json
{"lane":"live","clientId":"<observed Ego clientId>","tabId":7,"mode":"screenshot",
 "screenshotOptions":{"fullPage":true,"scale":"css","raw":false}}
```

The options use the SDK contract: `fullPage` and `raw` are booleans; `scale`
accepts `"css"`; `clip` requires finite CSS-pixel `x`/`y`, positive finite
`width`/`height`, and optional positive finite `scale`. Omitted options keep
native defaults, including explicit false values when supplied. The SDK owns
the capture wait. MASC supplies the output path, reads only an owned regular
file up to the existing Vision image limit, and removes the temporary file
after a capture response, including a failed response. If execution is cancelled
before returning, worker retirement sweeps the owned capture directory.

Omit `screenshotOptions` for a viewport PNG with viewport observation metadata.
An explicit object, including `{}`, returns an artifact with `scope: "page"`,
the requested `captureOptions` and measured PNG dimensions, without `viewport`.
Use `keeper_image_read` to inspect its pixels. A full-page, clipped or scaled
image cannot supply viewport coordinates for pointer input. Native options
require Ego; other browser transports refuse them before capture.
The HTTP capture endpoint accepts the same `screenshotOptions`; the worker
wire command calls that object `options`. Real SDK capture with these options
and the installed Keeper route remain unverified.

Choose the observed live Ego `clientId` and `tabId`, read the page, then send
`BrowserInteract` with `action: "workflow"`, its observed `expectedUrl`, and
the planned `steps`. The entire sequence ends with one native snapshot. A
failure or dialog stops following steps and returns the completed prefix.
Do not replay that prefix when input may already have happened.

Each step's optional `options` object uses the installed SDK's names and
milliseconds. Options are validated for that exact method. Omission preserves
the SDK default. For example:

```json
[
  {"method":"fill","selector":"loc=css:#editor","text":" append","options":{"clearFirst":false,"timeout":3000}},
  {"method":"selectOption","selector":"loc=css:#choice","selectionJson":"{\"label\":\"Beta\"}","options":{"timeout":3000}},
  {"method":"click","selector":"loc=css:#submit","options":{"button":"left","position":{"x":8,"y":8},"label":"Submit selected choice"}},
  {"method":"waitForLoadState","options":{"timeout":5000}}
]
```

Use selectors from current page observations. `selectionJson` contains one JSON
value: a value-or-label string, `{value?,label?,index?}`, a mixed array of those
choices, or `null`. An empty array also clears selection. The SDK decides how
the actual select element behaves, including programmatic disabled-option
selection; MASC preserves the requested selection forms.

| Methods | Native options |
| --- | --- |
| `click` | button, clickCount, delay, position, force, timeout, label |
| `dblclick` | button, delay, position, force, timeout, label |
| `hover` | position, force, timeout, label |
| `dragAndDrop` | button, sourcePosition, targetPosition, force, timeout, label |
| `mouse.click` | button, clickCount, delay, label |
| `mouse.move` | steps, label |
| `mouse.wheel` | label |
| `fill` | clearFirst, timeout |
| `press` | delay, timeout |
| `focus`, `selectOption`, `waitForURL`, `waitForSelector` | timeout |
| `goto` | referer, timeout, waitUntil |
| `reload` | timeout, waitUntil |
| `keyboard.type`, `keyboard.press` | delay |
| `waitForLoadState` | timeout, idleMs |
| `waitForFunction` | timeout, polling |
| `fetch` | timeout, method, headers, body, cache, credentials, integrity, keepalive, mode, redirect, referrer, referrerPolicy |
| `snapshot` | scope, root, includeActionMarks, includeStableLocator |

`evaluate`, `keyboard.insertText`, `keyboard.paste`, `url`, `title`, `info`,
`events`, and `waitForTimeout` accept no options.
`keyboard.paste` accepts step `text` and optional `html`. Only pointer actions
accept an option `label`; MASC prefixes it with the actor's identity.
`waitForSelector` takes step `state`. `waitForLoadState` has an optional step
`state`, whose omission uses the SDK default.

`mouse.click` and `mouse.move` take observed CSS-pixel `x`/`y` coordinates.
`mouse.wheel` uses `x`/`y` as horizontal/vertical deltas: first move or click
over the observed scroll container within this same workflow invocation.
`dragAndDrop` takes `selector` and `destination`, both observed locators.
If a pointer click or drag fails, release stays unconfirmed. The SDK's
`mouse.up()` can return normally when a dialog interrupted the release, and a
selector click does not preserve its coordinates in the public mouse handle.
Native workflows and selector `drag_to` therefore do not synthesize a release
from that handle or call its void return a release acknowledgement. A failed
selector drag preserves the original SDK failure and blocks further input until
its unconfirmed input state is resolved. Coordinate-path drag has a separate
manual-input implementation; this selector repair does not establish its release
acknowledgement or safe recovery. A lost key press/type/paste response also
keeps release unconfirmed without guessing a key-up sequence. `keyboard.paste`
uses the SDK's `ControlOrMeta+V` sequence, so it can leave a modifier held.
`press` is included because its key sequence may be held if
its reply is lost. Before `press`, a read-only SDK attached-selector wait can
refuse the step without sending keys. It does not authorize a later press or
classify an exception from that actual press as pre-effect. A dialog can be
reported before release: answering it alone does not prove that every original
key or pointer button was released. An unconfirmed release prevents further
input on that connection. The result reports `inputReleased` independently of completed
effects; a guard does not make the failed action successful.
Manual held-button and held-key workflows are not exposed.

A selector gesture (`click`, `dblclick`, `dragAndDrop`) whose target the
SDK cannot resolve fails with the SDK's typed `ElementResolutionError`: no match,
hidden, disabled, obscured, or an invalid selector. These gestures resolve the
target before the first press and between complete press and release pairs,
never between a press and its release, so nothing is held. `inputReleased` stays
`true` and the connection keeps accepting input. The step is still reported as a
failure that may have had an effect, because a hover move or the first click of a
double click can precede the refusal. Any other error from a holding step keeps
release unconfirmed, including one with the same message from another error
type or a refusal from a step that resolves no selector (`mouse.click`,
`keyboard.*`). Measured with Ego Lite 0.6.1.11 on 2026-10-27: missing, hidden,
disabled and invalid selectors, a missing `dblclick` target and a missing drag
source or destination each left the page with no mouse or key event, and the next
click worked.

`press` is not on that list. It sends its keys through the SDK's raw keyboard,
which the SDK's input tracking does not see, so a key command that times out
comes back as the same typed error after the key was sent. Measured the same day
with a keydown handler that stalled the page for 17 seconds: `press` failed with
`page.press timed out after 3000ms: CDP request timed out: Input.dispatchKeyEvent`
after the page had received the keydown. `click`, `dblclick` and `dragAndDrop`
under a stalled mousedown or mouseup failed with the plain `CDP request timed
out: Input.dispatchMouseEvent`, which stays unconfirmed. A `press` on a missing
selector is still refused before any key by the read-only attached-selector wait.

`keyboard.type`, `keyboard.press` and `keyboard.paste` have no selector preflight.
An exception after entering their SDK method cannot be classified as definitely
before input. A dialog receipt can interrupt a button/key sequence, and
`acceptDialog()` plus `info()` does not confirm its release: `info()` has no
held-button or held-key state. Automatic continuation after such an interruption
remains unsupported by this integration. A holding step that returns no receipt
stops the workflow, stays outside the completed prefix and retains
`inputReleased=false`; no later step or final snapshot runs. Keep the original
command and inspect the page rather than repeating it. The original
installation's private operator input-reset confirmation permits a new distinct
command after the operator has checked/reset that Space; it does not prove SDK
cleanup.

The installed SDK's `keyboard.type()` always returns void, both when typing ran
to its end and when it swallowed a dialog interruption. A dialog closed before
the subsequent `info()` read leaves nothing for `info()` to show. The Page's
event buffer tells the two apart: the SDK buffers `Page.javascriptDialogOpening`
in the same handler that rejects the blocked key, so the event is already there
when `keyboard.type()` returns. The workflow reads the buffer before and after
the step:

- A dialog already open when the step starts: the SDK sends no key and emits no
  event for it, so nothing would show the typing was swallowed once the dialog
  closes. The workflow stops before any key with `inputReleased` still `true`,
  and `failure.dialog` names the dialog. The check runs after the first buffer
  read: a dialog that opened before the read is open here, and one that opens
  after it leaves its event for the read after typing.
- No opening event during the step and no open dialog: the step is recorded as
  completed with receipt `null`, `inputReleased` becomes `true` and the workflow
  continues.
- An opening event, or a dialog still open: the workflow stops as described
  above. `failure.dialog` is present only while the dialog is still open.
- A failed or malformed buffer read proves nothing. Before typing, nothing is
  typed and `inputReleased` stays `true`. After typing, `inputReleased` stays
  `false`.

Reading the buffer drains it. The workflow parks what it read, per Page, and a
later `events` step returns the parked events first and then new ones, in
order. Parked events live in the Ego process only and are trimmed to the newest
10000, the SDK's own buffer size.

Measured with Ego Lite 0.6.1.11 on 2026-10-27: ordinary typing left no opening
event in 10 of 10 runs, and a dialog-interrupted run left an opening event in 10
of 10, also when the dialog was closed before `info()`. A dialog opened by a
cross-origin frame and `beforeunload` were not measured. The SDK source says
Chromium delivers every dialog event on the Page session.

Observed action receipts still report immediate popup/dialog data,
and do not verify application success. See the
[SDK input boundary](https://github.com/citrolabs/ego-lite/blob/aecc5831fc5a9ea01a078b632185992a3a7ac448/package/ego-browser/src/page-model.ts#L2674),
[pointer implementation](https://github.com/citrolabs/ego-lite/blob/aecc5831fc5a9ea01a078b632185992a3a7ac448/package/ego-browser/src/driver/page-actions.ts#L1183)
and [keyboard implementation](https://github.com/citrolabs/ego-lite/blob/aecc5831fc5a9ea01a078b632185992a3a7ac448/package/ego-browser/src/driver/page-keyboard.ts#L115).

`url`, `title`, `info` and `snapshot` return the SDK's native value in that
step's `receipt`. `snapshot` supports `scope: "full_page"`,
`"only_within_viewport"` or `"subtree"`; subtree requires a current `root` ref
from the same Page. Root is rejected outside subtree scope. The two inclusion
flags preserve explicit `false` values. The workflow still ends with its usual
final snapshot, controlled by top-level `snapshotScope` and `maxChars`.

`events` reads **and clears** the SDK process's buffer for this Page. It counts
as an effect: a lost or failed drain is not permission to replay it. This is
not a persistent event history across SDK process restarts. `waitForTimeout`
takes nonnegative finite `milliseconds`, including zero. Use `waitForSelector`,
`waitForURL`, `waitForLoadState` or `waitForFunction` for readiness; elapsed time
alone proves no app state. A dialog returned by `info` stops following steps.
Observation result types are validated before accepting a workflow receipt.

For login, 2FA or captcha, hand the same live client to the operator with
`BrowserAct action=hand_off`. Its receipt names `spaceId` and `spaceName` from
that TaskSpace before handoff; no Page operation follows the handoff. Use those
values in `masc_ask` with the required human step, original Task/Goal binding and
browser/tab context. Await explicit completion before `take_over`. Native
takeover returns the same numeric Space and the Page Ego captured at that user
boundary as `activeTabId`/`egoPage`, including an unmanaged tab with `label:null`.
This is the boundary Page, not proof of current focus or login. The handle's
Space/target/label/origin must still match that Space's native inventory; a
missing or changed target is uncertain, never replaced by the current active
tab. An absent native boundary Page returns no active ID.

For an unmanaged boundary Page, explicitly `adopt_tab` that observed ID before
reading it; takeover itself neither adopts nor reads a document. Explicit
effects then use the adopted native Page with its original origin. List tabs
and observe the
intended managed Page to verify login. SDK takeover runs without a host reply
clock; a lost result is never replayed or treated as input-reset confirmation.
A question or an invisible-window
report is not completion. See the [Keeper procedure](../../skills/browser-lanes/references/connection.md#로그인인증-인계).
These tools are composed by the Keeper; handoff does not automatically create
an Ask, show a window, or verify credentials. The identity receipt and guidance
are source changes; a real Keeper login handoff remains unverified.

Before handing off an agent-controlled Space, `BrowserInteract activate_tab`
can explicitly activate its observed managed Page, with exact `clientId`,
`tabId` and `expectedUrl`. It uses Ego's native `TaskSpace.cdp` to look up that
target's window, restores it only if minimized, and activates the target.
The command rechecks Page identity, URL and window before effects and observes
them afterward. These CDP calls are not atomic: a concurrent change or a lost
response after activation remains uncertain and must not trigger a replay.
The receipt reports `active` and `window` (`windowId`, `stateBefore`,
`stateAfter`, `restored`). These are native observations, not proof that the
operator can see the rendered page or that the app has OS focus. Fullscreen
and maximized windows are not resized. No claim, takeover, navigation, login
or new Space is part of activation. Never use it while the Space is delegated.
Real SDK activation/window restoration and installed Keeper execution remain
unverified; a successful source fixture is below visible login handoff proof.

For an observed unmanaged tab in an **agent-controlled** Space, explicit
`BrowserAct action=adopt_tab` takes that tab's `tabId` and exact `clientId`.
Optional `pageLabel` is forwarded as the SDK's `as` option; omission lets Ego
assign the label. The receipt retains the tab number, target and unknown origin.
Reads and explicit Page effects can then use that native Page, including
input, navigation and activation. Adoption preserves its origin;
unmanaged tabs remain unavailable to those operations. Unknown-origin Pages
remain protected from close; use release to return their tabs to the operator.
`action=release_tab` returns an unknown-origin managed Page without closing its
browser tab; agent-created Pages must be closed instead. Neither operation takes
over user control or clears uncertain input release. If a receipt is lost, list
the same Space's tabs and reconcile its current label before continuing. Never
replay the lost operation. This is source integration with stand-in forwarding
checks; real SDK, installed Keeper and UI execution remain unverified.

`evaluate` and `waitForFunction` take browser `source` and optional
`argumentJson`. The source never executes in the host Node process. Page code,
including a wait predicate, can have effects before failing. `fetch` accepts
HTTP(S) absolute or page-relative URLs and returns its native response receipt.
A scheme-relative URL such as `//api.example/path` is also accepted: the
browser inherits the page's HTTP(S) scheme and uses the specified host, with
its normal credentials policy and CORS checks.
`options.saveAs` accepts an artifact filename such as `report.pdf`, with no
directories or control characters. Ego saves binary bytes to a fresh private
UUID path; the step receipt returns `source="fetch"`, `downloadId` and the
requested `suggestedFilename`, without a host path. Retrieve that ID through
BrowserRead `mode=downloads` on the same client/tab and use only its finalized
artifact reader. Native download events have `source="native_download"`.
HTTP errors can still produce a completed save; inspect response `ok`/`status`.
If a later step or snapshot fails, a completed save remains in the living SDK
process's inventory. Read it without repeating Fetch. A lost or malformed save
receipt cannot be replaced by file-existence inference. Registry recovery
across worker/SDK-process replacement remains unimplemented.

These methods are integrated in source with standalone codec and forwarding
checks. The new Page observations, event drain, timeout and step-snapshot
options have no real SDK or installed Keeper execution proof yet. An earlier
owned real Ego fixture in replacement Space 32 executed 22 input/navigation option
and selection steps plus five mouse/state-wait steps. Its
[receipts](../evidence/2026-10-26-ego-options/README.md) are SDK evidence with
explicit routing and UI limits. Installed MASC, Keeper dispatch and visible UI
behavior for this extension remain unverified. See
[the SDK inventory](ego-sdk-coverage.md) for evidence and remaining capabilities.

## Goal-bound Space

After `masc_browser_tabs` reports a live Ego connection, bind its observed
client to an existing shared Goal with `masc_browser_session`:

```json
{"action":"bind_goal","goalId":"<existing-goal-id>","lane":"live","clientId":"<observed-client-uuid>"}
```

This records the original installation and numeric Space without taking control
or creating a replacement. Repeating the same binding is idempotent; a different
assignment or sharing the Space across Goals is refused. There is no unbind
action on this tool. To read the stored binding, call:

```json
{"action":"goal_status","goalId":"<existing-goal-id>"}
```

The status is stored metadata and does not prove that the browser is connected.
If the bound connection is unavailable, initial Goal discovery refuses instead
of selecting another browser.

## Space control wait

`masc_browser_act` with `action: "wait_for_control"`, the observed live
`clientId` and optional `controlOptions: {interval, timeout}` invokes Ego's
`TaskSpace.waitForControl()` inside the same agent-owned Space. Both options
are positive finite milliseconds; omitted values retain SDK defaults. The SDK
owns polling and its deadline. MASC adds no timer around that call.

This is an in-place SDK availability observation. It does not complete a login
handoff, reclaim a user-held Space, or clear uncertain input release. A handed-off
Space is refused before the wait; the existing explicit operator-confirmation
and same-Space `take_over` flow still applies. Subsequent commands recheck normal
ownership and input state. Keeper activity names the Space wait separately.

## Dated Space metadata in MASC

`BrowserAct` with `action: "space_status"`, `lane: "live"` and the exact
observed `clientId` refreshes native metadata for the original numeric Space.
It uses `listTaskSpaces`, without constructing a TaskSpace, navigating a Page
or taking control. A missing Space is an error; no replacement is created.

The TUI Browser Lane selection and selected connection show the last SDK Space
name, raw ownership value and SDK observation time. This is separate from the
attachment name and caller activity. Rendering reads the published cache and
does not refresh Ego. A null publication is explicitly unobserved; failed
connection refreshes retain the dated value alongside the failure. A value
bound to a different numeric Space is rejected.

This display is not proof of current control, a visible browser window or
login completion, and never authorizes input or takeover. Source/component
checks cover decoding and refresh ownership; installed and rendered TUI
behavior remain unverified.

