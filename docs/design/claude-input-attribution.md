# Claude input tickets and response attribution

This prerequisite adds invocation-local evidence to the official Claude Code
runtime. It preserves the existing single-shot return and process lifetime.
It does not provide a persistent receiver, post-result background delivery,
multiple-command admission, task journaling, or new TUI/Dashboard rows.

## Producer authority

The installed Claude Code 2.1.292 binary inspected for this contract has SHA256
`97a01e5bc74a199e67189435d0331ea3a24eac2e07db4b76d9148c5b0386138f`.
The coordinates below are literal file byte intervals, zero-based and
end-exclusive, not runtime addresses. The full primary audit is retained in
`/tmp/masc-claude-async-lifetime-20261008`; that local evidence directory is not
required to run the feature.

| Source | Interval | Authority |
|---|---|---|
| User input schema |184497880–184498820|Optional outer `uuid`, separate from authored content.|
| Root assistant schema |184510588–184514200|Optional `user_message_uuid` and ordered `user_message_uuids`. Child frames have another scope.|
| Result schemas |184556430–184557000;184567220–184569100|Success/error can identify consumed input groups; session-scoped failures may omit them.|
| Partial schema |184592820–184594880|Only the first non-ping partial of a typed SDK turn is stamped, independently of the first assistant; later model requests in its tool loop can be unstamped.|
| Attribution builder `yv` |217300230–217301055|Preserves consumed order, removes duplicates, caps at the provider's64 members and includes primary. A typed input's primary can remain original while later inputs join the group.|
| Host UUID selection and frame stamping |217319760–217320270;217337730–217338620|Client UUIDs supply authority. Stamping is per frame kind and primary UUID, not model message ID. A typed primary lasts the whole SDK turn; a meta turn can change primary after a witnessed queued-input fold.|
| Stdin command construction |217629661–217631075|Copies the outer input UUID; synthetic/peer inputs explicitly opt into meta handling. This runtime submits a typed non-meta input.|
| Result construction |217327680–217328090;217334600–217337050;217339110–217339600|Normal, short and error paths obtain attribution from that builder.|

## Runtime API and evidence

`Runtime_claude_input_attribution` owns the typed metadata decoder, outer user
frame constructor and invocation-local reducer. `Runtime_claude_code.run_turn`
offers a separate optional `on_input_observation` callback. Existing
`stream_event`, native task observations, `turn_result`, content reconciliation,
usage, prompt-sent callback and tool handling retain their contracts.

After admission callbacks and before writing the prompt, the host mints a
receiver-generation UUID and client-input UUID with the existing UUID facility.
Together with the exact provider session ID these form an immutable ticket.
The client UUID is serialized in the outer user frame. Original image and text
blocks pass through unchanged. The existing input `session_id="default"` SDK
sentinel remains; stdout is checked against the actual argv session ID.
A new invocation with `Resume` receives fresh generation and input IDs.

| Ticket phase | Evidence |
|---|---|
| `Prepared` | Host constructed the ticket; no transport or consumption claim.|
| `Written` | Complete JSON plus newline returned from the pipe writer. This is not provider acceptance.|
| `Write_unknown` | User-frame write raised, including cancellation. Partial delivery is possible; no rejection or automatic retry is implied.|
| `Consumed` | A valid root provider attribution group explicitly contains this input UUID. This does not prove a model request was sent or that output was displayed.|
| `Settled Provider_success/Provider_error` | A validated provider result explicitly includes the ticket. It is not host delivery or operation success: later model/body checks or callbacks can still fail.|

Each observation carries the accumulated ticket phase separately from the
current frame's attribution. A foreign group's frame can arrive after this
ticket was consumed; the retained `Consumed` fact does not make that frame
owned by this ticket. Unknown group members remain opaque observed IDs, never
new locally admitted tickets. With no callback, metadata is not accumulated;
the UUID-bearing user frame remains identical.

## Response identity and rejection

A valid optional group retains its primary and full ordered members. Primary
membership, not equality with the last member, is required. Singular fallback
is available only when the plural field is absent. A malformed, empty,
duplicate, oversized or contradictory plural is rejected without fallback.
No text, timestamp, identifier prefix, request ordering or latest ticket is
used for ownership.

Root partial `message_start` creates a response occurrence. Later unstamped
partial frames inherit only that occurrence's witnessed attribution. An
explicit updated group replaces its attribution; this is a normal meta/fold
case, not a conflicting reuse. A partial stop closes that cursor. Complete
assistant envelopes can inherit through the exact provider message ID only
while it identifies one witnessed partial occurrence. Reusing that ID makes
response-occurrence selection ambiguous. A fresh complete assistant can still
carry the independently available typed-command proof: it names that command,
not either occurrence sharing the model ID. While the command is open, absence
of that proof leaves this response-ID route rejected as ambiguous. An ended
command continues to leave unstamped frames unattributed. The new partial occurrence can carry its own explicit group. Without that response witness, a root envelope
can instead use the independently witnessed typed-command authority below. Before either witness, and
for every result, an absent stamp stays unattributed.

Same-UUID metadata replays emit no duplicate observation; changed frame kind
or attribution is rejected. The content parser moves its message cursor on a
replayed start. An immediate same-occurrence start replay preserves inheritance,
but replaying an old start after another/closed response retires the cursor
and marks that message ID ambiguous. An exact historical stop is different:
it is a content-parser no-op already associated with its original occurrence,
so its replay preserves the current response's valid inherited group. Fresh,
missing-identity and conflicting stop boundaries still retire inheritance;
a stop without an owned cursor cannot adopt a response. Rejected local partial
starts retire the prior cursor, and missing/conflicting fragment identity invalidates inheritance until another
explicit stamp. Rejections never retract already witnessed ticket facts.
Foreign sessions cannot poison local state. The runtime observes only root
partial/assistant frames after its existing parsing and session checks; child
and unscoped partial metadata cannot consume the root ticket. Their parsed
message starts retire the prior root inheritance cursor rather than letting an
unstamped later fragment adopt its group. Global strict JSON duplicate rejection remains in force. Malformed optional attribution in
an otherwise admitted frame is an observation rejection, preserving the
existing single-shot body and completion behavior.

The registry lives only as long as this invocation; there is no time expiry.
It is not a durable task owner or a general receiver registry. A future
persistent receiver must join every result to these explicit groups and keep
native task owners bound to their original invocation. This patch deliberately
leaves the current first-result return path intact.

## Typed command authority across model requests

A typed SDK turn can call tools and issue multiple model requests. Its primary
UUID is stamped only on its first root assistant and first non-ping partial,
not again for each model message ID. The reducer separately tracks
`Awaiting_witness`, `Witnessed`, `Suspended` and `Ended` command authority.

Only a fresh validated root explicit stamp whose primary equals the host's
client UUID, after a confirmed complete input write, establishes this command.
`Write_unknown` and later consumption evidence do not fabricate that write
fact. A group with another primary may explicitly include this ticket and
prove its consumption or settlement; that fact alone cannot establish the
stronger assertion that this is its own typed command.

Within the witnessed command, later unstamped root model starts and complete
assistant/native tool envelopes carry `Command_inherited {group; stamp_uuid}`.
This remains distinct from a direct `Explicit` stamp and from `Inherited`
through a known response occurrence. It preserves the actual group snapshot
and the exact witnessing envelope UUID. Provider group membership can grow
without another partial stamp; no unobserved members are invented and older
observations are not retroactively expanded.

A model stop closes only its response cursor. It does not end the SDK command.
A root result in this validated session ends command inheritance regardless
of optional attribution, including a rejected result identity. Results never
inherit; only their own valid explicit group settles a ticket. Later metadata
cannot reopen an ended command. The existing single-shot runtime still returns
its first result and does not become a multi-input receiver.

Malformed, contradictory or foreign-primary root evidence suspends command
fallback. Exact replay cannot reseed it; a fresh matching explicit witness is
needed. A response whose association came from command inheritance cannot
bypass that suspension. Child frames do not establish root command ownership. An invalid or
stale body-response cursor is tracked separately as uncertain: a renewed
command stamp alone cannot hide that uncertainty. A fresh valid response start
is needed before command fallback can attach to that response again. Existing
response-local observations retain their exact original evidence rather than
being relabelled as whichever command was seen most recently.

The assistant input observation is emitted after strict root parsing and before
its native call callbacks. A future task hook can join a registered owner's
exact `call_envelope_uuid` to that observation. This patch does not implement
that hook, persist task ownership or keep the provider alive after the result.

## Verification boundaries

- `test_runtime_claude_input_attribution` exercises the complete actual pure
  module: outer envelope/content preservation, write facts, group changes,
  membership settlement, malformed64-member boundary, replay, reused message
  IDs, old start/stop replay after a newer response, quarantine after rejected
  identity, foreign session and unknown result; plus whole-command ownership
  over multiple model IDs, complete-only envelopes, group snapshot preservation,
  foreign-primary membership, unknown writes, suspension/replay and result end;
  reused model IDs with valid command proof and absent/suspended/uncertain/ended
  controls.
- `test_runtime_claude_code` adds real fake-CLI stdin assertions. The fixture
  parses the serialized outer UUID and uses that value in actual SDK metadata;
  a prompt echo or independently invented UUID cannot satisfy the assertions.
  Cases cover fresh resume tickets, partial/complete association, absent result,
  legal folded groups, malformed metadata, child/foreign groups, success/error,
  crossed UUID identities and unchanged strict JSON/session admission. A
  Native_full tool-loop fixture observes the second unstamped model's Agent
  envelope before its native-start callback, then child tools and a complete-only
  root reply, with own/absent/foreign-primary/malformed initial-stamp controls.
  A native-only Read→Agent case reuses a model ID under fresh envelope UUIDs,
  verifying command attribution without relying on text-index reconciliation;
  absent and foreign-primary controls remain unowned.
- The new helper is in the existing `masc.runtime` library. Its focused stanza
  declares `masc.runtime`, `yojson` and `alcotest`; the CLI suite adds its direct
  runtime dependency. No provider/task callback consumer needs a new variant.

Local evidence for this unit is limited to source parsing and execution of the
complete pure helper/test module through the OCaml interpreter. The fake-CLI
runtime suite, whole-runtime typecheck, provider, PTY, screenshots and CI have
not been executed for this change. The isolated pure check seals the complete
actual helper implementation with its complete actual `.mli`. No async delivery or screen outcome is
claimed from those pure checks.
