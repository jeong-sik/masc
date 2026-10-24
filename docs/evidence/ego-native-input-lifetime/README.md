# Native Ego input owns its execution lifetime

The [workflow wait repair](../ego-native-sdk-waits/) removed newly introduced
execution caps. Ordinary selector/ref input still used `run_step` and the
generic `Reply_window`. That was an execution limit: `Watched_work` cancels its
loser, the lane removes its waiter, and the peer can stop its SDK process.
A late result then has no original caller to settle. It was not harmless
observation or durable background execution.

Native selector/ref click, fill, hover, double-click, selection and plain
selector-to-selector drag now use the native session runner. The lane chooses
the execution policy from its authenticated client's actual transport and the
closed interaction type. Other browsers and scene/coordinate/custom-waypoint
adapters retain their existing worker-side policy. The private Add-on client
selects its wait policy from the original worker's validated snapshot: an
opaque live UUID alone does not authorize Ego-only waiting. Only an exact Ego
transport observation removes the additional execution clock. Automation,
Stagehand, WebExtension and BiDi retain their shared reply windows. Missing
transport metadata refuses differing-policy calls before dispatch. The worker
still owns browser admission and validates its actual transport.

A new snapshot clears the previous transport observation. Only the latest
snapshot may publish metadata, so overlapping replies cannot restore stale
entries after replacement, failure or revocation. Socket tests exercise actual
writes, silent peers, SDK-owned waiting and controlled overlapping snapshots.
The full-stack12c focused run40112787489 passes all19 selected tests, including
four actual client cases. Parsing and independent source review are separate
evidence. [Actual12c Keeper evidence](../ego-sdk-owner-disconnect/keeper-12c001e5/)
now binds ordinary native navigation/ref-input success and recovery to the new
metadata path; it does not claim another long-duration result.

The independent audit also found a poll-lifetime boundary. Ego polls between
SDK commands. A legitimate long command could outlive the idle 120-second
connection lease. The lane now records queued/running ownership per original
executor-owned request. Only a take with its original waiter still present
marks it running. Running work retains that connection; queued work cannot
hold a lost client alive. Delivery removes ownership and renews the idle lease.
Cancellation and explicit disconnect release ownership; a retired ID and late
result cannot revive the connection. State reads and mutations use the same
client mutex, preserving global-to-client lock order.

The current base's selection and host admission matches also omitted `Page_native_workflow`
after a separate host-selection refactor. This layer restores those closed
cases so native workflows pass through the selected host path.

The preceding candidate `ae5c0a5f83236ac592e332bfaec2d06313faf305`
failed selected CI [40102778277](https://github.com/jeong-sik/masc/actions/runs/40102778277)
and macOS runtime build [40102780562](https://github.com/jeong-sik/masc/actions/runs/40102780562)
on those missing cases (warning 8), before tests ran or candidate binaries were
available. These are retained failures, not successful validation of this layer.

## Component evidence and limits

`python3 scripts/check-browser-native-lifetime-component.py` compiles the
actual lane, its helper modules and the actual mock-clock test with warnings
as errors. Eight tests pass, including long-running ownership after explicit
Mtime lease expiry, idle expiry after settlement, queued expiry, caller
cancellation, explicit running disconnect, original-caller failure, stale
delivery/ID rejection, and unchanged other-browser/guarded-input policy.
Three existing boundary-arrival scenarios remain in that count.

The test sets an actual `Monotonic_deadline` to an expired value; moving the
mock Eio clock alone does not advance Mtime. It does not spend 120 seconds in
a real browser. The upload-lease module is an unused alias stub in this
standalone component. This is not upload integration or a complete host type
check. [component-results.txt](component-results.txt) retains the result.

The production JavaScript input/workflow/drag/upload tests also pass: 22
scenarios, preserving native dispatch, uncertain failures and no replay.
Changed host/peer/client sources parse and diff-check passes. Independent
source review identified and corrected one obsolete private call argument and
the client-state locking issue. These are not CI or installed-runtime claims.

Installed Ego 0.6.0.20 was observed on continuing space20/p1: a missing native
click target timed out in its SDK after 3,053ms with the SDK's own 3,000ms
message. That common-case result does not justify the former MASC 20-second
execution limit or prove a long action. The earlier real SDK and Keeper runs
remain bound to their own exact sources. Combined host/Keeper verification of
this layer is still required; no production installation is changed here.

## Chooser ownership correction

Selected CI [40105102108](https://github.com/jeong-sik/masc/actions/runs/40105102108)
compiled candidate `fad55fd7c77d1ae55f7cd1d064d0908892fced2a`, then failed
peer case 28: a second `setFiles([])` was attempted after the SDK had handled
a failed assignment. The separate macOS runtime build
[40105104432](https://github.com/jeong-sik/masc/actions/runs/40105104432)
succeeded for that source; it does not include this correction.

The second call came from `f12386db1d8` after the earlier live verification.
Its new mock assumed failed SDK assignment left the chooser pending. Real Ego
0.6.0.20 contradicts that assumption: [round 03](chooser-recheck/round-03-output.txt)
executes the extracted production chooser body, deliberately changes the owned
input to text just before assignment, receives the native error, then completes
the next chooser in the same process. Only the two requested assignments occur;
no empty assignment is sent. MASC now closes only a captured chooser that it
has not handed to `setFiles`, retaining uncertainty and no replay after failure.
The JavaScript mock now represents this observed SDK lifecycle; existing OCaml
case 28 already asserts it. Independent delta source review found no P0-P2.

Space 20 was confirmed missing; the operator's existing replacement permission
was used to create continuing space 25/p1. The first two recheck rounds failed
before file assignment because of invalid/inapplicable semantic locators; their
logs are preserved. Round 03 inspected the input DOM and used its observed CSS
selector. This proves production JavaScript with the installed SDK, not full
host/Keeper integration. The local fixture server ended after each round.

## Current selected CI

[40106834542](https://github.com/jeong-sik/masc/actions/runs/40106834542)
completed successfully for `14c9f0c701768ed3242e3fcde219b3dfaf9a80ce`.
[The receipt](selected-ci.json) records all eight selected suites: native workflow
5, Ego peer 31, live Ego integration 11, lane 14, Add-on client 1, watched work 8,
selection 9 and reply policy 1 (80 tests total). This includes the formerly
failing handled-chooser assertion. It is not a full regression run.

The three SDK output files retain their payloads with only trailing blank EOF
lines removed in this evidence follow-up. No runtime source changed after the
candidate SHA above. The macOS candidate build and real Keeper proof remain
separate evidence.

## Real Keeper candidate 14c9

Exact macOS build [40106836825](https://github.com/jeong-sik/masc/actions/runs/40106836825)
succeeded for `14c9f0c701768ed3242e3fcde219b3dfaf9a80ce`. All three downloaded
binary hashes, dynamic dependencies and embedded source were checked; full
health independently verified the running executable hash/path and isolated
state root. [Candidate artifacts](keeper-14c9f0c7/) retain the receipts.

A real glm-coding.glm-5.3-flash Keeper observed the UI, filled the requested
name, conditional shipping address and email+SMS selection, and submitted once.
The operation succeeded, with exactly one matching EGO-001 persisted. Server
processing took 130.01s. The post-submit networkidle native workflow returned
its final completion snapshot through the original call after 81.93s, beyond
the former 20-second execution window. It does not prove a single call longer
than the idle 120-second connection lease: the first post-submit hidden-address
condition finished immediately and the later networkidle call began 49s after
submission. Those calls and the initial missing-clientId refusal are retained.

The root reviewer took and visually inspected the completion screenshot after
the Keeper's operation succeeded; this is not described as a Keeper image-tool
capture. Provider reasoning and bearer credentials are not copied into the
artifacts. Keeper shutdown was accepted after the form goal, then the same
Keeper and space25/p1 were resumed for a separate marker lifetime test. Final
connection/server cleanup was still pending at that observation; its final
result is recorded below. This candidate predates the native
navigation layer and is not evidence that its new binary ran.

The separate marker operation also succeeded on the same candidate and25/p1.
After one before-effect rejection for missing expectedUrl, the Keeper corrected
its request. One workflow clicked Start once, waited for the observed #pending
marker to become hidden with its explicit SDK timeout unchanged, and returned
one final snapshot after **130.14s**. Both completed steps and the completion
text reached the original caller. The fixture records exactly one start and
130.006s server delay. [marker-outcome.json](keeper-14c9f0c7/marker-outcome.json)
and the retained actual tool record prove a single command beyond the prior
120-second idle lease, not merely application elapsed time. The marker screenshot
was captured by the root reviewer after Succeeded and visually inspected.

Final cleanup is now recorded in
[final-cleanup.json](keeper-14c9f0c7/final-cleanup.json). The later navigation
candidate used the same25/p1 after this Keeper stopped; its explicit detach
finished the shared task space once. The older idle SDK required the separate,
identity-checked stop recorded in old-sdk-stop.json after server SIGTERM.
Both candidate servers, their workers/SDKs and the two owned fixtures are gone.
No installed production binary or persisted production state changed.
