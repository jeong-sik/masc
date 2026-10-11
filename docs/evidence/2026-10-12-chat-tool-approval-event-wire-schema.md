# Approval event wire schema repair

Base: `54e67cdc85c85ed84fc35e3249c4c2fe79baaff4`.

The preceding producer added server approval admission IDs to REQUESTED and SETTLED, while the Web strict allowlist rejected those fields. Independent source reviews returned FAIL/HOLD. These historical findings remain valid for that head.

Actual producer-shaped fixtures reproduced the decoder rejection: 3 failed / 191 passed in `/tmp/chat-approval-event-wire-red.log`. The corrected schema admits and validates required UUIDv7 approval IDs with the existing UUID library, requires the producer policy reason, and keeps rejection of unknown fields. The event union carries the same required fields. A functional test sends both events through the strict decoder and the real stream projection, confirming pending and settled state.

Validation on the source changes:

- `pnpm exec vitest run src/schemas/sse.test.ts src/keeper-stream.test.ts src/keeper-tool-approval.test.ts --config vitest.config.ts --no-file-parallelism --maxWorkers=1`: 3 files, 343 tests passed; `/tmp/chat-approval-event-wire-green.log`.
- `pnpm exec tsc --noEmit`: successful, empty diagnostics; `/tmp/chat-approval-event-wire-types.log`.
- `git diff --check`: successful.

The new integration fixture initially lacked required AG-UI envelope fields and timestamp. Those fixture failures were corrected; they are not the product regression reproduction above.

This repairs wire admission only. Web state, answer commands, backend settlement, and late-answer correlation still use provider tool-call IDs in some paths. Admission identity authority must be propagated through those consumers before claiming that reused provider IDs are safe. No local Dune build, CI, installed binary, provider continuity, visible UI or screenshot verification was performed. This evidence is not independent GitHub approval or merge admission.
