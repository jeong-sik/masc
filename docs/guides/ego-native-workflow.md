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
the [SDK owns URL matching and polling](https://github.com/citrolabs/ego-lite/blob/4cf79356509bccdead17863250b442f60a881c25/package/ego-browser/src/driver/page-waits.ts#L228).
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
selector drag preserves the original SDK failure and reports
`release_uncertain`. A selector drag that returns normally reports
`command_settled` only when `dragAndDrop` answers with an object receipt that
has no `dialog` (see below). MASC sends no coordinate-path drag (`page.drag`): it
calls `mouse.down`, `mouse.move` and `mouse.up`, which return void and swallow a
dialog interruption, so no SDK answer would show that the button came up. A lost key press/type/paste response also
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
Manual held-button and held-key workflows are not exposed. The rule below applies
to native selector and snapshot-target `click` and `dblclick`, drags, and
input-holding workflow steps. Ordinary Ego `type_text` also acquires this input
ownership through the native typing path below.

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
so none provides a release receipt. `keyboard.insertText` only invokes native
`Input.insertText`, with no key-down/up, and is classified `No_hold`; it does not
attest release or application success. Manual `down`/`up` are not exposed.

Ego `type_text` and workflow `keyboard.type` use the same fixed native typing
producer, invoking `page.keyboard.type()` once. Ordinary `type_text` checks the
observed document, URL and enabled editable focus before typing. A workflow
types at its current Page's focus; use an observed editor's `focus` step when
needed. Choose native `fill` to replace an observed input, textarea or
contenteditable editor, `keyboard.insertText` for literal insertion without
key-down/up, or `keyboard.paste` for text/HTML. MASC never substitutes a method.
Selector-to-selector `drag_to` and workflow `dragAndDrop` keep their observed
receipt boundary.

Before native holding input, MASC persists the actual command's `Pending`
intent. For raw typing it also fixes the original source Page and the current
Page's canonical Space, permanent label, target and origin. The fixed producer
observes a fresh native isolated context and places authenticated start/end
binding markers around the awaited typing call. It preserves the actual void
return and checks the native event interval between those bounds for dialog,
document, context or session changes. A void return by itself still proves
nothing. The local check must succeed before any later workflow step runs;
the Host independently validates the returned capture and its original
command, generation, step and Page bindings before accepting that progress.
These internal bindings cannot be supplied through public tool arguments or
application evaluation results. See the [producer interface](../../lib/browser_ego_raw_type.mli)
and [native-window classifier](../../lib/browser_ego_native_window.mli).

A verified ordinary typing result has `receipt: null` and a separate
`nativeCompletion`; the completed raw workflow row uses the same pair. This
summary identifies a Host-verified SDK tail, not a fabricated SDK receipt,
physical key release, input freshness or application acceptance. Observe the
same document's values, pixels or independent application result for the task's
outcome. Native event arrays, CDP setup/replies and invocation nonces stay
private: they can contain cookies or authorization headers. Success, partial
failure and transport errors expose only the fixed safe completion/failure
summary and strictly validated native error fields, never those raw captures.

Typing consumes this SDK process's Page event buffer for its pre-window and
interval checks. A later workflow `events` step sees only the remaining buffer,
not a complete history of the typing invocation. This observation is not
persistent event history across SDK process replacement.

An entered raw call without a verified interval stops the workflow before
later steps and retains uncertain input. A validated `Not_entered` result
concerns only that raw step: observation setup may already have run, so it is
not a claim of no effects.
Ordinary typing can restore its prior readiness; a workflow must still judge
every earlier entered holding step. A swallowed dialog/void result does not
acquire an invented SDK error code. An actual thrown SDK error is retained
only through the existing strict native-error projection.

Removing the native binding is later, nonholding cleanup. A separately valid
typing interval can settle its input even if this cleanup fails; the result
remains a partial cleanup failure and the workflow stops before following
steps. A malformed optional cleanup diagnostic is omitted only when the Host
has validated that exact cleanup-only failure after the final verified raw
tail, with no later pending action or Page transition. A lost or malformed
overall reply, ambiguous progress, or an unconfirmed later holding step still
leaves the release unconfirmed. Never replay typing because cleanup or its reply failed.

A pre-effect refusal preserves previous input readiness. Already dispatched
receipt-less holding input stays unconfirmed: inspect the page rather than
typing the same text again, because its effect is unknown. Input readiness
lives with one connection; a new connection starts `command_settled`, which
says nothing about an older connection's input.
The separate native window does not change the SDK's void contract or repair
historical receipt-less failures. The retained
[normal one-key experiment](../evidence/ego-native-window-foundation-20261102/README.md)
establishes a native experimental tail only. Current producer/Host checks use
owned SDK stand-ins; installed MASC raw typing, interrupted-input recovery and
full native parity remain unverified. Observed action receipts still report
immediate popup/dialog data and do not verify application success. See the
[SDK input boundary](https://github.com/citrolabs/ego-lite/blob/aecc5831fc5a9ea01a078b632185992a3a7ac448/package/ego-browser/src/page-model.ts#L2674),
[pointer implementation](https://github.com/citrolabs/ego-lite/blob/aecc5831fc5a9ea01a078b632185992a3a7ac448/package/ego-browser/src/driver/page-actions.ts#L1183)
and [keyboard implementation](https://github.com/citrolabs/ego-lite/blob/aecc5831fc5a9ea01a078b632185992a3a7ac448/package/ego-browser/src/driver/page-keyboard.ts#L115).

The Host does not take the script's `inputReleased` on trust. `decode` builds
each holding step's typed evidence through
[`Browser_ego_release`](../../lib/browser_ego_release.mli):

- an object receipt that has only the members `popups` and `dialog`, each at most
  once, and no `dialog`, is `Receipt_without_dialog` for a receipt-backed step.
  Its `popups` is a list of `{label, targetId}` objects whose two members are
  strings that are not empty. Only `Browser_ego_release.answer_of_json` builds it;
- a raw typing window independently verified for its expected invocation is
  `Native_window_tail`. It keeps its private completion provenance separate
  from the SDK receipt path; JSON or a void flag cannot construct it;
- an object receipt whose `dialog` is an object is `Receipt_with_dialog`;
- `null` is `Void_answer`, which declares nothing;
- any other value is `Undeclared_answer`: a non-object, a member the SDK does not
  declare or that repeats a member, a `popups` that is not a list of such objects,
  a popup with another or a repeated member, or a `dialog` that is not an object;
- a step that was entered and gave no answer is `Never_returned`;
- an unconfirmed native window or conflicting evidence also releases nothing.

Unreleased reasons are public and supply no completion authority. Only the
receipt decoder and the verified-window boundary build successful answers.

For receipt-backed holding steps, the script stops on a void or non-object
answer rather than recording a successful step. An object receipt with an
undeclared member also cannot settle input. Raw typing is accepted only with
its separately validated native window; `receipt: null` without that evidence
is not a clean answer. Historical `keyboard.type` failures and bare void replies
remain their original evidence and cannot be promoted into a native completion.

A reply that claims release is accepted when every holding step that was entered
has valid evidence. The one `judge` carries receipt-only indices as
`Released_by_receipts`, or retains mixed/native provenance in
`Completed_by_evidence`. Identical window duplicates count once; contradictory
private invocations or a receipt/window conflict at the same step refuse.
`No_hold` applies only when no holding step was entered, as when a `fill` fails
before a `click`. Otherwise the reply names the first unconfirmed step.
A failed reply that reports a held input is `Stopped` with that step, or with
`Held_by_script_report` when every answer is clean. A successful reply cannot
report a held input.

The peer settles its input from `Released`, and restores its previous readiness
for whole-command `No_hold`.
[`Browser_ego_input.command_settled`](../../lib/browser_ego_input.mli) accepts
only the judge's proof. Native-window bindings must additionally match the
actual pending command/generation, source Page label and the connection's
numeric Space; Page-scoped input requires the same source/current Page.
Receipt-backed answers retain their call-site responsibility: the
types alone cannot establish that JSON is the actual SDK answer. A selector
`drag_to` still settles from the one declared `dragAndDrop` receipt through
`answer_of_json` and `judge`; a missing, `null` or non-object receipt establishes
no completion.

The receipt's `dialog` is declared by the SDK: it is set from the dialog-opened
error that unwound the driver
([action boundary](https://github.com/citrolabs/ego-lite/blob/aecc5831fc5a9ea01a078b632185992a3a7ac448/package/ego-browser/src/page-model.ts#L2777-L2784),
[receipt type](https://github.com/citrolabs/ego-lite/blob/aecc5831fc5a9ea01a078b632185992a3a7ac448/package/ego-browser/src/page-model.ts#L411-L414)),
so an object receipt without it means the whole action ran. Raw keyboard calls
such as `keyboard.type`, and `mouse.down`, `mouse.move` and `mouse.up`, swallow
that error into void
([raw action](https://github.com/citrolabs/ego-lite/blob/aecc5831fc5a9ea01a078b632185992a3a7ac448/package/ego-browser/src/page-model.ts#L2674-L2687),
[mouse](https://github.com/citrolabs/ego-lite/blob/aecc5831fc5a9ea01a078b632185992a3a7ac448/package/ego-browser/src/page-model.ts#L512-L568)),
so void is never release proof. MASC sends no raw pointer drag, and raw typing
uses only the separate bounded native-window path above.
`Page.info()` and unbounded event samples cannot establish that interval or
complete an interrupted call. The SDK documents no release acknowledgement,
and neither a receipt nor a verified typing tail proves that every key or
button came up.

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
from the [SDK error](https://github.com/citrolabs/ego-lite/blob/4cf79356509bccdead17863250b442f60a881c25/package/ego-browser/src/page-model.ts#L416),
without interpreting its message. A first-step evaluation failure also returns
this receipt while its effect outcome remains unknown. An initial URL or other
read failure retains the same diagnostics with `effectPhase: not_started` when
no effect step began; this phase is derived from validated workflow progress.
Stopped execution can still have late effects; the completed prefix and input-release state retain
their existing meaning. Native error diagnostics do not authorize replay or
settle held input. Local codec and SDK-stand-in checks cover these boundaries;
the actual installed Keeper timeout path remains unverified.

An SDK `EGO_NAVIGATION_TIMEOUT` also retains `code`, `timeoutMs`, `committed`,
`waitUntil` and its optional `url`/`readyState` under `failure.nativeError`,
following the [SDK navigation error](https://github.com/citrolabs/ego-lite/blob/4cf79356509bccdead17863250b442f60a881c25/package/ego-browser/src/driver/page-waits.ts#L83).
Missing observations stay absent. `committed: true` may mean the page moved
without reaching the requested lifecycle; it does not complete the workflow,
release input or authorize a repeated navigation. `committed: false` does not
prove no external effect occurred. Read the same Page before deciding the next
action. Receipt/SDK-stand-in checks do not establish actual Keeper navigation
timeout behavior.

An SDK `EGO_PAGE_DIALOG_OPENED` error retains `code`, `method`, `sessionId` and
the native `dialog` object under `failure.nativeError`. MASC validates the
dialog's recognized `type` and text `message`, plus any supplied `defaultPrompt`,
`url`, `frameId` and `hasBrowserHandler` fields, without interpreting page text.
These names follow the [SDK error](https://github.com/citrolabs/ego-lite/blob/12407167f84a58af24044f072868051952131491/package/ego-browser/src/browser-runtime.ts#L115).
Missing optional observations stay absent. This preserves an interrupted first
evaluation's diagnostics even when no effect completed. Its outcome remains
unknown; initial reads that failed before input retain their not-started phase.
The dialog observation neither completes the interrupted operation nor settles
its release. Answer the dialog on the same managed Page, observe its state,
and decide a distinct next action without replaying the stopped workflow.

After successful work, `BrowserAct action=finish_space` completes that native
task once. `keepPages` accepts either a list of distinct observed permanent
Page labels (default `[]`) or the native literal `"all"`. MASC forwards `"all"`
without first enumerating Pages; the SDK retains the Space even when no managed
Pages remain. Completion ends every former Page label, including retained
Pages' labels. Only a validated native `closedSpace=true` receipt permits file
cleanup; retained Spaces keep browser-backed files. A lost receipt stays
uncertain and must not be replayed. Connection retirement, errors and login
handoff are not successful task completion.

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
clock; a lost result is never replayed.
A question or an invisible-window
report is not completion. See the [Keeper procedure](../../skills/browser-lanes/references/connection.md#로그인인증-인계).
These tools are composed by the Keeper; handoff does not automatically create
an Ask or verify credentials. Its identity receipt does not verify that a
window is visible. The identity receipt and guidance
are source changes; a real Keeper login handoff remains unverified.

The public [TaskSpace.handOff implementation](https://github.com/citrolabs/ego-lite/blob/4cf79356509bccdead17863250b442f60a881c25/package/ego-browser/src/page-model.ts#L1014)
awaits the native handoff and stops background Page discovery. The
[native API contract](https://github.com/citrolabs/ego-lite/blob/4cf79356509bccdead17863250b442f60a881c25/docs/native-bindings-api.md#L610)
describes control transfer and status, without a rendered-window acknowledgement.
The native implementation's UI behavior is not established by those public
sources, so neither visible presentation nor absence of native window handling
may be inferred from the JavaScript wrapper alone.

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

To cancel a pending native browser download, first read its `downloadId` with
BrowserRead `mode=downloads` on the same client and tab, then send one workflow
step `{"method":"download.cancel","downloadId":"<observed UUID>"}`.
The worker retains that exact Page's native Download handle privately until
the save settles and invokes its SDK `cancel()` once. Fetch saves, completed
downloads, missing handles and other Pages are refused before cancellation.
No caller-selected file path or browser-wide download configuration is used.

The step receipt is `{downloadId, source:"native_download", cancelReturned:true}`.
It means the native call returned; the SDK explicitly allows completion to win
the cancellation race. Read the same tab's download inventory for the observed
transfer status. A lost response is an uncertain effect and must not be replayed.
The existing save, failure observation, temporary-file deletion and finalized
artifact publication remain worker-owned. Native path/delete handles are not
exposed as host file authority. This cancellation integration has component
checks only; actual SDK transport and Keeper execution remain unverified.
The native cancellation behavior is pinned to
[Ego SDK v2.1.0 DownloadArtifact.cancel](https://github.com/citrolabs/ego-lite/blob/4cf79356509bccdead17863250b442f60a881c25/package/ego-browser/src/driver/downloads.ts#L270).

These methods are integrated in source with standalone codec and forwarding
checks. The new Page observations, event drain, timeout and step-snapshot
options have no real SDK or installed Keeper execution proof yet. An earlier
owned real Ego fixture in replacement Space 32 executed 22 input/navigation option
and selection steps plus five mouse/state-wait steps. Its
[receipts](../evidence/2026-10-26-ego-options/README.md) are SDK evidence with
explicit routing and UI limits. Installed MASC, Keeper dispatch and visible UI
behavior for this extension remain unverified. See
[the SDK inventory](ego-sdk-coverage.md) for evidence and remaining capabilities.

## Popup continuation in one SDK process

`clickAndWaitForPopup` arms native `Page.waitForEvent("popup")` before one
`Page.click` call. It reconciles the returned handle's Space and permanent label
against the unique native inventory row, then uses that row's canonical Page.
The installed SDK's lightweight event handle may omit target ID and origin;
those fields are never invented from that handle or used to adopt a tab.
Before any workflow effect, the host fixes the original Page's complete identity
from a fresh native inventory. The SDK process checks that exact identity before
acting, and the host compares it again before accepting the returned source.
The caller cannot supply this internal expected identity.

```json
{
  "action": "workflow",
  "lane": "live",
  "clientId": "<observed client>",
  "tabId": 1,
  "expectedUrl": "https://example.test/opener",
  "steps": [
    {"method": "clickAndWaitForPopup", "selector": "a[target=_blank]"},
    {"method": "waitForURL", "url": "https://example.test/child"},
    {"method": "fill", "selector": "input[name=title]", "text": "Owned result"}
  ]
}
```

Ordinary `options` are the native click options. Optional `popupOptions` accepts
only the native event wait's `timeout`, in milliseconds; omission preserves the
SDK default. A popup URL is not mandatory. Existing following `waitForURL` and
`waitForLoadState` steps express the caller's desired result on the acquired
Page. The final snapshot and top-level returned `tabId` identify that Page;
`sourceTabId` and `pages.source` preserve the opener. `pages.current` and each
transition preserve canonical native identity plus the stable MASC tab ID for a
later explicit tool call. Source routing is not overwritten with the popup URL.

A returned trigger whose popup wait or identity reconciliation fails appears as
`pendingAction` with the exact native trigger receipt, outside the completed
step prefix. The effect is not replayed. A popup observed after an uncertain
trigger can be retained as an unselected transition without operating it. Native
event failure diagnostics remain observations. No Page is fabricated or adopted
on a failed/foreign/ambiguous event. The native popup waiter is consumed on both
trigger success and failure; no host timeout, Promise.race or cancellation API is
invented. SDK round disposal still owns interruption of an unfinished wait.

Input uncertainty remains connection-wide. Because a lost reply can follow
input on a different Page, a popup workflow's pending input is Space-scoped
and keeps the original source identity; it does not guess which
Page holds input. A raw typing window after a selected popup binds both the
original source and that step's current canonical Page. The Host reconstructs
the current Page from validated selected transitions; arbitrary Page identities
do not authorize continuation. SDK void ambiguity remains unchanged. Receipt-backed input uses the shared receipt-field contract
in the Host parser and SDK-side continuation check. Any
undeclared action receipt, including an unknown field or `dialog: null`, stops
before later input; a declared optional popup list without a dialog stays valid.
The contract data itself supplies no input-release authority. This one popup flow is
not general conditional execution or arbitrary multi-Page scripting. Source,
component SDK execution and installed MASC acceptance remain separate evidence.

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
are positive finite milliseconds and are forwarded unchanged. Omit either option
to retain its SDK default. The SDK owns polling and its deadline; the
executor-owned caller and native runner add no host reply-window limit.

This is an in-place SDK availability observation. It does not complete a login
handoff, reclaim a user-held Space, or clear uncertain input release. A handed-off
Space is refused before the wait; the existing explicit operator-confirmation
and same-Space `take_over` flow still applies. Subsequent commands recheck normal
ownership. Keeper activity names the Space wait separately.

## Dated Space metadata in MASC

`BrowserAct` with `action: "space_status"`, `lane: "live"` and the exact
observed `clientId` refreshes native metadata for the original numeric Space.
It uses `listTaskSpaces`, without constructing a TaskSpace, navigating a Page
or taking control. A missing Space is an error; no replacement is created.
The connection row retains the same client and attachment ID and publishes a
dated `spacePresence`: `present`, `missing`, or `unknown` with its observation
failure reason. A failed inventory query cannot establish absence. Automatic
browse selection excludes missing, unknown and unobserved Ego Spaces; an exact
client can still run `space_status` to refresh that same binding. A later native
inventory that contains the original ID restores its automatic eligibility.
Transport disconnection remains a separate condition. Reading connections uses
the cached presence and performs no native listing or Page call.
Presence describes the native inventory at its observation time; command
admission still checks the peer's ownership, input and completion state.

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

## A click the SDK refused before its press

**What.** `click`, `double_click` and selector `drag_to` resolve their target
before the first press. When the SDK cannot resolve it (several matches, no
match, hidden, disabled, covered by another element, a stale ref), it throws
`ElementResolutionError` with a declared `kind`, `transient` or `permanent`.
The peer reads that name and kind as data and judges them in
`Browser_ego_release`; the message text is not read. Such a gesture holds no
key or button, so the input keeps the readiness it had.

**What the caller sees.** The command still fails, with the SDK's message, an
uncertain effect (the SDK may have scrolled the target, and a double click may
have finished its first click) and two fields in the receipt:
`refusedBeforePress: {"kind": "permanent"}` (or `"transient"`) and
`inputReadiness`. A `permanent` refusal does not change by waiting; read the
page again and pick a narrower target, such as a snapshot ref. A `transient`
one may resolve once the page settles.

**What stays unconfirmed.** Any other error, a missing or malformed name or
kind, and `press` (its key goes out outside the SDK input tracking) leave the
input `release_uncertain`.

**Evidence.** The error class is `src/element-resolver.ts` lines 28-35 at
`citrolabs/ego-lite@12407167f84a`. On ego-browser 0.6.2.5 (Chromium 156,
2026-11-04) eleven refusals of these gestures each threw that error with a
`kind`, the page received no pointer or mouse event, and the next click worked.
The same probe saw `page.press` throw the same error, which is why `press`
stays out: the error alone cannot show its key was never sent.

## Input readiness is an observation

Every result object and failure an Ego connection returns carries
`inputReadiness`:

- `command_settled`: the last input-holding command ended with a release the
  SDK declared (a receipt without `dialog`, or a verified native typing tail),
  or no holding command ran yet on this connection.
- `release_uncertain`: the last holding command ended without that, for
  example after a dialog cut it or its answer was lost.

The value never refuses input. The next click, fill or key on the same Space is
admitted either way, and a new connection starts `command_settled`. A tab list
returned as a plain array and failures the server reports on its own (it
stopped waiting, the lane is absent) carry no value.

On ego-browser 0.6.2.5, dialogs that cut `click`, `dblclick`, `dragAndDrop`,
`press` and `keyboard.press` left no key or button down on the same Page or
another Page of the Space. A cut `keyboard.type` left the next press of the
interrupted key on that Page marked `repeat: true`; the typed value was right
and the flag cleared after that key went up once. RFC #48037 has the
measurements.
