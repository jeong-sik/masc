---
name: browser-ego
description: Observe and operate an ego lite task space through its snapshots, refs and native workflows.
---

For assigned Task work, first call `BrowserTabs {}` without `mode`, `lane` or
`clientId`. Automatic initial discovery consults the current Task's Goal binding
when present. Retain the returned `browserSelection.lane` and `clientId` for
subsequent calls, and preserve `browserGoal` when returned. `BrowserTabs`
`mode = "connections"` is global connection diagnostics; it does not select the
current Task's Goal. Never pick its first listed client as a substitute for
Task-aware discovery. An intentional advanced `lane`/`clientId` override selects
that browser instead of consulting the Task's Goal.

When the selected client's transport is `ego_task_space`, start with
`BrowserRead` `mode = "snapshot"` (`snapshotScope = "viewport"`, the default),
and reuse its refs or observed Ego locators for input. Ego owns locator
resolution, actionability, automatic scrolling and frame/shadow traversal; do
not resolve a native target to coordinates or add a separate selector wait.
After page changes or a stale ref, read a fresh snapshot on the same page.

Use native `fill` on an observed input, textarea or contenteditable editor to
replace its contents. For literal insertion at an already observed/focused
editor, explicitly choose `keyboard.insertText`; it creates no key-down/up
state. Use `keyboard.paste` when native paste semantics or text/HTML are wanted.
These are different actions: select the intended one rather than silently
substituting for an input that already ran.

For actions already determined from that observation, use one `BrowserInteract`
`action = "workflow"` with `tabId`, initial `expectedUrl` and `steps`. Each step
names a native `method` such as `fill`, `click`, `waitForURL` or
`waitForSelector`, with that method's fields. The SDK executes the known
sequence and returns one final snapshot. Split the call when intermediate
results require a new decision. Retain `completed` progress on failure and
never replay the sequence after uncertain effects.

Use `type_text` with the observed `documentId` and `expectedUrl` to type at the
current enabled editable focus, or use workflow `keyboard.type` after an
observed focus. Both call native typing once. The SDK return stays void;
MASC independently verifies that the same command reached the native typing
tail and reports `nativeCompletion` separately. This is command completion,
not proof that the application accepted the text or that external input is fresh.
Read the resulting field or editor before deciding what to do next.

If that native window is interrupted or unconfirmed, MASC stops before the next
workflow step and reports `release_uncertain`. The typing's effect is unknown,
so running the typing or workflow again can repeat it.
A proven refusal before typing can restore the previous input readiness without
claiming that observation setup had no effects. Typing consumes the native Page
event buffer for its completion check; a later `events` result is not a full
history.

A `drag_to` from one selector onto another uses the SDK's `dragAndDrop`, which
returns a receipt. Its no-dialog receipt settles the command, while
application drop acceptance still requires observation.

Uploads use `BrowserAct` `action = "upload"` on the live ego connection
(`lane = "live"` with its observed `clientId`) and the observed `tabId`. The
host must first authorize and snapshot the requested files through the
Keeper's file-read context. A raw path is not that authority. Never invent an
`uploadId` or reuse a grant from another call.

For Ego downloads, read `page.downloads` with the observed live client and tab
ID, or use BrowserRead with `mode = "downloads"`. Read completed files only when
their row contains a finalized artifact; invoke its returned
`keeper_artifact_read` reader and arguments. Completion without that reference
does not prove that bytes were retained. Pending or failed downloads are not
completed artifacts; worker paths are not file-read grants.

An Ego workflow `fetch` step can set `options.saveAs` to an artifact filename
such as `report.pdf`, without a directory or control characters. Ego performs
the browser-context fetch and binary save to a fresh private path. The step
receipt returns `source: "fetch"`, `downloadId` and the requested
`suggestedFilename`; it exposes no saved host path. Retrieve that ID through
the same connection/tab's download reader and use only its finalized artifact.
A saved HTTP error response still has `ok: false`; inspect the HTTP status.
If a later step or final snapshot fails, an already completed save remains in
that SDK process's download inventory. Read it without repeating fetch.
An interrupted save has no completed artifact. Registry recovery after SDK
process/worker replacement is not implemented; retained files alone are not
proof of completion or permission to adopt them.

To inspect who owns the already bound Ego Space, send `page.act` with
`{"action":"space_status"}` on that exact live client. It reads native Space
metadata only, even when delegated to the operator, without Page calls, claim
or takeover. The receipt carries current SDK name/ownership and `observedAt`;
these observations do not establish permission or login success.
Control-changing calls and failed refreshes invalidate the cached observation.

After the operator explicitly completes a handed-off step, `take_over` on the
same client returns the native user-boundary Page as `activeTabId`/`egoPage`.
It can be unmanaged (`label:null`); explicitly `adopt_tab` the observed ID
before reading it. Takeover does not adopt, read a document, clear uncertain
input or prove login/current focus. An absent boundary Page stays absent.
A changed or lost boundary result does not authorize another active tab,
another Space or automatic takeover replay. Confirm login with a fresh read
of the intended managed Page. Explicit input/navigation/activation can
then use an adopted native Page without changing its origin.

Ego tab inventory uses native `task.tabs()` without waiting for Page info.
`dialogObservation = "unobserved"` means the inventory does not establish whether
an alert or prompt is open. To request dialog metadata explicitly, use
`BrowserRead mode = "dialog"` on the same live client and observed `tabId`.
This native read can be unavailable after SDK-session replacement;
its failure does not invalidate the inventory. An observed dialog in an input
receipt remains useful. `accept_dialog` and `dismiss_dialog` bind the same native
managed Page and call its boolean method directly without first reading info;
`answered = true` does not certify input release or identify unobserved dialog text.
Never repeat an uncertain answer or infer a clean key/button state from it.

Every result object and failure the Ego connection answers carries
`inputReadiness`: `command_settled`, or `release_uncertain` when the last
input-holding command ended without the SDK declaring its release (a dialog cut
it, or its answer was lost). The next input runs either way. After a
`release_uncertain` typing, the next press of the interrupted key on that Page
may arrive marked as a key repeat; the text it types is unchanged. The original
command's effect is unknown, so running it again can repeat it; reading the
page shows what happened. Answering a JavaScript dialog is a separate step. A
tab list that comes back as a plain array carries nothing, and neither does a
failure the server reports on its own (for example when it stopped waiting for
the connection).
A click, double click or drag whose target the SDK could not resolve fails with
`refusedBeforePress: {"kind": ...}` and keeps `inputReadiness` as it was: no
key or button is left down. A double click may have finished its first click
before the refusal. `permanent` means the target as written will not resolve;
`transient` means it may once the page settles.

When Ego reports `EGO_PAGE_UNRESPONSIVE` because navigation has not committed,
use `BrowserAct` `action = "stop_loading"` on the same observed live client and
managed `tabId`. This invokes native `page.cdp("Page.stopLoading")` without
first calling Page URL, info or snapshot; it therefore does not require the
blocked observation to succeed. The receipt acknowledges native command return
on the identified Page, not a loaded document or input release. Read that same
Page afresh before deciding what to do next. Do not replay lost recovery calls,
create another Space, clear unknown key/button state, or infer login success.
