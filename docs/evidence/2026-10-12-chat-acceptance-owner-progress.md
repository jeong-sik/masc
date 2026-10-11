# Acceptance preserves producer ownership and active progress

Base: 2085e7c403e62557e7aa079fae76a07b50f7aed4.

Two real stream projection fixtures failed: a queued acceptance arriving after text changed a streaming response to queued; an acceptance naming a foreign operation replaced the response's canonical delivery key. RED: /tmp/chat-acceptance-owner-progress-red-20261012.log.

Acceptance now checks canonical typed delivery-key equality before attaching provenance. Initial sending/queued states may acquire acceptance status. A response that has progressed keeps delivery, streamState and streamContract while accepting matching provenance. Existing terminal response guard remains. Request IDs are compared only through the existing typed provenance contract; no prose substring or guessed provider message is used.

The keeper-stream suite passed 100 tests, and TypeScript noEmit exited 0. Log: /tmp/chat-acceptance-owner-progress-focused-20261012.log. Focused fixtures cover text progress and foreign operation ownership; Thinking/Tools, reactive observer interleaving and identity-free initial projection need further boundary review. No actual provider/server/browser screenshot, CI, formal approval or installation is claimed.
