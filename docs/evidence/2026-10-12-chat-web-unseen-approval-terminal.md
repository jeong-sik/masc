# Unseen approval terminals and compact lifecycle state

Base: `7f684f79420e9d3319d10afa7b386e67d55442ec`.

Approval state is now a discriminated pending/settled union. Stream termination retains a terminal fact even when its opening was never observed. Delayed openings and inventory hydration preserve that fact in the current authentication scope. Terminal rows contain only admission identity, authentication revision and outcome/terminal flags; pending arguments, question, reason and tool metadata are released. UI and answer consumers narrow to actionable pending state.

Expected-row HTTP receipts reject a foreign authentication owner. A current-auth stream terminal may replace an old-auth row instead of losing the new terminal fact; subsequent same-auth opening remains suppressed. Duplicate same-auth terminals preserve their first immutable terminal object.

Actual RED: restoring the previous state/stream implementations temporarily and running the two unseen-terminal cases failed both selected tests, `/tmp/chat-unseen-approval-terminal-red.log`. They show delayed opening and in-flight inventory resurrecting an unseen finished admission. Corrected source was restored before subsequent edits/checks.

Final verification: three suites, 170 tests passed with `pnpm exec vitest run src/keeper-stream.test.ts src/keeper-tool-approval.test.ts src/components/keeper-workspace/keeper-workspace-chat.test.ts --config vitest.config.ts --no-file-parallelism --maxWorkers=1`; `/tmp/chat-unseen-approval-terminal-green.log`. `pnpm exec tsc --noEmit` succeeded with empty diagnostics, `/tmp/chat-unseen-approval-terminal-types.log`. `git diff --check` passed. Feature cases also cover released pending payload and authentication partition behavior.

This reduces retained terminal payload, not the lifetime count of terminal IDs. An authoritative stream/inventory frontier is still required for resource-safe metadata retirement without permitting replay resurrection; no arbitrary time or count cap was added. No full-goal completion, formal approval, merge, deployment, installed runtime or screenshot proof is claimed. Broader provider/runtime/Thinking/tools/saying/interleaving/broadcast and continuity/UI verification remain active.
