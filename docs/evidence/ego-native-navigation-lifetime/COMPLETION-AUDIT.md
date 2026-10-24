# Native-first goal completion audit

Goal: use Ego Lite itself as far as its installed APIs support, supplementing
actual MASC integration gaps. This audit covers implementation, PR delivery and
isolated real execution. It does not claim merge, production installation,
release readiness, every browser feature, or repair of unrelated runtime bugs.

| Requirement | Current source and inspected evidence | Result |
|---|---|---|
| Ego interprets normal DOM targets | Native snapshot/ref default in both Keeper/browser skills and nativeTargetInput in browser_ego_peer; existing SDK iframe/shadow/selection evidence and actual Keeper ref/locator calls | Proven for the implemented native surface |
| Known actions use native calls and conditions, one final snapshot | Closed native workflow codec, production JS, selected host tests and real form/marker Keeper calls; no injected caller JavaScript | Proven |
| Remove duplicate MASC sequence limits and SDK timeout races | Bottom PR45812 removes step-count/cumulative clocks and Promise.race; actual20-step SDK run, codec tests and source/host checks retained | Proven at those stated evidence layers |
| Native input lifetime belongs to SDK | Parent PR45821 native runner + actual transport policy; selected80 tests and original call returning after130.14s on compiled14c9 candidate | Proven |
| Long work retains the original connection/caller | Authenticated take binds running ownership; expiry/cancel/disconnect component cases and actual130.14s click+hidden wait, completed2/failure:null, starts1, Succeeded | Proven |
| Native navigation uses same lifetime as workflow navigation | PR45830 run_native_step for open/goto/reload, Ego-only policy; selected50 tests, current a96 real Keeper ordinary goto/reload/native snapshot | Proven; open creation/partial failure is covered by peer integration tests |
| SDK owns handled chooser cleanup | Duplicate setFiles([]) removed; actual installed SDK failure then next chooser success in one process, original peer assertion and current selected CI | Proven |
| Supplement actual transfer/process gaps | Sandbox grants/staging/leases and receipts stay at MASC boundary; native upload/drag/download methods remain SDK-owned. Installed SDK dialog process-state and download-handle observations are retained in earlier integration evidence | Proven rationale for retained adapters; no claim all protocol windows are universally necessary |
| Preserve other-browser semantics and uncertain effects | Actual transport selects policy; Firefox/BiDi and guarded/history boundaries retained. Peer created/partial/unknown receipts and no replay cases preserved | Focused tests/source review; no new live Firefox claim |
| Real task completion and persisted output |14c9 real glm Keeper, exact1 matching EGO-001, completion snapshot/screenshot; marker and a96 navigation operations Succeeded. Raw tools omit reasoning and credentials | Proven within isolated candidates |
| Deliver reviewable changes | Native Stack45822: PR45812,45821,45830; exact-source independent reviews, selected CI and this evidence follow-up | PR delivery; merge/installation not performed |
| End owned runtime resources | New explicit detach native_released + space25 absent; both servers/workers/SDKs and fixtures absent after recorded old-SDK stop | Proven; generic server-signal orphan cleanup remains a separate limitation |

Candidate14c9 proves the input/workflow/lease behavior. Candidate a96 includes
that runtime source plus the navigation layer and proves its ordinary navigation
path. Evidence-only commits after a96 must retain an empty runtime-input diff;
they do not become a newly executed binary identity. Full regression/release
CI was not requested or run. Independent agent review is source/evidence review,
not a formal GitHub approval.
