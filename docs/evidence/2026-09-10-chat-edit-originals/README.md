# Chat edit originals — implementation evidence

This frontend stack consumes the durable edit snapshots introduced by #34924.
It adds an explicit button to fetch both complete files from the artifact API,
checks each response's byte length and SHA-256 against the recorded reference,
and renders a unified diff plus both verified originals without interpreting HTML.
The established jsdiff engine is loaded on demand and runs in a dedicated worker that is terminated when the view closes. Input snippets are not
required for this view. Closing the view cancels pending fetches; reopening
retries failures.

## Verification

Focused Vitest run on 2026-09-10 KST passed 21 tests across:

- `src/api/edit-snapshots.test.ts`
- `src/components/chat/edit-evidence.test.ts`
- `src/components/chat/edit-snapshot-view.test.ts`

Coverage includes CRLF and whitespace preservation, altered-response rejection,
missing input snippets, explicit persistence/retrieval failure, retry, keyboard
focus, CRLF changes, a final-newline-only diff, cancellation before computation,
and worker termination on close/reopen/unmount. Component tests simulate the
worker transport while executing the real jsdiff engine; actual browser worker
loading was subsequently verified in the CI artifact scenario below.
No local build was run. CI-built browser screenshots are recorded below.

## Remaining acceptance work

Objective 15 still requires deployed Keeper edits and full-chat integration proof. Non-UTF-8 data cannot round-trip through this
JSON text endpoint and fails byte verification. Endpoint-owned remote edits are
outside the current backend producer coverage. LSP observation is independent
and remains unverified.

## Diff implementation reference

[jsdiff's primary documentation](https://github.com/kpdecker/jsdiff/blob/master/README.md)
provides line comparison and asynchronous callback execution. The implementation preserves whitespace and final-newline differences. Fetch/verification precedes diff
computation so neither transport corruption nor unsupported text becomes a
plausible-looking change preview.

## CI browser scenario

The preview-only Vite configuration includes `dev-fixtures/chat-edit-snapshots.html`.
Release builds keep their existing entry. After downloading the CI preview:

```sh
node scripts/verify-chat-edit-preview.mjs PREVIEW_DIR PR_HEAD EVIDENCE_DIR
```

The harness checks all manifest hashes, serves only local fixture assets and
artifact responses, and exercises the actual browser worker. It checks CRLF and
final-newline changes, full originals, visible persistence failure, corruption
rejection, focus, and mobile overflow; it writes desktop/mobile screenshots and
a receipt. These are synthetic HTTP records, not a deployed autonomous edit.
Browser run passed at 2026-09-09T17:21:54.684Z using artifact 10116348739
from CI run 34382147967, PR source 3c5388a76d9dc2cda2d6e0cab618559a79dd2550,
checkout 30b9aa691b2f92f1bb64d902dfcf13ebeb7a5897. The run was later cancelled
by a newer push; this is artifact execution proof, not an overall green CI claim.
The dashboard source and dependency files were unchanged between this artifact
source and verification-time head 5053d8677247bdcf64db64cd84c69f2061525355.
All manifest files passed SHA-256 verification before serving.

Three scenarios passed with one actual browser worker and zero page errors.
Screenshots were visually inspected at 1440x1000 and 390x844; the mobile document
had no horizontal overflow. Evidence: [desktop](browser/desktop.png),
[mobile](browser/mobile.png), [receipt](browser/receipt.json).

Backend targeted CI run 34380660903 exposed a missing artifact-reference carrier
at the ordinary tool hook. #34924 commit c797dd4e6c repairs that path; targeted
rerun 34382313926 was dispatched. Five filesystem race cases also failed in the
first run and remain unresolved; their baseline behavior has not been measured.

## Full transcript browser follow-up

At 2026-09-09T17:31:46.273Z the full `ChatTranscript` flat tool-card path passed
all three browser scenarios. Receipts used distinct execution IDs and reused the
same provider ID. Source 832795b620852748fb5cc997f11d2d9677592d18, CI run
34382910298, artifact 10116630108, checkout
47709ba292401fbc508800559ade418be1a38854. One real worker ran with no page errors.
The mobile screenshot was visually inspected; no document horizontal overflow.

[Desktop](full-chat-browser/desktop.png), [mobile](full-chat-browser/mobile.png),
[receipt](full-chat-browser/receipt.json). These remain synthetic HTTP inputs,
not deployed autonomous edits. Grouped autonomous turn presentation still needs
its own browser scenario. The focused ChatTranscript suite passed 165 tests,
including a reused provider ID with a different execution that must not join.
