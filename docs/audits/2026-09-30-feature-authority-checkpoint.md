# Feature authority audit checkpoint — 2026-09-30

These checkpoints name different source commits. They are not a single released or integrated build.

## Latest current-main checkpoint

This section supersedes earlier pending observations below. Play19a1, expiry5f73, pruneacb0 and rotationf800 now preserve complete mainc112 plus each reviewed own delta. Required/current native CI remains pending; no merge/deployment is claimed. Prior pruning b695 completed Test36669352105 with8/8 suites133 cases. Prior rotation040 failed before suites on a private-helper fixture reference; refreshed f800 fixes it. Dashboard40190/ce7 publishes the workspace authority repair over a065; its Vitest/typecheck/browser evidence is queued, not measured. The remaining file-backed Keeper/bootstrap/login publication gaps are being repaired in the next stack.

[Raw logs, current head/tree receipt and evidence limits](../evidence/2026-09-30-credential-current-main-native/README.md).



| Feature boundary | Repair | Measured checkpoint | Remaining |
|---|---|---|---|
| Item account / workspace / Portrait | Clear detail tokens/account on workspace transition; withdraw failed account | [#40111](https://github.com/jeong-sik/masc/pull/40111), f4041a99 native 9/9 suites, includes local/remote Portrait PTYs, Item HTTP/purchase and held history | Draft composition branch; installed runtime not verified |
| Quiz / retained capture / score history | Join source/incarnation/fact/captured URI+SHA/record; capture-version question+row ID | [#40125](https://github.com/jeong-sik/masc/pull/40125), e716f181 native 4/4 suites; current691c204c Python75/75 and Quiz image4/4; isolated snapshot-comparison mutation fails strengthened regression | Merged as1a52f26b after formal Keeper approval and current five required successes; six source blobs independently matched main. Deployed worker remains unverified |
| Play invite / Auth / DOS controller | Atomic create-only admission; corrupted/mismatched revoke refuses effects; shared strict presence protects general recovery | [#40136](https://github.com/jeong-sik/masc/pull/40136), c12151bc source review and13 parse-only files | Prior c121 Test step passed11/11 suites. Refreshed main2638 Test36665136571 measured8/9 resolved native suites passing, two corrected route assertions failing, plus two wrongly named requests unresolved. Current6714 corrected transaction native Test36666093985 passed17cases. Its corrected cache/PTY36666744553 was still running at observation. Required run36666098633 remains pending |
| Credential expiry / bearer / OAuth / Play / inventory | One strict typed RFC3339 whole-second authority, malformed denial and holder preservation | [#40171](https://github.com/jeong-sik/masc/pull/40171),63cc46e9 source review;25 published delta blobs match local candidate | Test36666481145 ran12/12 correctly resolved native suites successfully (428cases), but workflow failed for two misnamed requests. Corrected followup36666741795 passed cache4cases and actualinvitePTYalias. Required current-head checks pending |
| Credential prune / concurrent renewal / UUID deletion | One current-store Auth transaction with validated deletion targets; strict unlink; typed partial failure | [#40174](https://github.com/jeong-sik/masc/pull/40174),b69576e1 repairs native compiler label inference; initialb5f16 published delta blobs matched local candidate | Test36666974017 failed compiling auth_credential_token.ml:116 before any requested suite. Private agent_name record label shadowed credential inference. Currentb69576e1 renames the private field; Test36669352105 requests the same8suites, pending |
| Shared credential rotation / startup / concurrent publishers | Fresh groups and raw/credential publication in one existing Auth admission; UUID write-target ownership checked before effects; partial state typed | [#40182](https://github.com/jeong-sik/masc/pull/40182),040761c6 composed source review and16new feature cases | Test36669420029 requests9suites; required/native results pending |
| Candle lane publication contract | Expected refusal includes the actual seventh registered lane | [#40004](https://github.com/jeong-sik/masc/pull/40004), b6306003 isolated native2/2 suites (30+14cases) | PR check36654228217 still failed: earlier one-shot300s timeout and later step-budget cutoff. Isolated success does not establish the earlier cause or authorize merge |

## Common architectural issue

Names and declared versions alone are insufficient observation or mutation authority. The corrected paths keep the original owner of the authoritative facts: Item detail admission belongs to its workspace transition, Quiz facts/questions belong to immutable captures, and Play credentials belong to the existing Auth transaction. No extra wallet, score ledger, credential store, workspace generation counter or compatibility reader was introduced.

## Evidence limits

Python stdio workers, native host fixtures, terminal PTYs, container image contents/builds, and installed/live Keeper behavior are separate claims. The retained sources and logs demonstrate the first four only in their stated scopes. No live credential, controller, Goal, wallet, Keeper or runtime config was changed.

Human Candle calibration remains incomplete: the operator's shared-foundation Epic label is one posthoc anchor, not a fully labelled20-Goal acceptance set. The prepared revised model experiment remains unmeasured through the original production adapter. The approved shared-Goal hard cut still needs fresh runtime data and a stopped-writer rollout.

## Earlier rotation source checkpoint (superseded)

Startup shared-token rotation still reads its groups before credential admission and writes raw sidecars before separately saving credentials. Source review found Admin renewal overwrite and successful rotation with a missing raw sidecar when prune interleaves. The next work unit is implementing current-group reading and raw/credential publication inside the existing Auth admission. This finding has no native reproduction yet.

## Dashboard Item workspace repair

An independent source audit found the same account authority omission in the Dashboard consumer. The prepared fix captures accepted raw workspace_root, process epoch and the existing hydration request generation, reusing an immutable admission token and rejecting late responses before effect cleanup. It is being composed over current Item integration a0653280 while retaining account revision refresh and prior browser evidence. Typecheck, Vitest and actual browser verification remain unmeasured.
