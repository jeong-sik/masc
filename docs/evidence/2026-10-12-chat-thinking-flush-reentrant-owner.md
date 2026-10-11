# Thinking flush revalidates after observable publication

Base: 0f9fbb4e2bbe82a106670a3e4548d47aa6ca5ecb.

A real signals observer reacts to thinking trace publication and replaces the row with another operation. Parent follow-up activity preservation changed the replacement's queued state to the original sending state. The observer mutation is untracked and one-shot to avoid a fixture feedback cycle. RED: /tmp/chat-thinking-flush-reentrant-red-20261012.log.

Flush now revalidates its captured credential/producer/domain owner after thinking snapshot publication and after activity restoration, before persistence. The activity updater itself checks its actual target owner. A stale preview removes only its exact pending record, preserving any replacement buffer. Commit/preview share the same publication sequence, reducing duplicate effect paths.

The keeper-stream suite passed 116 tests, TypeScript noEmit exited 0, and diff check passed. Log: /tmp/chat-thinking-flush-reentrant-focused-20261012.log. This proves a public projection/signals interleaving, not a live provider/browser screenshot. Initial keyless row incarnation and same-producer response-generation transitions need further review. No CI, formal approval, deployment or runtime continuity claim.
