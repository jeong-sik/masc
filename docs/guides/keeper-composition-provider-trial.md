# Measure selected results at the provider boundary

This experiment sends real model requests over immutable results captured by
`test_keeper_tool_plan_executor`. The producer is a fixture. The existing DAG
executor, result projection, durable artifact reader, Agent Core bridge and
OpenAI-compatible tool-result serializer run in the focused suite. The later
model run replays those observations; it never reruns the producer.

Compare the original result with the selected-export result from the **same
execution**. Keep task, model, endpoint, request options and artifact responses
fixed. Two scenarios cover a completed read and useful independent output beside
an unknown-effect failure. This measures result recovery, request body bytes and
provider-reported usage. It does not measure live Keeper preparation, async job
duration, installed behavior or the entire task improvement.

1. Request the single focused `test_keeper_tool_plan_executor` suite through the
   repository's development-check workflow. Do not build locally or watch CI.
2. At a work boundary, confirm the suite succeeded and download its
   `suite-runner-log` artifact. The console log may omit the large receipt.
   The artifact's `ci-run-tests.log` must contain exactly one
   `composition_provider_trial_corpus=` receipt. Record the run's actual head
   and run identity.
3. Choose one OpenAI-compatible endpoint/model and put provider options in a JSON
   file. For example, a supported model can use
   `{"temperature":0,"max_tokens":512,"thinking":{"type":"disabled"}}`.
   Model support must come from that provider's current documentation.
4. Run the experiment with an existing credential environment variable:

```sh
python3 scripts/benchmarks/keeper-composition/provider_trial.py \
  --corpus /tmp/composition-suite.log \
  --producer-head <actual-40-character-head> --producer-run <actual-run-id> \
  --endpoint <chat-completions-url> --model <same-model-for-both-conditions> \
  --api-key-env <existing-credential-variable> \
  --request-options /tmp/composition-model-options.json \
  --pairs 2 --max-requests 4 --timeout 60 \
  --output /tmp/composition-provider-trial
```

The explicit request ceiling and transport timeout bound this experiment, not
Keeper behavior. A ceiling reached without an answer is `unfinished`; failed
requests, wrong answers and uncaptured artifact requests remain in the samples.
No retries silently discard failures. Pair order alternates to reduce order bias.
The recorded reader responses cover default full pages at their exact captured
offsets. A model that asks for an unrecorded slice produces an explicit failed
sample, rather than a Python reconstruction of the production reader.

The output keeps the captured corpus, exact request JSON bytes, model responses,
per-request usage and one manifest updated after every attempted sample. Headers
and credentials are omitted. Its scope and expected sample count remain visible
if the run is interrupted. `first_useful_action_seconds` starts after composition
result delivery and ends at the first valid artifact read or correct final
answer. `completion_seconds` includes failed attempts. Summary latency medians
are conditional on correct answers; the adjacent attempted/correct/outcome
counts retain the denominator. Use per-sample records to report overall failures.

Large original results may already use blob markers. A smaller producer payload
therefore need not make the first request smaller. Compare the complete recovery
conversation: exact serialized request body bytes, actual artifact calls, model
round trips and complete reported usage. Wire byte counts include message/schema
JSON but exclude HTTP headers; raw result bytes and prompt tokens are different
measurements. Do not infer an end-to-end percentage from this isolated trial.
Check each condition's reported model identities as well as the requested model:
an endpoint may resolve a requested alias to another model. Mixed or missing
reported identities prevent a claim that both conditions used the same model.

For a failure-presentation comparison, select
`--baseline-projection previous_selected`. A newer corpus records the previous
`Inline_with_reference` presentation and the new structured diagnostic from the
same already executed result. The runner uses those exact captured bytes rather
than rebuilding either envelope. The original baseline remains the default.

For Z.AI, the [official Chat Completion reference](https://docs.z.ai/api-reference/llm/chat-completion)
defines request fields and usage. Supply endpoint/model/options explicitly so this
experiment introduces no provider choice or configuration knob in Keeper runtime.
