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

`waitForURL` accepts exactly one of a string/glob `url` or a `urlRegex` object:

```json
{"method":"waitForURL","urlRegex":{"source":"^https://example\\.test/(done|ready)$","flags":"i"},"options":{"timeout":5000}}
```

The fixed adapter creates a native `RegExp` and passes it to `page.waitForURL`;
the [SDK owns URL matching and polling](https://github.com/citrolabs/ego-lite/blob/v2.1.0/package/ego-browser/src/driver/page-waits.ts#L217).
`source` is a string, including an empty pattern. Optional `flags` is a string;
omission keeps the JavaScript default. Invalid syntax or flags stop this step
before entering the wait and preserve any earlier completed effects. MASC does
not implement a second matcher or evaluate caller function source on the host.
The SDK's function matcher form is not exposed by this workflow. Real installed
SDK/Keeper execution of regex waits remains unverified.

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
its unconfirmed input state is resolved. A selector drag that returns normally
unblocks input only when `dragAndDrop` answers with an object receipt that has
no `dialog` (see below). Coordinate-path drag (`page.drag`) calls `mouse.down`,
`mouse.move` and `mouse.up`, which return void and swallow a dialog interruption,
so no SDK answer shows that the button came up. Once it ran, its result is an
unknown outcome and it blocks further input until the operator's input reset. A
guard that refuses it before any input leaves input usable. A lost key press/type/paste response also
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
Manual held-button and held-key workflows are not exposed. A single `click`, `dblclick`,
pointer or keyboard verb outside a workflow does not take the input, so only workflow steps
and drags are judged by the rule below.

`keyboard.type`, `keyboard.press` and `keyboard.paste` have no selector preflight.
An exception after entering their SDK method cannot be classified as definitely
before input. A dialog receipt can interrupt a button/key sequence, and
`acceptDialog()` plus `info()` does not confirm its release: `info()` has no
held-button or held-key state. Automatic continuation after such an interruption
remains unsupported by this integration. In particular, the installed SDK's
`keyboard.type()` returns void after normal typing and can also return void
after swallowing a dialog interruption. Even if a dialog closes before the
subsequent `info()` read, that read cannot distinguish the two outcomes.
`keyboard.press` and `keyboard.paste` are observed actions: the SDK returns a receipt
for them (`{}`, `{popups}`, or `{dialog}` when a dialog interrupts the action;
[source](https://github.com/citrolabs/ego-lite/blob/aecc5831fc5a9ea01a078b632185992a3a7ac448/package/ego-browser/src/page-model.ts#L620-L639)),
so only `keyboard.type` is receipt-less among these three. The other keyboard calls
`keyboard.insertText`, `keyboard.down` and `keyboard.up` also return void at that commit
([source](https://github.com/citrolabs/ego-lite/blob/aecc5831fc5a9ea01a078b632185992a3a7ac448/package/ego-browser/src/page-model.ts#L612-L643)),
so they declare nothing either.
The workflow therefore stops at a receipt-less holding step, leaves it outside
the completed prefix and retains `inputReleased=false`; no later step or final
snapshot runs. This also requires explicit recovery after ordinary void-returning
typing. Keep the original command and inspect the page rather than typing it
again. The original installation's private operator input-reset confirmation
permits a new distinct command after the operator has checked/reset that Space;
it does not prove SDK cleanup. Automatic, fully settled `keyboard.type` workflows
require an SDK contract that distinguishes the original input's completion from
interruption. Observed action receipts still report immediate popup/dialog data,
and do not verify application success. See the
[SDK input boundary](https://github.com/citrolabs/ego-lite/blob/aecc5831fc5a9ea01a078b632185992a3a7ac448/package/ego-browser/src/page-model.ts#L2674),
[pointer implementation](https://github.com/citrolabs/ego-lite/blob/aecc5831fc5a9ea01a078b632185992a3a7ac448/package/ego-browser/src/driver/page-actions.ts#L1183)
and [keyboard implementation](https://github.com/citrolabs/ego-lite/blob/aecc5831fc5a9ea01a078b632185992a3a7ac448/package/ego-browser/src/driver/page-keyboard.ts#L115).

The host does not take the script's `inputReleased` on trust. `decode` reads what
the SDK declared for each holding step and builds the release state from that
(`Browser_ego_release`):

- an object receipt that has only the members `popups` and `dialog`, each at most
  once, and no `dialog`, is `Receipt_without_dialog`, the only answer that releases
  a step.
  Its `popups` is a list of `{label, targetId}` objects whose two members are
  strings that are not empty. Only `Browser_ego_release.answer_of_json` builds it;
- an object receipt whose `dialog` is an object is `Receipt_with_dialog`;
- `null` is `Void_answer`, which declares nothing;
- any other value is `Undeclared_answer`: a non-object, a member the SDK does not
  declare or that repeats a member, a `popups` that is not a list of such objects,
  a popup with another or a repeated member, or a `dialog` that is not an object;
- a step that was entered and gave no answer is `Never_returned`.

The last four are the answers that release nothing (`Unreleased`). They are public
and anyone may build them, so the type that names the first unreleased step cannot
hold the one answer that releases.

The script turns a void or non-object answer of a holding step into a failure
before it records the step, so a real `keyboard.type` decodes as `Never_returned`.
A `null` or non-object receipt (`Void_answer`, or `Undeclared_answer` for a
non-object) therefore only comes from a reply the script did not produce. An object
receipt with a member the SDK does not declare is recorded as it is and decodes as
`Undeclared_answer`.

A reply that claims release is accepted when every holding step that was entered
is released. It carries their indices as `Released_by_receipts`, or `No_hold` when
no holding step was entered, as when a `fill` fails before a `click`. Otherwise
the reply is an unknown outcome that names the first step that is not released.
A failed reply that reports a held input is `Stopped` with that step, or with
`Held_by_script_report` when every answer is clean. A successful reply cannot
report a held input.

The peer settles its input from `Released`, and restores the readiness it had for
`No_hold`. `Browser_ego_input.command_settled` takes the `proof`, which only
`Browser_ego_release.judge` builds from answers read by `answer_of_json`, so a flag
cannot settle an input. The types do not show that the JSON handed to
`answer_of_json` is the SDK's answer for this pending input. A selector
`drag_to` settles from the one receipt of its `dragAndDrop` call by the same rule:
an object receipt goes through `answer_of_json` and `judge`, and only a reply read
whole settles. A failure the script caught, and a receipt that is missing, `null` or
not an object, end as an unknown outcome and settle nothing.

The receipt's `dialog` is declared by the SDK: it is set from the dialog-opened
error that unwound the driver
([action boundary](https://github.com/citrolabs/ego-lite/blob/aecc5831fc5a9ea01a078b632185992a3a7ac448/package/ego-browser/src/page-model.ts#L2777-L2784),
[receipt type](https://github.com/citrolabs/ego-lite/blob/aecc5831fc5a9ea01a078b632185992a3a7ac448/package/ego-browser/src/page-model.ts#L411-L414)),
so an object receipt without it means the whole action ran. Raw keyboard calls
such as `keyboard.type`, and `mouse.down`, `mouse.move` and `mouse.up`, swallow
that error into void
([raw action](https://github.com/citrolabs/ego-lite/blob/aecc5831fc5a9ea01a078b632185992a3a7ac448/package/ego-browser/src/page-model.ts#L2674-L2687),
[mouse](https://github.com/citrolabs/ego-lite/blob/aecc5831fc5a9ea01a078b632185992a3a7ac448/package/ego-browser/src/page-model.ts#L512-L568)),
so a typed run never releases and the operator's input reset applies.
`Page.info()` and the Page's event buffer are samples of the page, not answers of
the SDK, and `decode` does not use them as release evidence. The SDK documents no
release acknowledgement, and a receipt does not prove that every key or button
came up.

This rests on the SDK implementation at the pinned commit, not on a documented
guarantee. The receipt's `dialog` is `pendingDialog(sessionId) || actionError.dialog`.
If both were empty the field would be `undefined`, JSON would drop it, and the host
could not tell that receipt from a clean one. At the pinned commit that cannot happen
through the SDK's own error class: `PageDialogOpenedError` takes `dialog` as a
required argument and keeps a copy, and every place that builds it passes an object
([class](https://github.com/citrolabs/ego-lite/blob/aecc5831fc5a9ea01a078b632185992a3a7ac448/package/ego-browser/src/browser-runtime.ts#L115-L146),
[dialog opening event](https://github.com/citrolabs/ego-lite/blob/aecc5831fc5a9ea01a078b632185992a3a7ac448/package/ego-browser/src/browser-runtime.ts#L1503)).
An empty `dialog: {}` is still an object and does not release. The SDK's own
real-browser case checks that `page.click` reports the dialog type and message in its
receipt
([page-dialogs.mjs](https://github.com/citrolabs/ego-lite/blob/aecc5831fc5a9ea01a078b632185992a3a7ac448/package/ego-browser/scripts/real-browser-e2e/cases/page-dialogs.mjs#L123-L128)).
An object receipt with an open dialog would need an error that carries the SDK's
error code without being built by that class; the code string appears only in the
runtime and in tests. The SDK's own usage text says a dialog may appear as `receipt.dialog`
or in `page.info()`, and that a receipt describes only the dispatched action
([usage text](https://github.com/citrolabs/ego-lite/blob/aecc5831fc5a9ea01a078b632185992a3a7ac448/package/ego-browser/skill-body/SKILL.md#L410-L422)).
A newer SDK that adds a receipt member makes the receipt undeclared, so the input
stays unconfirmed until this rule is read again.

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

An SDK `EGO_PAGE_EVALUATION_TIMED_OUT` error retains its structured diagnostics
under the workflow receipt's `failure.nativeError`: `code`, `timeoutMs`,
`executionStopped`, `mayHaveLateEffects` and `pageResponsive`. The timeout is
finite and nonnegative; the three observations are booleans. These fields come
from the [SDK error](https://github.com/citrolabs/ego-lite/blob/v2.1.0/package/ego-browser/src/page-model.ts#L416),
without interpreting its message. A first-step evaluation failure also returns
this receipt while its effect outcome remains unknown. An initial URL or other
read failure retains the same diagnostics with `effectPhase: not_started` when
no effect step began; this phase is derived from validated workflow progress.
Stopped execution can still have late effects; the completed prefix and input-release state retain
their existing meaning. Native error diagnostics do not authorize replay or
settle held input. Local codec and SDK-stand-in checks cover these boundaries;
the actual installed Keeper timeout path remains unverified.

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

Goal Space binding is experimental: no installed Keeper has run Goal discovery
through a binding yet.

After `masc_browser_tabs` reports a live Ego connection, bind its observed
client to an existing shared Goal with `masc_browser_session`:

```json
{"action":"bind_goal","goalId":"<existing-goal-id>","lane":"live","clientId":"<observed-client-uuid>"}
```

This records the original installation and numeric Space without taking control
or creating a replacement. Repeating the same binding is idempotent; a different
assignment or sharing the Space across Goals is refused. To read the stored
binding, call:

```json
{"action":"goal_status","goalId":"<existing-goal-id>"}
```

The status is stored metadata and does not prove that the browser is connected.
If the bound connection is unavailable, initial Goal discovery refuses instead
of selecting another browser.

To remove a wrong binding, or to stop Goal discovery from using one, call:

```json
{"action":"unbind_goal","goalId":"<existing-goal-id>"}
```

The reply names the removed binding (`removed`, `null` when the Goal had none)
and the `actor` who removed it. Unbinding changes no browser, Space or Page.
Afterwards initial discovery chooses a browser as it does without a binding,
and `bind_goal` can record a different Space for the Goal.

## Space control wait

`masc_browser_act` with `action: "wait_for_control"`, the observed live
`clientId` and optional `controlOptions: {interval, timeout}` invokes Ego's
`TaskSpace.waitForControl()` inside the same agent-owned Space. Both options
are positive finite milliseconds. The SDK owns polling and its deadline, and
MASC adds no timer around that call, so the timeout must end inside the
action's reply window: a longer one is refused before the wait starts, and an
omitted one waits for that window. An omitted interval keeps the SDK default.

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
