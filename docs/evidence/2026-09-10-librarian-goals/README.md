# Goal criteria in Librarian input

The per-Keeper Librarian previously received role instructions, selected
memory and recent messages/tool observations, but no explicit linked Goal
criterion. The post-turn memory owner now resolves the latest immutable post-tool meta's
Task through the primary goal-task registry and passes goal IDs, phases and typed
criteria (revision/title/metric/target) to Librarian input. All linked phases
remain relevant to post-turn memory, including recently completed work.

No Task, available criteria and unavailable criteria are represented
separately. Missing linked Goals or unreadable primary stores remain visible
errors in context; they do not suppress independent memory selection.
The same context is persisted in standalone-agent input evidence and rendered
in the actual Librarian prompt, with an instruction that criteria are not
completion proof. This introduces no model call or runtime budget gate.

A repository-template scenario checks goal identity, metric and revision in
model messages, explicit missing-source context, no stale criterion after a
failed read, and no-task context. Prompt-path validation and diff checks ran
locally; OCaml build/execution belongs to CI. No deployed model request or
behavior improvement was measured in this slice.

This improves per-Keeper goal-aware memory selection. It is not the requested
workspace-wide memory consolidation lane; that requirement remains open.

Adversarial review found the initial collector would receive admission-time
meta. The final post-turn call instead snapshots `acc.meta`, matching task
changes adopted after tool execution. A separate repository-backed scenario
covers Task selection changes, revised criteria, completed phases, missing
Goals, unreadable primary links with recovery present, and standalone Tasks.
These tests do not execute a full provider tool-claim/finalize sequence.
The existing Dashboard prompt-registry suite passed 11 tests after adding the
new input field to its Librarian contract display.
