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
