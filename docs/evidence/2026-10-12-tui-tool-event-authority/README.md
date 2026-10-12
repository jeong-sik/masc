# Tool event authority boundary

Base: 02017231d5e507025e2e5c490ba29972c056f522.

MASC Tool_args and Tool_ended events could update a Provider_native occurrence
when correlation matched. This overwrote native observation arguments or marked
native activity ended without a native completion observation. Tool_result
already refused native receipt ownership. Add the matching authority check to
argument and argument-end handling, preserving native state and recording a
protocol observation error. MASC argument accumulation and end handling remain
unchanged, including refusal of late arguments after argument end.

Artifacts: /tmp/masc-tui-tool-event-authority-20261012/.
Actual parent/current event arms are interpreted with minimal call/event types.
Occurrence matching/update is an explicit stub admitting the supplied call;
identity admission, stream parsing and full transcript reduction are not tested.
Parent exits 1 because MASC events mutate native activity. Current exits 0 for
native argument/end preservation with conflict diagnostics, canonical MASC
snapshot/delta/end behavior and late argument refusal. This is decision evidence,
not end-to-end provider/native protocol proof.

The existing native observation state fixture adds the mixed authority sequence;
it is unexecuted. Two changed OCaml files passed syntax-only parsing; diff
whitespace check passed. Full typecheck/build, event decoding and producer
integration, journal replay, installed runtime, UI/screenshots, CI, formal
approval and merge remain unverified.
