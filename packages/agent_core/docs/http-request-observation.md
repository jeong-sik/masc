# Observe native HTTP POST attempts

`Llm_provider.Http_request_observer` is an explicit caller-owned, fiber-local
metadata channel around the native synchronous, one-dispatch synchronous and
streaming POST clients. An unbound client does not hash or record its body.
No environment setting, observer registry service or runtime admission rule is
added. A scope captures each call's owner once; concurrent and nested bindings
do not move an in-flight call's later facts to a different observer.
An already running actor does not inherit the submitting fiber's bindings.
Use `capture` before handing over its work closure; invoking that closure
rebinds the captured owner on the receiving fiber. The Keeper heartbeat carries
this context across its existing Owner handoff. It does not change admission,
queue ordering or dispatch. An unbound handoff retains its original closure.

Each observed call has one owner-local identity and distinct facts:

| Fact | Meaning |
|---|---|
| `Client_entered` | Actual serialized body byte count and SHA256 supplied to this client |
| `Dispatch_entered` | The connection exists and the client is entering its concrete POST call |
| `Response_headers_received` | Actual HTTP status and response headers have arrived |
| `Client_finished` | The client returned a typed result, raised, or was cancelled |

Native completion serialization also binds optional Tool inventory metadata to
the exact body digest. The HTTP entry retains it only when that digest matches
its actual body, so a nested request with different bytes cannot inherit the
outer request's Tools. Unbound clients neither parse Tools nor invoke the lazy
inventory producer. A producer's ordinary exception leaves the inventory
unavailable without rewriting the HTTP result; reserved exceptions propagate.

The metadata distinguishes an absent `tools` member, a present array (including
an empty one), unavailable metadata and an unobserved producer. For a present
array it records top-level wire-entry count and the size/SHA256 of its compact
Yojson re-encoding, preserving array and object order. This is a defined wire
representation, not semantic JSON canonicalization. A Gemini wrapper is one
wire entry even when it contains several function declarations. Schema content
never crosses the observer API. Both sync and streaming completion paths bind
their final serialized body; transport-only calls make no Tool inventory claim.

`with_request_metadata` also carries structural attribution of the exact JSON
body. For each top-level member, in original occurrence order, the event retains
its name, encoded key/colon/value byte count, value byte count and value SHA256.
It never exposes the value. The object's braces and commas have a separate
`framing_bytes` count; these bytes plus every member's `wire_bytes` account for
the full submitted body. Duplicate names remain separate occurrences.

The serializer produces this decomposition only when compact Yojson re-encoding
matches the final body byte-for-byte. Non-object, unparseable or non-matching
bodies retain `Components_unavailable`, not an estimated decomposition. A missing
exact-body binding remains unobserved. Ordinary metadata producer failure leaves
both components and Tool inventory unavailable and does not rewrite HTTP results.
No metadata producer runs for an unbound observer.

This allows a consumer to compare the actual `messages`, `input`, `contents`,
`system`, `tools` and configuration members without guessing from checkpoint
size. These are protocol field names, not cross-provider semantic categories:
OpenAI system messages may be inside `messages`, while other codecs have a
separate system field. Equal digests across calls prove unchanged value encoding;
they do not prove that a field is redundant or may be omitted. The current path
does not change prompts, context reuse, request construction or retry policy.

The interface contains no URL, headers, credentials, prompt, Tool arguments or
response content. A submitted body is not a count of peer-acknowledged network
bytes. A returned `Ok` is a client result, not a provider/parser/business-success
verdict. For example, the synchronous raw client may return an HTTP refusal as
its raw response, while the streaming client returns that refusal as an error.
Only the producer of each fact determines that phase; an assistant block count,
last usage report or histogram is not a physical request counter.

The distinction between send attempts, status and operation outcome follows the
measurement concerns in the [OpenTelemetry HTTP client span guidance](https://opentelemetry.io/docs/specs/semconv/http/http-spans/#http-client-span).
This channel does not emit spans or claim OpenTelemetry conformance.

Callbacks acknowledge delivery with `Ok ()` or `Error ()`. A rejected delivery or
ordinary callback exception increments the observer's delivery failure count
without rewriting the HTTP result. Reserved exceptions, including cancellation,
propagate. Consumers must retain unknown totals when coverage is unavailable or
a call has missing or contradictory phases. This diagnostic state is not a
retry or execution decision.

The preparation driver binds one observer around its actual owned cycle. Its
separate metadata journal and receipt retain submitted sizes, dispatch entries,
header receipts and client returns, including HTTP refusals. Actual peer-body
size/hash comparison and concurrent/nested ownership scenarios require executed
verification at the candidate head. The driver's first inventory comes from the
first actual dispatch, never the last-turn snapshot. Missing or incomplete
evidence remains unknown. The API alone establishes no timing savings,
response-reported model identity or installation.
