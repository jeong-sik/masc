# Stream message identity decoding

Base: `31b8c4a79474b4c268e631dc88613b28b31b3400`.

Message start read stream_scope using an Int-only live helper and unrestricted
journal to_int, while message delta used safe-integer parsing. A malformed
supplied start scope could become absent live ownership or an unsafe/negative
journal identity. Integral Float spellings lost identity on start.

Keeper_chat_events.stream_message_identity_of_fields now owns generation/scope
parsing for live start/delta, strict CUSTOM identity validation, and journal
start/delta. Both supplied fields require unique nonnegative JSON safe integers;
observed generation requires scope. Absence of generation remains unobserved.
Journal event types still require scope; live payloads can be wholly unobserved.
Other payload fields, model labels, usage, producer events and reducers are unchanged.

## Direct bounded measurement

Interpreted actual complete shared identity codec, complete Runtime_json_integer,
selected production live start arm and selected journal start arm with minimal
event types and wrapper dispatch. Usage accessors are fail-fast probe sentinels;
all cases omit usage. This does not run the whole modules or SSE/reducer path.

Artifacts: `/tmp/masc-message-identity-codec-20261012/{generate.py,parent.ml,current.ml,parent.log,current.log}`.

Parent exit 2: `Failure "malformed scope granted journal identity"`.
Current exit 0: seven malformed scope cases refused live/journal; Int4/Float4
retain generation7/scope4; wholly absent and scope-only ownership remain unobserved.
Malformed cases: negative, null, string, fractional, above 2^53-1, duplicate,
and generation supplied without scope. Strict start/delta wiring is source-traced,
not executed by this probe. Existing registered protocol fixture extended but
not executed. Six changed OCaml files syntax-only parsing and diff check pass.

No full typecheck/build/CI/registered-fixture execution/runtime/UI screenshots,
formal GitHub approval, merge or installed-binary proof is claimed.
