# Overlapping operator actions retain their pending ownership

Parent: `b41d1a2bba17bdd0e178d831e27a89a0631a5a0f` (#42435).

Dispatch and confirmation each wrote the same global busy boolean. With both calls pending, completing or failing the first unconditionally cleared busy while the second was still running. Two actual action-boundary fixtures reproduced false instead of true (`/tmp/operator-action-pending-red-20261012.log`). Transport alone is mocked; the action implementation and reactive signals are real. Each fixture resolves the remaining operation in finally.

A private immutable pending-operation identity set is now the single source of truth. Busy is a readonly computed projection. Each action acquires one release capability and releases only its own identity in finally, including failures. No request is rejected or serialized by this change. The independent desktop-post fixture now arranges a real pending ownership lease instead of mutating the display projection. Unnecessary test resets of the projection were removed.

Focused direct-consumer validation completed: four suites / 129 tests passed with `npx vitest run src/operator-actions.test.ts src/components/board/board-surface.test.ts src/components/board/composer-v2.test.ts src/components/ops/cmd-intervene-form.test.ts`, retained at `/tmp/operator-action-pending-focused-20261012.log`. `npx tsc --noEmit` exited 0. Production and test writer census finds no remaining assignment to operatorActionBusy.value.

This proves concurrent pending lifetime only. Credential partition, stale log/error/refresh publication and snapshot/digest ownership remain separate work. No CI, installation, live provider/server, browser screenshot, TUI runtime or formal approval is claimed. The full chat goal remains active.
