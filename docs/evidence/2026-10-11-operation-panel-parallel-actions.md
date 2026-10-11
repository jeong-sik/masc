# Parallel operation panel action ownership

Base: 8e5a90db0210e7a66568b16dc8ac0314d046561f (#42407).

An actual two-operation DOM fixture failed before repair: starting B replaced the single pending action for A, re-enabling A's cancellation button while its request was still pending. Source review also confirmed the single action-owner token would suppress A's later result after B started.

Actions now use a typed operation-or-interruption address with structural tuple identity. Exact owner tokens are held per address. The scoped immutable action projection keeps pending addresses and failure records independently. Same-address duplicate admission returns before another API action; own completion removes only that address's pending state. A retry clears its own failure record, and another action's successful list refresh does not erase it. Failure records retain their typed address and are labelled in the advanced operation panel, outside authored chat content.

The fixture verifies A and B remain pending together, A failure publishes while B remains pending, B completion releases only B and A's error remains visible. Existing panel replacement, authentication and remount fixtures also passed in the same keeper-shared suite. API body tests were not rerun for this UI-only change.

Validation: 34 focused keeper-shared tests, TypeScript noEmit and git diff --check passed. Independent review of the two implementation/test files passed; final committed full-scope review is separate. The original red fixture directly established early pending release; its later assertions verify the repaired failure/completion sequence, not separately executed pre-repair failures. No formal GitHub approval, CI, merge, actual server, installed runtime or live browser screenshot is claimed.
