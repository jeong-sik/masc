# Curator stream observability

The next execution path requests Ollama NDJSON streaming. Every received line is
saved and flushed before decoding. `progress.json` records requesting/receiving
and terminal phases, decoded chunks and content/thinking character counts. These
are observation counters, not token estimates or execution limits. Terminal
counts also remain in `receipt.json`.

Only an explicit `done: true` event allows proposal validation. EOF after partial
output is a failed execution; its raw bytes and progress remain readable. JSON
state files are replaced atomically so observers do not read partially written
records. HTTP responses and files are closed on completion or failure.

Seven CLI scenarios pass, including multi-event Unicode assembly and EOF without
a terminal event. This is local HTTP-fixture evidence. The earlier nonstreamed
27B run was neither interrupted nor restarted by this change. An actual streamed
model run is still needed before claiming live progress observation.
