# Telegram Bot API prerequisite (#24497)

Current main still represents Telegram through the Python sidecar-state adapter.
It has no Telegram continuation constructor or native HTTP sender. The iMessage
path already has both ingress and outgoing continuation. This change implements
the protocol/transport prerequisite of RFC-0384, not a disconnected continuation
variant. The next layer must integrate a polling owner, durable accepted offset,
Keeper ingress and continuation delivery, then replace the sidecar.

## Contract and implementation

The [official Bot API](https://core.telegram.org/bots/api) was read on 2026-10-24,
including Update, getUpdates, sendMessage, editMessageText and ResponseParameters.
Calling getUpdates with a higher offset confirms older updates, so the client
never invents an offset or automatically retries/acknowledges a page. Negative
offsets, which discard older queue entries, are refused before transport. The
poll owner must durably settle each update before advancing its next offset.

Telegram_rest_client sends actual JSON requests through Masc_http_client.post_sync.
It returns typed API failures with numeric retry_after and migrate_to_chat_id
instead of guessing from descriptions. It does not execute a retry itself. Raw
response bodies/descriptions/transport error strings and credential URLs are
absent from error values. The opaque token is percent-encoded as one path segment;
a direct installed-Uri probe confirmed colon/slash/query/fragment/percent encoding.
No raw credential is printed. The endpoint URL is credential-bearing and must
remain private to the transport, including injected transports.

Chat/user identities use int64, including signed large group chat IDs. Each
message retains message ID, optional topic ID, user and text/caption. Native send
uses exact topic and reply_parameters coordinates; edit names the existing chat
and message. Text is sent unchanged as plain text; formatting/chunking remains a
caller responsibility. Shared Gate_rest_json rejects duplicate keys at any depth.
Malformed pages are rejected as a whole, including duplicate/out-of-order update
IDs and conflicting known Update alternatives. Unknown additional fields/events
are tolerated. Unsupported known event payloads must still be objects.

The Telegram poll duration is sent to the API. The default HTTP deadline adds
the shared outbound allowance; like Masc_http_client, it takes effect only with
a supplied clock. Injected transports own their lifetime. No new environment
variables, runtime knobs or arbitrary polling/retry gates are introduced.

## Executed and remaining evidence

Initial [selected CI 40102571145](https://github.com/jeong-sik/masc/actions/runs/40102571145),
exact head `15851fe3331c422858572c435c4598bc3d7cdc9f`, compiled the actual Gate
library/client and ran six Root protocol groups with an injected post function.
Five passed; the error-directives group failed because its duplicate-envelope
fixture expected Invalid_response instead of the actual trusted Http_status429.
The shared JSON boundary correctly refuses that envelope before accepting any
retry directive. The fixture now checks that precise error. Subsequent code also
rejects conflicting supported/unsupported known Update fields after independent
review. Final candidate execution is recorded on the PR when available.

Source fixtures exercise the actual client entrypoints and parser through an
injected completed-HTTP boundary: request/response identities, unknown/edited
updates, structural page corruption, topic/reply/edit fields, token segment
containment, transport/HTTP/API errors and retry/migration directives. They do
not execute real network HTTP. OCaml parser and whitespace checks passed.

No local Dune build, whole project/full regression, actual Telegram API call,
installed binary, poll cursor persistence, Keeper ingress/continuation, sidecar
removal or dashboard behavior is claimed. #24497 remains open.
