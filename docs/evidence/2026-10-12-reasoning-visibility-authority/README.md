# Reasoning visibility flag authority

Base: `c039a73a0f789b9b85ef9ed9b89950381d8ca5d8`.

Both persisted block decoding and TUI history projection interpreted malformed
`content_withheld`/`redacted` as false, exposing supplied reasoning. Duplicate
keys depended on the first value, so conflicting visibility assertions could
also authorize exposure. This violates the encoder's typed visibility boundary.

A shared `Keeper_chat_blocks.reasoning_visibility_of_fields` codec accepts
absence (false, matching encoder omission) or one boolean. Supplied nonbooleans
and duplicates return closed typed errors. The block decoder rejects the record;
the TUI history projection retains an omitted-step observation without its
content. Valid true continues to scrub text, and valid false/absence retains
only explicitly supplied content. No hidden reasoning is generated.

Interpreted probe in `/tmp/masc-reasoning-visibility-20261012/`: selected actual
trace-thinking and thinking block decoder arms, actual history counterparts,
and full shared codec. Uses installed Yojson, minimal trace/summary types and
field/line helper doubles. Parent exits 2 on malformed flag admission; current
exits 0. Nine malformed/duplicate cases across four consumers, plus absent/
false/true controls. Unrelated block parsing, full history and renderer are not
executed. Registered block-decoder fixture added but unexecuted.

Syntax-only parsing passes for the interface, two implementations and fixture;
diff check passes. No Dune build/full typecheck/CI/formal approval/merge/runtime/
UI or screenshot proof.

Identity investigation: trajectory `block_index` is AGENT_CORE final content
position, while live reasoning uses response generation/scope/content index.
The durable history aggregate discards per-step indices; autonomous Run_think
producer supplies None, and Trace_reason has no shared index. Numeric equality
cannot establish cross-path coverage. Full reasoning dedup remains unfinished.
