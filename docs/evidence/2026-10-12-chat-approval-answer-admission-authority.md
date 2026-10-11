# Approval answer admission authority

Base: `62e318343f363e8f33ead94254dab16b3dff5cf0`.

The actual HTTP answer requires and parses canonical UUIDv7 `approval_id`. Registry settlement atomically selects the Keeper's exact admission rather than provider call ID. Registration retains provider-call displacement ownership, while answers do not infer admission from that key. Late-answer attribution records and matches a typed admission ID together with workspace and Keeper; the v3 journal encodes that identity and validates/restores it. Remembered retry authorization still uses the existing canonical tool/argument fingerprint and one-use policy.

Web sends its admission-indexed action identity, validates it at the HTTP adapter, and retains auth/exact-row ownership. TUI inventory decodes typed admission IDs. Both chat and Approvals answers post that ID. Surface async receipts, presented-row identity and confirmed retirement retain typed admission identity; the provider ID remains separate tool metadata.

New state/decision tests specify that a displaced admission cannot approve a replacement with reused provider ID, a late answer authorizes only its original question, and TUI confirmed retirement preserves another admission of the same provider call. Existing fixture callers obtain actual registered IDs or capture producer IDs. HTTP actor/workspace fixtures and inventory fixtures carry admission IDs. These OCaml tests were not executed.

Executed validation:

- Web: three suites, 164 tests passed; `pnpm exec vitest run src/keeper-tool-approval.test.ts src/keeper-stream.test.ts src/components/keeper-workspace/keeper-workspace-chat.test.ts --config vitest.config.ts --no-file-parallelism --maxWorkers=1`; `/tmp/chat-approval-authority-web-tests.log`.
- `pnpm exec tsc --noEmit`: successful with empty diagnostics; `/tmp/chat-approval-authority-web-types.log`.
- OCaml 5.5.1 syntax-only parsing of all 25 changed ML/MLI files: successful with no diagnostics. Source hashes and exits: `/tmp/chat-approval-admission-authority-syntax.json`. This is not OCaml typechecking or functional execution.
- `git diff --check`: successful.

No local Dune build, CI, independent formal approval, merge, installed runtime, provider continuity or screenshots were verified. Source review is requested separately. Remaining goal work includes duplicate opening replay, unseen terminal/frontier and resource-safe retention, timeout-to-late-store publication ordering, Home/Agenda ownership projections, async receipt presentation, all provider/runtime event paths and actual visible UI validation. The identity switch is not full chat completion.
