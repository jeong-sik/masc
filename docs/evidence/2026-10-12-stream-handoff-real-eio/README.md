# Actual stream handoff concurrency

Run `python3 docs/evidence/2026-10-12-stream-handoff-real-eio/run.py .`.
The recorded execution exited 0. The harness interprets the complete production
`lib/server/server_keeper_stream_handoff.ml` and loads installed `eio_main`.
No production source changes, extracted function copies, or cancellation doubles.

Actual Eio promises suspend the sender while another fiber publishes. Actual
Eio cancellation tests exception propagation and subscription closure. An actual
OCaml Domain publishes while the first sender is inside its callback: it must
enqueue without invoking its own send callback or acquiring a second sender.
Assertions inspect delivered integer event identities and callback ownership,
not screen text, row order, or a rendered snapshot.

Scope: in-memory server subscription handoff only. Callback send completion is
not socket flush, durable journal publication, provider input consumption, or
user receipt. No actual HTTP/TCP, installed TUI, broadcast routing, full build,
CI, or formal approval is certified. Closing may allow an already claimed send
to finish, as the production interface specifies; pending sends are discarded.
This does not establish ordering of events before producers enqueue them.
