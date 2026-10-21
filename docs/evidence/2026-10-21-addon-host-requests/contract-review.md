verdict: PASS head: f4f55f5486edee82e060f51b8fe596978a4e29ef by: bidi_partial_failure_response

Independent SOURCE/contract review for PR #44824, bounded G03 host request observation follow-up.

- Base: `97468f95df78f35a35bb3fe14a9670240cced930`.
- Complete8-file diff:213 additions,5 deletions.
- Canonical `masc-reviewed-git-diff-v1` identity: `ae8f57dd841eae4200fe9cf94c7a9bf86ccdd19e32fd3dabc921b9d0bf1afa62`.
- Read all7 original source/test/worklist files at76cb4d11b311e16b73f78053a6fb0f5e4042b77c, their direct consumers, Runtime/Exact/TUI wire producers and decoders. Then read the complete final changelog-only delta; all7 prior blobs are identical in currentf4f55f.

No unresolved P0, P1 or P2 found in this scope.

Wire and logic assessment:

1. Compared `Runtime.host_status_json` and `host_issue_to_json` against the new decoder. Cycles, waiting request IDs, null-or-typed issue and all7 emitted issue constructors match. Compared all8 `Exact.not_final_to_json` constructors plus Runtime's awaiting_operator/source_unavailable cases: all10 wire waits are represented. Diagnostic detail deliberately accepts empty strings, matching original host/Exact/TUI contracts.
2. Optionality is honest: omitted host_requests remains absent, an actual zero-cycle object is observed, and present null/malformed/unknown or excess nested data is unreadable. Absence is not converted to zero, completed or healthy. The backend currently adds host_requests on live_json and commonly omits it on retained entries; the code makes no claim that every retained worker has a cycle.
3. Strict parsing applies to the diagnostic object and its known nested alternatives via onExcessProperty:error. The surrounding instance accepts that field as unknown before local decoding. A malformed diagnostic therefore does not invalidate a valid original worker, observation rows, configuration revision or action target. This is strict wire shape/known-enum validation, not a new model-result validator or a complete set of possible cross-field semantic invariants.
4. The decoder maps each received instance independently, preserving original ID/incarnation/run/package/phase/configuration fields. It has no fallback to a replacement or another owner. The component receives that exact instance directly from the worker row; no title, run, declaration or current-worker selection joins copy a cycle between workers.
5. The rendering is read-only. No host-request field is used for application, success, canObserve, selection, action submission or receipt validation. Absent, zero, waiting, issue and unreadable observations remain different. The text explicitly separates last received cycle, results, delivery receipts and cleanup.
6. Read actual direct type/consumer paths: LaneAddonInstance/Snapshot now override only the optional field type; existing consumers still receive the same required fields. Snapshot fetching still calls the single canonical parser. Action requests and exact instance/incarnation/request-ID receipt verification are unchanged.

Tests and evidence boundary:

- API fixtures cover all emitted reason/issue variants, empty diagnostic details, malformed/excess/unknown shapes, empty IDs, null, zero and absent. They assert original metadata remains and replacement absence is not filled from the original.
- Panel fixtures assert supplied original and replacement rows render separate host cycles, invalid diagnostics retain worker/rows, and rendering causes no Observe/action request.
- The test described as after replacement supplies a retained worker carrying host_requests. It proves read-model/UI isolation for supplied data; it does not execute actual Runtime replacement, real model/provider behavior or durable cycle history. Production currently injects this field only in live_json rather than persisting host_status in entry_json. Durable history across actual detach/restart is not established by this unit and must not be inferred from that fixture.
- The worklist remains partial and explicitly leaves full request history, actual UI and installation evidence open. The final own-number Fixed fragment describes preserved Dashboard observations without claiming model/Runtime/browser execution.
- Author reports6Dashboard suites/98tests and tsc PASS. This reviewer did not rerun those checks or independently audit their logs. No new OCaml behavior is executed here.

Limits: local immutable source judgment only. No builds, tests, typechecks, CI requests/queries, source/ref/GitHub/runtime changes or formal approval. Only this requested /tmp review record was written. This does not complete G03, certify durable historical-cycle retention, prove visible UI/deployment, or approve later evidence/rebase heads or the full Addon worklist.
