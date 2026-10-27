# Ego SDK coverage and remaining work

This inventory compares all **74 entries** printed by the installed
`ego-browser nodejs -e 'help()'` on 2026-10-26 with the MASC Ego adapter and
native workflow. Entries include properties and returned handles, not just
independent operations. Source integration, SDK execution, installed MASC and
actual Keeper/UI behavior are separate evidence layers.

The installed `ego-browser skill` guide is v2.1.0; the live browser reports Ego
0.6.1.11. The
[harness developer guide](https://lite.ego.app/document/en/docs/custom-agent-harness),
[browser API introduction](https://lite.ego.app/document/en/docs/ego-browser),
[Space guide](https://lite.ego.app/document/en/docs/space) and
[snapshot guide](https://lite.ego.app/document/en/docs/snapshot) explain the intended
model. The public examples currently use older global helpers and seconds; the
installed guide uses TaskSpace/Page handles and milliseconds. Do not copy old
examples into the current adapter or invent Playwright methods.

The source entrypoints are
[`browser_ego_peer.ml`](../../lib/browser_ego_peer.ml),
[`browser_ego_workflow.ml`](../../lib/browser_ego_workflow.ml),
[`browser_native_workflow.mli`](../../lib/browser_lane/browser_native_workflow.mli),
and the actual
[`masc_browser_interact` schema](../../config/tools/masc_browser_interact.toml).
“Internal” below means the adapter uses an API but does not offer its full public
contract to a Keeper. “Partial” includes missing SDK options and lifecycle choices.
Neither means fully supported.

## Spaces and handles

| SDK entry | Current MASC integration | Remaining boundary |
| --- | --- | --- |
| `profiles` | None | Profile selection only after explicit user request; no general profile inspection |
| `listTaskSpaces` | None in Keeper tools | Discover existing goal Spaces without creating replacements |
| `taskSpace` | Configured name on open; numeric id in every round | One configured Space is shared by Keepers; per-goal binding and resume are missing |
| `claimTaskSpace` | None | Explicit approval and user-owned Space admission |
| `takeOverTaskSpace` | `page.act` take_over | Explicit operator control boundary, currently only configured Space |
| `TaskSpace.spaceId` | Internal connection identity | Expose goal/Space provenance in tool and UI observations |
| `TaskSpace.name` | Configured name | Per-goal lifecycle and visible identity |
| `TaskSpace.ownership` | Checked before scripts and handoff | Current ownership projection in Keeper and UI observations |
| `TaskSpace.page` | Internal permanent label resolution | Expose durable Page label with numbered tab provenance |
| `TaskSpace.userPage` | None | Claim/takeover boundary attribution and explicit adoption |
| `TaskSpace.pages` | Managed pages known through tab enumeration | Direct lifecycle-aware managed inventory |
| `TaskSpace.tabs` | `tabs.list` | Goal/Space ownership and unmanaged-tab provenance in public DTO |
| `TaskSpace.newPage` | `page.act` open_tab | Per-goal Space and returned permanent label |
| `TaskSpace.adopt` | None; unmanaged pages refused | Explicitly authorized adoption with conservative ownership |
| `TaskSpace.release` | None | Return an unknown-origin managed page without closing it |
| `TaskSpace.waitForControl` | None | SDK wait without taking control away from the operator |
| `TaskSpace.handOff` | `page.act` hand_off | Per-goal scope and UI control-state projection |
| `TaskSpace.finish` | Internal connection teardown uses `keep:[]` | Goal completion with explicit keep policy and retained-page receipt |
| `TaskSpace.cdp` | None | Explicit Target/Browser protocol boundary and lifecycle reconciliation |
| `Page.label` | Internal permanent labels | Tool/UI provenance and resume identity |
| `Page.spaceId` | Space known internally | Tool/UI provenance |
| `Page.openedBy` | Conservatively checked for closure | Preserve origin attribution through public inventory and lifecycle tools |
| `Page.targetId` | Unmanaged-tab identification only | Advanced Target protocol provenance; never use as durable Page identity |

## Page operations

| SDK entry | Current MASC integration | Remaining boundary |
| --- | --- | --- |
| `Page.goto` | `page.goto`, native workflow goto | Native referer/waitUntil options |
| `Page.reload` | `page.act` reload, native workflow reload | Native waitUntil option |
| `Page.snapshot` | BrowserRead snapshot and final workflow snapshot | Subtree/root and action-mark/stable-locator choices in workflows |
| `Page.screenshot` | `page.capture` with brokered image data | Full-page, clip, scale/raw choices |
| `Page.url` | Internal guards and returned page observations | Direct SDK state result within a workflow |
| `Page.waitForURL` | Native workflow waitForURL | String/glob supported; RegExp and function matchers not exposed |
| `Page.waitForEvent` | Internal download watch | General event waits and typed handle lifecycle |
| `Page.waitForTimeout` | None | Explicit native duration, without using fixed sleeps as state verification |
| `Page.title` | Internal observations and workflow result | Direct SDK state result within a workflow |
| `Page.info` | Internal viewport/dialog checks | Full native state as a returned workflow observation |
| `Page.acceptDialog` | `page.act` accept_dialog | Native boolean receipt and per-goal ownership evidence |
| `Page.dismissDialog` | `page.act` dismiss_dialog | Native boolean receipt and per-goal ownership evidence |
| `Page.evaluate` | Native workflow evaluate, browser expression/call with JSON | Safety-timeout metadata beyond message not retained; installed MASC/Keeper route unverified |
| `Page.waitForFunction` | Native workflow waitForFunction with JSON and timeout/polling | Predicates count as possible effects; installed MASC/Keeper route unverified |
| `Page.fetch` | Native workflow fetch with browser options and structured response | `saveAs` requires broker integration; installed MASC/Keeper route unverified |
| `Page.cdp` | Fixed internal history commands only | General Page protocol calls with explicit effect and lifecycle handling |
| `Page.waitForSelector` | Native workflow waitForSelector | Native states and timeout exposed; installed MASC route unverified |
| `Page.waitForLoadState` | Native workflow waitForLoadState | Native idleMs option |
| `Page.events` | None | Read/clear event ownership across rounds |
| `Page.click` | Selector/ref interaction and native workflow | Native button/clickCount/delay/position/force choices in workflows |
| `Page.dblclick` | Selector/ref interaction and native workflow | Native button/delay/position/force choices in workflows |
| `Page.hover` | Selector/ref interaction and native workflow | Native position/force choices in workflows |
| `Page.dragAndDrop` | `drag_to` native selector/ref input | Native button/sourcePosition/targetPosition/force/timeout choices in workflows |
| `Page.fill` | Selector/ref interaction and native workflow | Native clearFirst choice |
| `Page.selectOption` | Value and distinct-value arrays | Label/index/null selection forms |
| `Page.focus` | Native workflow focus | Real SDK primitive proof; installed MASC/Keeper route unverified |
| `Page.press` | Native workflow press | Native delay option |
| `Page.setInputFiles` | `page.act` upload through staged leases | Direct workflow integration while preserving file broker/lease boundary |
| `Page.waitForFileChooser` | Internal chooser-opener upload | Explicit chooser wait/handle/options in native workflows |
| `Page.close` | `page.act` close_tab, agent-origin only | Unknown-origin release workflow and goal/Space lifecycle |

## Input and returned handles

| SDK entry | Current MASC integration | Remaining boundary |
| --- | --- | --- |
| `Page.mouse.click` | Trusted coordinate click/double click | Native delay and general clickCount choices |
| `Page.mouse.move` | Hover and path drag internals | Native steps choice and direct workflow operation |
| `Page.mouse.down` | Balanced drag implementation only | Held-button state, cancellation and release settlement across workflow steps |
| `Page.mouse.up` | Balanced drag implementation and cleanup | Explicit release receipt and uncertain-pointer recovery |
| `Page.mouse.wheel` | Scroll at observed point | Direct native workflow operation with pointer provenance |
| `Page.keyboard.down` | None | Held-key state and cancellation/release settlement |
| `Page.keyboard.up` | None | Explicit release and uncertain-key recovery |
| `Page.keyboard.press` | Interaction chord and native workflow | Native delay choice |
| `Page.keyboard.type` | Trusted text interaction and native workflow | Native delay choice |
| `Page.keyboard.insertText` | Native workflow | Real SDK primitive proof; installed MASC/Keeper route unverified |
| `Page.keyboard.paste` | Native workflow plain/rich paste | Real trusted paste proof; installed MASC/Keeper route unverified |
| `FileChooser.isMultiple` | Internal chooser validation | Explicit chooser handle observation |
| `FileChooser.setFiles` | Internal upload with staged copies/leases | Explicit handle lifecycle and timeout options |
| `Download.page` | No native call; registry stores the triggering Page label | Returned handle provenance in workflow receipts |
| `Download.url` | Internal download registry | Direct handle observation |
| `Download.suggestedFilename` | Internal download registry | Direct handle observation |
| `Download.saveAs` | Internal UUID path then download broker | Explicit brokered save operation; no arbitrary host path |
| `Download.path` | None | Round-local path lifetime with broker output |
| `Download.failure` | Internal completion/interrupt observation | Explicit handle operation |
| `Download.cancel` | None | Download cancellation and resulting receipt |
| `Download.delete` | Internal temporary-file cleanup after save | Explicit deletion of only that handle's temporary files |

## Current evidence and next work

The rich-input and Page-code probes run the production workflow JavaScript in an
owned real Ego Space against local fixtures. They exercise native input, browser
code and JSON separation, app-state wait, browser POST exactly once, CORS failure,
timeout and stop-before-following-step behavior. The actual OCaml codec decodes
the captured receipt against its exact request. These are not installed Keeper or
visible MASC TUI proof.

The first probe Space (24) disappeared externally. After explicit user approval,
the same ongoing Goal resumed validation in replacement Space **27**. No existing
operator or Keeper Space was adopted. The replacement is still open; finishing
it now would falsely imply this whole Goal is complete.

MASC source now tracks reads, waits within workflows and navigation alongside
input, and retains caller-specific last results. Native Ego cursor labels cover
pointer actions. Native Ego read/wait visibility remains a gap: extra synchronous
pre/post CLI calls were rejected because they can delay command execution and
receipt delivery.

The Goal remains incomplete while any required SDK, Space, selection, recovery,
installed Keeper or actual UI evidence is missing. See
[`tui-browser-lanes.md`](tui-browser-lanes.md) for the current product flow.
