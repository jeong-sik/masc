# Ego native-first integration audit

Ego owns browser interpretation and execution. MASC uses its existing browser
broker to cross the Keeper sandbox/host boundary and preserve scoped identity,
authorization, cancellation and receipts. Keeper code cannot supply Node source.
This change adds a closed native Page sequence to that broker, not another
composition engine or locator implementation.

## Requirement audit

| Required outcome | Implementation and evidence |
|---|---|
| Native snapshot/ref by default on Ego | Both browser-lanes and the actual Add-on browser Skill teach native snapshot/ref. The raw advertised schema includes `page.snapshot`. Real Keeper BrowserRead requests and resulting snapshots are recorded below. |
| Native selector input and SDK waits | Selector/ref click, fill, hover, double-click and selectOption reach native Page methods without DOM-to-coordinate resolution or custom input. [SDK evidence](../ego-native-sdk/) covers scroll, iframe, shadow and selection behavior. |
| One known sequence, SDK conditions, final snapshot | BrowserInteract workflow uses the existing broker, typed codec and executor cancellation. [Workflow evidence](../ego-native-workflow/) binds production JS, codec tests and real SDK runs. The viewport scope defect found by a real Keeper is retained with its repair evidence. |
| Keep only justified input/file adapters | [Transfer audit](../ego-native-transfers/) records native upload and drag; MASC retains sandbox grants/staging, delayed file lifetime and release-uncertain handling. Scene/coordinate/custom-waypoint semantics have no equivalent SDK action. Document-window scrolling and direct-href navigation retain their different contracts. |
| Preserve actual remaining SDK gaps | [Installed .20 process-state experiment](../ego-native-session-gap/) justifies the shared SDK session for dialogs. Native download handles/events plus durable publication justify download integration; temp-file deletion is not assumed. |
| Verify host and real Keeper, separately from fixtures | Exact-source candidate identities, real provider goals/tool records, persisted application state and the actual Keeper screenshot are recorded per candidate below. SDK-only evidence is identified separately. |

## Original candidate: 4219c307

CI run [40075616342](https://github.com/jeong-sik/masc/actions/runs/40075616342)
built server, browser worker and native launcher at
`4219c3074e281940ffec9c0d0b12db6f04a0d296`. All three downloaded hashes and local
dynamic dependencies were verified. Full health identified the running server
and its private state root. This was an isolated candidate, not a production
installation or release.

A real `glm-coding.glm-5.3-flash` Keeper received a form goal and input values,
without selectors, refs, tool arguments or scripted model replies. It used
native snapshots, ref inputs, native single/multiple selection and one submit
click. Independent application state contained exactly one matching submission;
the completion page and the actual Keeper screenshot show `EGO-001`.

[Original-candidate artifacts](original-candidate/) contain the plain goals,
identity, application source/state/HTTP log, visible chat, actual screenshot
and tool records. `tool-trajectory.json` covers all 34 tool calls but the
producer abbreviates some results. `retained-raw-tool-records.json` carries
25 retained tool completions, with full browser results from raw turn logs; it does
not reconstruct missing earlier raw turns. Non-browser success bodies are
represented by hashes/lengths; hidden reasoning and credentials are omitted.

The run was not clean. A headless-session request and missing client binding
were refused. A label sent as an exact option value failed and was corrected
after observation. The first operation was interrupted when the original
space 4 was found missing; the operator explicitly approved continuing in 9.
The candidate's first startup also inherited a Discord token and connected;
it was stopped, with no message handling/sending recorded, and subsequent
startup passed only required environment variables. The private fixture Keeper
wrote its own local notes; they were not promoted into production or candidate 2.

Screenshot persistence succeeded. Keeper image interpretation failed because
the isolated configuration had no image-capable runtime. The image was instead
retrieved from the private Keeper vision store, hash-checked and visually
inspected by the reviewing agent. A generic tool-blob HTTP endpoint does not
serve that distinct vision store.

The same Keeper's extra workflow check exposed invalid forwarding of MASC's
`viewport` scope. It recovered with `full_page`, completing two native waits
and a final snapshot. Complete receipts and exact-source identity are in
[keeper-original-host.json](../ego-native-workflow/viewport/keeper-original-host.json).
That workaround does not prove the repaired viewport host path.

## Repaired candidate: 7ee0dd6e

Source `7ee0dd6e13086c9faaab9d63b6b13bd901aa4da1` maps viewport to the native
default snapshot call, just like ordinary BrowserRead. Nineteen production JS
tests and five codec/receipt component tests passed. Fixed production JS also
passed real viewport and five-step full-page SDK checks; see the workflow proof.
Independent source reviews found no remaining P1/P2 in the repair and restack.

Selected seven-suite run:
[40077677283](https://github.com/jeong-sik/masc/actions/runs/40077677283).
It completed successfully: 74 tests across native workflow (5), browser lane
(14), wire/schema validation (6), Ego peer (31), client (1), live BiDi (6) and
live Ego host integration (11). [selected-ci.json](selected-ci.json) binds the
source/run/counts. This is the selected set, not the full regression suite.
Exact-source macOS candidate run:
[40077681846](https://github.com/jeong-sik/masc/actions/runs/40077681846).
It completed successfully. All three downloaded executable hashes and local
dynamic dependencies were verified. The candidate server and Browser Add-on
started in another private workspace, and full health reported binary source
`7ee0dd6e` with the expected effective root. The review head had only docs
changes after that source; [repaired-candidate](repaired-candidate/) retains
the exact identities and delta.

The first real Keeper attempt reused space 9 and the existing tab, navigated
to a fresh owned fixture and observed its form/options. The provider then
repeatedly timed out before its first token. On subsequent recovery the SDK
reported space 9 missing; a direct independent SDK read confirmed that state.
The cause of space loss is unproven. At the end of that attempt the new fixture
had no submission and the Keeper was stopped. The failed attempt is retained.
The operator then authorized replacement spaces when needed for this goal.

The retry used the reconnected space 14 and its existing p1 tab. A real-provider
Keeper observed the form and native option values, then executed two native
workflows: fill name / select shipping / select email+sms, followed after
observing the conditional address field by fill address / click submit. The
first returned a full-page snapshot; the second returned the repaired viewport
snapshot at `/confirmation` with `EGO-001`. Both raw receipts contain every
requested completed step, `effectStarted=true`, `completedEffect=true` and
`failure=null`. [keeper-native-workflows.json](repaired-candidate/keeper-native-workflows.json)
retains the original tool arguments/results, not scripted model responses.

The real request reached `Succeeded`; independent fixture state and the HTTP
log show exactly one matching submission. An independent SDK screenshot of
the same final page was visually inspected; it is a reviewer capture, not a
Keeper-produced image. See [outcome.json](repaired-candidate/outcome.json),
[operation-result.json](repaired-candidate/operation-result.json) and the
retained raw tool records/visible chat. The private Keeper Task verifier was
unavailable because this isolated configuration has no published exact-output
registry. Browser completion is established by the actual request/receipts,
persisted application state and rendered page, not by Task verifier approval.

## Scope and lifecycle

All application URLs and input values belong to private local fixtures.
Connector credentials are excluded from the final launcher environment.
Keeper goals use real model inference; recorded tool errors are retained.
No local Dune build, full regression, production binary replacement or release
verification is claimed.

The idle original host was stopped only after Keeper shutdown finalized,
queued operations were empty and browser host requests had no waiters.
Normal host cleanup would finish the task space, so its private idle process
tree was stopped while preserving approved Ego space 9 for candidate replacement.
Space 9 remained agent-owned with the same p1/p2 pages at that boundary, then
was later found missing as recorded above. The final space 14 was ended through
the normal explicit Browser Add-on detach path after Keeper shutdown finalized
and queued operations were empty. Detach returned `native_released`; worker
and SDK PIDs were absent and a direct lookup confirmed space 14 no longer
existed. No manual SDK signal was needed for that final retirement.

## Existing shutdown observation

Stopping the earlier private repaired-candidate host with SIGINT left its SDK
child orphaned after the server and worker exited. The verified owned SDK
process was manually terminated. Source inspection places the same teardown
structure before this stack (commit `965d3120780`); nested worker/SDK shutdown
graces provide a plausible race, not a proven cause. Neither that observation
nor the successful final explicit retirement establishes the cause of space
loss or provider timeouts. [shutdown-observation.json](repaired-candidate/shutdown-observation.json)
and [final-cleanup.json](repaired-candidate/final-cleanup.json) preserve the
different outcomes. No fix of that pre-existing host-shutdown path is claimed.
