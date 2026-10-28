# Native Ego workflow

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

`keyboard.type`, `keyboard.press` and `keyboard.paste` have no selector preflight.
An exception after entering their SDK method cannot be classified as definitely
before input. A dialog receipt can interrupt a button/key sequence, and
`acceptDialog()` plus `info()` does not confirm its release: `info()` has no
held-button or held-key state. Automatic continuation after such an interruption
remains unsupported by this integration. In particular, the installed SDK's
`keyboard.type()` returns void after normal typing and can also return void
after swallowing a dialog interruption. Even if a dialog closes before the
subsequent `info()` read, that read cannot distinguish the two outcomes.
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
browser/tab context. Await explicit completion before `take_over`, then list
tabs and observe the page to verify login. A question or an invisible-window
report is not completion. See the [Keeper procedure](../../skills/browser-lanes/references/connection.md#로그인인증-인계).
These tools are composed by the Keeper; handoff does not automatically create
an Ask, show a window, or verify credentials. The identity receipt and guidance
are source changes; a real Keeper login handoff remains unverified.

For an observed unmanaged tab in an **agent-controlled** Space, explicit
`BrowserAct action=adopt_tab` takes that tab's `tabId` and exact `clientId`.
Optional `pageLabel` is forwarded as the SDK's `as` option; omission lets Ego
assign the label. The receipt retains the tab number, target and unknown origin.
Reads can then use that Page. Existing mutations still require agent-created
Pages; adoption does not change origin or grant those effects.
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
`saveAs` requires a brokered download path and is not exposed here.

These methods are integrated in source with standalone codec and forwarding
checks. The new Page observations, event drain, timeout and step-snapshot
options have no real SDK or installed Keeper execution proof yet. An earlier
owned real Ego fixture in replacement Space 32 executed 22 input/navigation option
and selection steps plus five mouse/state-wait steps. Its
[receipts](../evidence/2026-10-26-ego-options/README.md) are SDK evidence with
explicit routing and UI limits. Installed MASC, Keeper dispatch and visible UI
behavior for this extension remain unverified. See
[the SDK inventory](ego-sdk-coverage.md) for evidence and remaining capabilities.

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
