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
a terminal event. Those are local HTTP-fixture tests.

The actual held-out local 27B run completed in 564.340843 seconds, without a
restart or imposed time/token budget. `qwen38-27b-stream/` retains its input,
request, raw NDJSON, assembled response, proposal, progress and receipt.
It received 6,644 events; the final event explicitly reports done. Reassembling
the events reproduces the saved response: 596 content characters and 26,380
thinking characters. Provider counts were 1,159 prompt and 6,646 output tokens.
`stream-observation.json` remains an intermediate observation of this same run.

Manual comparison against `input-stream.json` finds that the proposal preserves
the unresolved Dataset D disagreement (writer: 10 samples; reviewer: 15), with
both source IDs, and attributes the analyst's correction from 43 to 37 ms with
both old and corrected source IDs. Missing source-bound stores remain gaps;
they do not erase ordinary claims. An independent adversarial review also
reconstructed the stream and checked the input digest and proposal.

This is one synthetic case, not a quality benchmark or proof of broad model
reliability. The script's semantic_verification remains not_performed: the
manual comparison is separate from automated structural validation. No live
memory promotion, Keeper recall, or autonomous server lane is demonstrated.
