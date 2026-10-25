# Cohere compatibility schema wire — issue #27869

Source base:3cce9a517b25863c00b48cfb3dd79b994ebc1044. Separate feature stack
from the provider-identity hard cut; do not treat either stack as merged.

The [official Cohere compatibility guide](https://docs.cohere.com/docs/compatibility-api)
was read on2026-10-25. Its structured-output example uses response_format
with type=json_object and a sibling schema. The existing Chat serializer
always emitted type=json_schema with an OpenAI named envelope. The retained
before-source is a source reproduction of that mismatch, not observed
provider traffic or executable baseline evidence.

A closed json_schema_dialect declaration now carries the envelope through
TOML, manifest and provider JSON parsing, ordinary/exact capability assembly,
and frozen catalog/target/plan identity. Cohere's existing capability base
selects Json_object_schema, and command-r-plus uses that base. No new model
alias or inferred provider/URL match. Missing declarations inherit the chosen
base; invalid declarations return Error. Declaring a dialect does not grant
structured-output capability.

Only Openai_chat serialization uses this dialect. Raw schemas and named
caller envelopes send the domain schema as json_object.schema. OpenAI Chat
retains its named envelope; Responses and other codecs retain their contracts.
The GLM backend shares a request builder, so both serialization and exact
fingerprints explicitly preserve its named schema under an explicit override.
Exact Chat admission fingerprints the raw schema for the new dialect.

The focused fixture captures actual loopback peer bodies for Complete sync
and SSE, raw/named input envelopes, plus provider isolation, explicit override,
strict declarations and frozen exact schema identities. Fixture definition and
source parse are not execution. No local Dune or successful candidate suite
is claimed before a completed execution is read.

No Cohere native-v2 restrictions are imposed on compatibility requests from
that other API's contract. Schema-plus-tools and forced tool behavior remain
outside this fix. The guide's example host is api.cohere.ai; the packaged
api.cohere.com URL is unchanged. Live alias equivalence and provider acceptance
remain unverified. Mistral/Kimi issue acceptance remains separate. No complete
#27869 closure, full regression, deployment or live provider result is claimed.
