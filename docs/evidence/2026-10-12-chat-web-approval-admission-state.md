# Web approval state indexed by admission

Base: `8fff01b8ee9585763b47d0a7ea5f940c050ef093`.

Approval storage, immutable row updates, settlement, hydration gap checks, answering ownership, and card actions now use the canonical server approval admission ID. Provider tool-call IDs remain metadata. Different admissions with a reused provider ID therefore coexist without overwriting each other or suppressing hydration. Existing exact-row and authentication ownership remain intact.

Feature checks cover two admissions sharing one provider call ID while an answer is in flight: the old answer settles its own row and leaves the newer row unchanged. Inventory hydration admits a different admission even when the provider call ID is already known. Existing stream displacement checks now address distinct admission-indexed rows. Existing replacement of the same admission row still exercises immutable receipt ownership. Test IDs use the existing UUIDv7 library rather than fabricated provider-to-admission parsing.

Final validation: three suites, 164 tests passed with `pnpm exec vitest run src/keeper-stream.test.ts src/keeper-tool-approval.test.ts src/components/keeper-workspace/keeper-workspace-chat.test.ts --config vitest.config.ts --no-file-parallelism --maxWorkers=1`, log `/tmp/chat-web-approval-admission-state-tests.log`. `pnpm exec tsc --noEmit` exited successfully with empty diagnostics, `/tmp/chat-web-approval-admission-state-types.log`. `git diff --check` passed.

The HTTP answer adapter still sends the retained provider call ID because backend settlement and late-memory authority have not yet switched. This source must not be described as full answer safety, merged/deployed behavior, runtime continuity or visible UI proof. Unknown terminal events, duplicate opening replay, terminal retention/frontier and server/TUI command ownership remain work. No CI, formal approval, merge, installed runtime or screenshot verification was performed.
