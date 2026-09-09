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
