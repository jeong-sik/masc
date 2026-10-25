# Responses sync full reasoning and declared replay

Relates #27924 and #45932. Source base
`e486ded8e4adf19f58339a3b3d4f7558d82ba77b`.
Official schema comparison: [#45926](https://github.com/jeong-sik/masc/pull/45926).

## Actual baseline

[Run40191650121](https://github.com/jeong-sik/masc/actions/runs/40191650121)
checked out exactly `0b49be0d9296bfdd3eb9c9887a0f19edf712ebb9`, built the
new regression-only executable and ran six cases. Four failed, two passed.
The full-content, full-over-summary and multiple-reasoning parser assertions
failed, reproducing the production omission. Later history/replay assertions in
those cases were not reached. Summary-control failed for a different reason:
the fixture expected plaintext replay under OpenAI's declared opaque-only
policy. Existing opaque and blank-full/summary parse controls passed.
The excerpt preserves the raw-log digest. No failed case is relabeled PASS.

## Correction and current source

A private typed decoder selects nonblank encrypted object first, then nonblank
full content/reasoning_text in wire order, then the existing summary. It does
not concatenate full reasoning with its condensed summary. Known malformed
full-text parts or a malformed content carrier fail; unknown part types remain
extensions. Sync consumes this decoder and preserves native grouping.

The request projector already serializes Thinking as summary_text, but its
supported-carrier predicate allowed only opaque reasoning. It now accepts
Thinking under an admitting declared policy. Policy and source identity checks
still run first. In particular, OpenAI Provider_opaque_state still excludes
plaintext and preserves its opaque objects. No provider/model-name checks or shipped catalog activation are added.

The first corrected run40191951639 at a3a failed compilation before the suites:
extraction left an unused non_blank_json_string helper (warning32 is fatal).
The helper is removed. Separately, source review found that the transport still
unconditionally replaced an explicit generic preserve-always declaration with
opaque-only. That policy failure was not executed in this run. The corrected contract
adds a Responses-only member to the existing typed replay capability vocabulary:
`preserve_responses_text`. Only this declaration admits plaintext on Responses;
ordinary Chat preserve-always cannot enable it. Stable response stamping and
request-local projection consume the same final transport rule. Other protocols
keep their defaults, including Ollama and the embedding runtime's Anthropic
history rule. Dashboard declaration serialization covers the new member.
No shipped catalog row opts in, and no MiniMax activation is claimed.

Fifteen current cases use an explicitly synthetic plaintext replay declaration
for plaintext round-trips, plus actual default OpenAI opaque-policy control.
Additional public cases verify producer/request contract identity, the manifest
vocabulary, other-protocol defaults and nonactivation from a Chat override.
This override does not certify production MiniMax Responses binding. Source
telemetry, response cache JSON, assistant conversion and the actual Checkpoint
message codec are used. Canonical message bytes are written to/read from an
actual temporary file before requesting replay alongside tool output and a
later user message. This is not whole-Agent checkpoint/resume or process restart.
The later-user assertion was also corrected to the actual input_text parts
array; its old string assertion was unreached in the failed baseline.

## Validation boundary

Changed OCaml parses, fragment and whitespace pass. A corrected run of the
new suite plus existing backend codec, phase-replay and capability suites is requested
separately. Execution at the corrected source has not yet been observed here.
`source-sha256.json` binds the candidate implementation/fixture, not a new
execution receipt. No local Dune/typecheck/full build or full regression.

SSE is the next distinct layer: summary and full-text deltas need separate
provenance before reconciling authoritative item-done/terminal snapshots.
Encrypted replacement, repeated snapshots, multiple items and conflicting
terminal data need joined conformance. This sync repair does not establish
SSE parity, MiniMax HTTP acceptance, native binding, installation/live runtime,
whole issue completion or formal merge approval.
