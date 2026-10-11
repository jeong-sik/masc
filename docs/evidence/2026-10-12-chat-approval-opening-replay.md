# Approval opening replay preserves lifecycle

Base: `c5e87c5d8aab0fa90d1205a4ac4aa5e00f62f804`.

An approval admission is immutable in one authentication scope. The shared opening publisher now retains an existing same-ID row instead of replacing it. Duplicate stream openings therefore preserve answering ownership and known terminal facts. A different authentication scope may publish its own row; distinct admission IDs remain independent.

Actual RED: the real stream and answer consumers reopened a settled row and reset an answer in flight when the same opening replayed: two selected tests failed in `/tmp/chat-approval-opening-replay-red.log`. Final feature tests use the same opening identity after settlement and during a pending HTTP answer; only the original POST may dispatch. Existing receipt-ownership cases now use actual independent settlement rather than reconstructing a supposedly new admission under the same identity. All pending test HTTP answers are resolved and awaited.

Final execution: three suites, 166 tests passed; `pnpm exec vitest run src/keeper-stream.test.ts src/keeper-tool-approval.test.ts src/components/keeper-workspace/keeper-workspace-chat.test.ts --config vitest.config.ts --no-file-parallelism --maxWorkers=1`; `/tmp/chat-approval-opening-replay-green.log`. `pnpm exec tsc --noEmit` succeeded with empty diagnostics; `/tmp/chat-approval-opening-replay-types.log`. `git diff --check` passed.

Independent reviews of the parent authority switch have identified OCaml direct-dependency/module-qualification P2 findings. This Web-only unit does not clear those findings; they require a separate repair. Unknown terminal events/frontier, terminal retention, timeout-to-late-store ordering, Home/Agenda identities, runtime/provider coverage and visible UI proof remain incomplete. No formal approval, merge, CI, deployment or screenshot claim is made.
