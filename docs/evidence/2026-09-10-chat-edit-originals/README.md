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
loading remains pending CI artifact verification.
No local build was run. CI build and browser screenshots are still pending.

## Remaining acceptance work

Objective 15 still requires CI-built browser proof and deployed Keeper edits. Non-UTF-8 data cannot round-trip through this
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
The harness is implemented; screenshots have not yet been produced.

Backend targeted CI run 34380660903 exposed a missing artifact-reference carrier
at the ordinary tool hook. #34924 commit c797dd4e6c repairs that path; targeted
rerun 34382313926 was dispatched. Five filesystem race cases also failed in the
first run and remain unresolved; their baseline behavior has not been measured.
