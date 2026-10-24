# Native-first goal completion audit

Objective: use Ego Lite itself wherever its installed APIs support the required
behavior; MASC supplements actual integration gaps. This audit covers the source
implementation, reviewable Native Stack45822 and isolated real Keeper/browser
validation. The user requested PR delivery; production merge, installation and
release are separate actions and have not been performed.

## Source and execution identities

Current runtime source is `12c001e55e27c7a9340ae27f956e112fd5360c76`.
Subsequent commits change only documentation/evidence. Its focused run
[40112787489](https://github.com/jeong-sik/masc/actions/runs/40112787489)
compiled the selected targets and passed19 tests: actual client4, reply policy1,
lane14. Its [macOS candidate build40113070920](https://github.com/jeong-sik/masc/actions/runs/40113070920)
succeeded, and the downloaded three-binary receipt was verified before execution.
[Actual12c Keeper evidence](../ego-sdk-owner-disconnect/keeper-12c001e5/)
separately binds server/worker hashes, embedded source, effective private root,
actual provider run, browser receipts, persisted result and rendered screenshot.

Earlier evidence retains its own identity:14c9 proves the real form and130.14s
original native-workflow call; a96 proves ordinary navigation at that source;
34c proves the compiled owner-loss repair. They are not represented as execution
of12c. Full regression was not run for this candidate; selected results do not
replace release verification or establish every browser feature.

## Requirements and authoritative evidence

| Requirement | Inspected source and evidence | Assessment |
|---|---|---|
| Ego interprets ordinary DOM targets | Both browser Skills advertise native snapshot/ref; current peer forwards selector/ref methods to native Page APIs; actual12c snapshots expose ref1 and the real Keeper clicks that ref | Satisfied |
| Reuse Ego interpretation across iframe/shadow/selection | Existing [native SDK evidence](../ego-native-sdk/) and [integration audit](../ego-native-integration/) cover installed APIs; current peer retains direct native targets rather than another DOM locator/interpreter | Satisfied for the documented implemented surface |
| Known sequences use SDK conditions and one final snapshot | Closed workflow codec/broker, production JS, [workflow evidence](../ego-native-workflow/) and real Keeper workflows in the original/repaired integration audit; no Keeper-supplied Node source | Satisfied |
| Remove duplicate sequence/execution budgets | Bottom layer removes step count, cumulative/per-step MASC clocks and Promise.race; explicit SDK options forwarded unchanged and omitted defaults left to SDK;20-step real SDK result, codec cases and retained JS tests in [wait repair](../ego-native-sdk-waits/) | Satisfied |
| Native input/navigation execution belongs to Ego | Current native_runner and actual transport policy; actual client socket tests cross the transport timer for click/goto/reload/open-tab; current Keeper exercises ordinary goto/reload/ref-click through the real host | Satisfied; short current run is not a new130s result |
| Shared client must not export Ego wait policy to other routes | Original-worker validated Snapshot selects exact transport; missing differing-policy metadata refuses before writing; owned/WebExtension/BiDi silent peers remain bounded in actual socket tests | Satisfied; no new live Firefox execution claim |
| Concurrent metadata cannot revive stale transports | Latest physical Snapshot token, full replacement, failure/start clearing and revoke invalidation; controlled two-snapshot tests exercise both reply orders, failures and replacements | Satisfied by current-source compiled socket tests |
| Long work retains its original caller/connection | Running ownership tied to admitted take with original waiter; queue/cancel/disconnect/late-result tests and earlier14c9 single130.14s native call completed2/failure:null | Satisfied with explicit earlier-source timing scope |
| Delegate supported transfer behavior, preserve required host gap | Native upload/chooser/drag/download APIs; [transfer audit](../ego-native-transfers/) preserves sandbox grants/staging, file lifetime and durable artifact publication. Actual SDK failed-assignment then successful next chooser justifies removing duplicate setFiles cleanup | Satisfied |
| Retain a shared SDK session only for a real gap | Installed0.6.0.20 [session-state experiment](../ego-native-session-gap/) shows process-local dialog state; process/receipt/file boundaries are distinct from a browser interpreter | Satisfied |
| Adapter semantics remain honest | Scene/coordinate/custom-waypoint, direct-href/referrer and CDP history paths retain contracts without documented equivalent native Page methods; current source audit found no material native locator/actionability or aggregate execution middleware duplicate | Satisfied within inspected installed API surface |
| Lost owner cannot leave buffered SDK work running | Idempotent IPC end/close/error exit; installed evaluator before/fixed5-case proof, plus compiled34c worker kill and server SIGTERM; actual12c normal shutdown also leaves no SDK child | Satisfied; requires responsive Node loop and cannot undo dispatched effects |
| Real Keeper proves the latest client integration | Actualglm operation on12c Succeeded;9 tools include ordinary goto/reload/native ref1 click/final snapshot, same client/tab and30/p1; one predispatch missing-identity read and model recovery retained | Satisfied |
| Persisted result agrees with visible browser | One fixture confirmation in [12c result](../ego-sdk-owner-disconnect/keeper-12c001e5/outcome.json); native snapshot/title and independently captured/visually inspected PNG agree | Satisfied; no existing form replay |
| Reviewable delivery and cleanup | Four ready open native-stack PRs45812/45821/45830/45841; independent full-source/evidence reviews and scoped CI receipts. Matched12c server/worker/SDK/fixture PIDs absent and space30 absent after normal shutdown | Satisfied; source review is not formal GitHub approval or merge |

## Final limitations and conclusion

No required implementation or isolated verification remains open for this
native-first goal. MASC retains browser selection/authorization, sandbox and
artifact transfers, receipts, cancellation, process ownership and adapters with
distinct semantics. It does not add another planner or locator interpreter.

This conclusion does not certify universal SDK/API coverage, every existing
protocol window, synchronous-CPU interruption, full regression, production fleet
behavior, GitHub merge approval, deployment or release. Those claims require
their own scope and evidence. Already-dispatched uncertain effects remain
unknown and are not automatically replayed.
