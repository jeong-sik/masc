# Supplied server timestamp authority

Base fde7d97cae632489d403fed26bafe0825e22f479.

Live frame timestamp decoding previously converted malformed supplied time to
None then dispatched the state event. The mailbox uses arrival time when at is
None, so a malformed server clock became a different observed timeline instant.
Strict stream decoding already required finite nonnegative event timestamps.

Share event_timestamp_of_fields between strict validation and live frames.
Finite nonnegative JSON Int/Float retain epoch seconds, absent time remains
unobserved on live frames, supplied null/negative/string/boolean/nonfinite and
duplicate timestamps produce Undecodable and do not dispatch the payload event.
Strict events still require time; optional absence is not supplied corruption.
No time budget, new time range, arbitrary cutoff or content matching added.

## Direct bounded probe

/tmp/masc-event-timestamp-20261012/{generate.py,parent.ml,current.ml,parent.log,current.log}.
Complete actual Sse_wire module, actual frame_deltas function, complete new
shared timestamp decoder interpreted using installed Yojson. event_deltas is
an explicitly counted dispatch sink returning Run_started, not actual strict/live
event dispatch; id classifier is fail-fast because frames supply no id.
These doubles measure whether malformed time reaches state dispatch and avoid
claiming whole stream/reducer execution. Strict wiring source-traced only.

Parent exit2: malformed supplied clock became untimed admitted event.
Current exit0: null/negative integer/negative float/string/boolean/NaN/Infinity
refuse dispatch; valid integer/fractional seconds and true absence retain clock;
duplicate field rejects in shared helper. Existing registered protocol fixture
extended for four malformed values, unexecuted. Four changed OCaml files parse
syntax-only; diff check passes.

No full typecheck/build/CI/registered fixtures/provider/reducer/runtime/UI,
installation/formal GitHub approval or merge proof. Input interleaving and
broadcast state integration remain parts of the active full objective.
