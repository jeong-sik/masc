# Buffered thinking retains its publication owner

Base: 5636656e11da7217db890bd608becf7916cc6b23.

Three parent projection fixtures failed: pending exposed reasoning was flushed after credential replacement, onto a replacement operation with the same row id, or onto a user row replacing that id. RED: /tmp/chat-thinking-buffer-owner-red-20261012.log.

Pending reasoning captures immutable credential revision, copied canonical delivery key when present, target source and turn reference. Both enqueue reuse and flush validate this publication owner against the current assistant target. Obsolete buffers are removed and their scheduled handles released before publication. The pure ownership predicate takes its current credential revision at the effect boundary. Existing same-owner preview/interleaving fixtures continue to pass.

The keeper-stream suite passed 115 tests; TypeScript noEmit exited 0 and diff check passed. Log: /tmp/chat-thinking-buffer-owner-focused-20261012.log. Fixtures exercise public state/projection and controlled flush, not an installed provider incident or actual browser screenshot. Initial keyless row incarnation changes and reactive observer changes during publication remain separate checks. No CI, official approval, installation or runtime continuity proof is claimed.
