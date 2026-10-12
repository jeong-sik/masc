# Provider correlation on model content observations

Base: `80dcf14c37cca139059d2252e53c189c98df9b00`.

The bridge emits generation/scope/index/channel and provider message correlation.
The transcript discarded the provider ID. A foreign explicitly named stop with
the same scope/index could close current text or reasoning; foreign observations
could also refresh its activity timestamp.

Retain the provider message ID in a private immutable observation record.
Conflicting supplied IDs leave occurrence activity unchanged and increment the
existing unreadable evidence counter. A missing ID does not erase a known ID;
a later supplied ID can enrich an unknown occurrence. Exact matching and
missing-correlation stops remain admissible; closed tombstones cannot reopen.
New responses still reuse indices. No provider ID is used as a guessed name or
text-pattern classifier. Existing response admission and body-byte policies
are unchanged, including retaining late body bytes without reopening activity.

Bounded interpreted probe `/tmp/masc-content-provider-correlation-20261012/`:
actual complete apply_model_content/model_activity functions and exact response
frontier/correlation helpers; minimal event/state declarations, note_unreadable
counter sink and no-op begin_response (unrelated speech-boundary effect). Parent
exits 2 on conflicting stop closing current activity; current exits 0 for both
channels, conflict observation/stop, missing ID retention, matching stop,
tombstone replay, late-known ID, missing-correlation stop and new-scope reuse.
This is not full apply_delta, renderer, provider or real I/O execution.

Registered ownership-decision fixture added, not executed. Syntax-only parsing
of production and fixture and diff check passed. No local Dune build, full
typecheck, CI, formal approval, merge or runtime/UI/screenshot proof.
