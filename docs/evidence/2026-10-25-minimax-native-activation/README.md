# Native MiniMax production catalog activation — 2026-10-25

Issue #27924. Candidate base: `c75ee3febdb834225ff905020add4cecd2e5264b`.
The original scalar carrier repair #45772 is already merged: PR head
`d226f348da8b7ff3da6132c29828aa41dc926d96`, squash merge
`3c5fe0c329d9b631de1ba87cb6834e97dbb0858d`.

## Actual missing boundary

The existing native replay fixture injects a model capability override. The
normal `Provider_config.capabilities_for_config_model` request policy lookup
has no native MiniMax scoped rows or provider entry. An explicitly declared
MiniMax provider cannot borrow unowned bare rows. Thus the passing fixture
cannot establish automatic production activation of the inline carrier.
Scoped model rows use exact normalized IDs, not prefix lookup.

Add a native OpenAI-compatible MiniMax identity plus explicit exact rows for
M2, M2.1/M2.5/M2.7 and each documented highspeed variant, M3 and M3.1-Flash.
The existing replay fixture now constructs the ordinary provider config with
no override and exercises each row through sync/SSE parsing, cache/canonical
history and request serialization. It retains complete inline scalar bytes,
independent reasoning, tools, later human turns and tool-free blank carriers,
while excluding incompatible-source raw replay. Hosted Ollama M2.7/M3 retain
their separate declared policy. No catalog resolution algorithm is changed.

## Primary contract

Read on 2026-10-25:

- https://platform.minimax.io/docs/api-reference/text-openai-api
- https://platform.minimax.io/docs/guides/text-m3-function-call

The SDK contract names complete inline content preservation for these model
families. The tool guide also requires complete responses on turns without
thinking. M3.1-Flash always thinks and rejects a disabled switch; it does not
inherit M3's optional disable control. M2 also has no effective off switch.
Only M3/M3.1 receive the documented reasoning_split request field. M2 context
windows and prices are left unknown, and M3/M3.1 use the documented 1M context.
Tool-choice and schema flags retain the existing native M3 conservative field
policy; these rows do not establish API acceptance or rejection. M3.1 effort
control is not added by this replay repair. Anthropic wire, provider Responses
support and live HTTP are separate contracts and remain unverified.

## Validation

[Baseline run 40118308754](https://github.com/jeong-sik/masc/actions/runs/40118308754)
checked out exactly the candidate base and passed backend codec64, provider
reasoning replay57, structured stream6 and types60: 187 actual cases. The
existing native codec case still injects capabilities there. This baseline
result does not certify the new automatic activation/family matrix.

The changed fixture parses and the TOML parses; whitespace checks pass. A
focused execution of the changed backend codec remains required. No local Dune,
provider HTTP, installation, complete checkpoint resume, full regression or
issue closure is claimed.

## Structured replay correction from adversarial review

The expanded M2 fixture exposed a separate source boundary: the serializer
used the optional output-format request switch to decide whether already
returned reasoning_details could replay. M2 intentionally sends no unverified
reasoning_split switch, so this dropped its structured artifact. The renderer
and its blank-message predicate now share a typed decision: a declared
Delta_field_and_details response carrier replays details independently of the
request switch; other carriers retain their existing Reasoning_split rule.
Source compatibility and replay-policy projection still run first. New
sync/SSE tool-free opaque-details cases verify that the assistant row itself
survives without visible text, tool calls or textual reasoning. No switch is
added just to satisfy the fixture.

Codec-only run40119116449 was requested before this serializer correction at
source 7a88cf1e8d99fd160fc3819ea7a5dbab032bdc68; its result was not observed
when this update was authored. It cannot certify the subsequent correction.
The changed serializer and fixture require the focused codec/reasoning replay
checks at the corrected candidate. No exact corrected-candidate PASS yet.

## Current strict-catalog integration

Review response prepared from original PR head
`908134915142e40765eee1b70c64236cbcc9d2ea` on main
`88619fd00748bce2e053a00b77f4643c9545e43a`. Git replayed the PR cleanly,
but the combined catalog retained nine new `id_prefix` rows. The current
`Model_catalog` requires exact `model_id` and rejects unknown keys; any one
of those rows prevents loading the complete embedded catalog. The new provider
also retained `identity_hosts`, removed by the current strict provider contract.

The nine declarations now use `model_id` with the same identifier bytes and
`provider_name = "minimax"`. The retired provider metadata is removed while
its declared endpoint, path, authentication and capability base remain. No
parser admission is weakened. All other decoded TOML values and row order are
identical to the cleanly rebased input. Native MiniMax, bare model and hosted
Ollama declarations remain separate; original serializer and replay fixtures
are unchanged.

Python TOML parsing and validation against both current production key lists
found nine missing model identities and one unknown provider field before the
repair, and no such errors afterwards. All 244 model rows and 27 provider rows
were checked, including uniqueness of provider-scoped exact model identities.
The two changed OCaml source/fixture files parse; fragment and whitespace
checks pass. These checks do not execute the complete OCaml catalog parser,
codec/replay tests, provider HTTP, CI or an installed runtime. Earlier baseline
and authored source receipts retain their original heads and are not current
candidate execution evidence.
