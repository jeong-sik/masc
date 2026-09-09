# Configured runtime token sampling

`masc runtime-token-sample` runs an explicit, tool-free conversation through
MASC's existing Agent Core runtime executor. It reads one immutable runtime.toml
observation and emits its revision before executing. Provider credentials,
inference settings, model capabilities and transport come from the existing
runtime resolver. It does not modify runtime.toml or create Keepers.

After installing a build containing this command:

```sh
masc runtime-token-sample --base-path "$MASC_BASE_PATH" \
  --runtime 'glm-coding.glm-5.3' \
  --runtime 'kimi_coding.kimi-for-coding' \
  --scenario docs/examples/runtime-token-sample.json > sample.jsonl
```

Set the base path to your existing MASC installation. The IDs above are examples
from the operator's configured catalog, not defaults: choose exact enabled IDs
from your runtime configuration. This command makes live model calls. The JSONL
contains the full scenario, prompts and visible answers; choose the destination
and scenario accordingly. The example is a continuity smoke scenario, not a
representative cache benchmark or an automatic correctness judge.

Every runtime gets its own fresh conversation, with identical system prompt and
user prompts. Assistant blocks and provider reasoning provenance are retained
through `assistant_message_of_response`; text rendering is only for the report.
A failed or incomplete turn stops that conversation. Independent runtimes still
run. CLI transports report `not_supported` because this sampler implements Agent
Core conversations, not native CLI session lifecycle; that is a sampler
limitation, not evidence that the provider cannot run the scenario. Any failed
or unsupported runtime gives process exit status 1.

The manifest is followed by `started`, `response`, and a final `completed` or
`failed` row for each admitted conversation. Unsupported targets have their own
row. A missing terminal row means an interrupted measurement, not success.
The response includes the upstream response ID, actual response model, stop
reason, normalized usage, telemetry and visible output. The sample index, runtime ID and turn
index correlate the rows, including repeated requests for the same runtime. There is no heuristic output judging or automatic
model substitution.

`usage` and `telemetry` use the existing Agent Core codecs. Missing whole usage
or telemetry objects remain null. **Individual cache counters inside a present
usage object may already be zero-filled by provider adapters.** These are
normalized counters, not proof that every cache field was reported on the wire.
No cache-hit ratio or token saving is inferred from them. Lower-level retries,
failed partial streams and provider-internal actions are not an exhaustive cost
ledger here. Use attempt-ledger evidence separately.

Validation status: source inspection only; no local build, live provider sample
or installed-command verification has been performed. Compare the same scenario
on named source/build revisions before making an optimization claim.
