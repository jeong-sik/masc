# Tool first-call validity

`first_call_validity.py` measures how often a model's first call to one tool
is a call masc accepts. It sends one tool definition and one situation to a
model, takes the first tool call, and checks it against the tool's schema and,
for tools listed in `TOOL_RULES`, the rules the handler checks afterwards.

Use it before and after changing a tool definition. Changes include a
parameter, a description, or an example. Compare the rates the two runs
print.

## Run

```sh
# Baseline: the masc_ask definition masc actually sent in the newest captured request.
python3 scripts/harness/tool_calls/first_call_validity.py \
  --masc-dir ~/me/.masc \
  --from-wire-capture masc_ask \
  --scenarios scripts/harness/tool_calls/masc_ask.scenarios.json \
  --lanes glm-coding.glm-5.3-flash,kimi_coding.kimi-k3 \
  --reps 5 --out /tmp/masc_ask.jsonl

# Candidate: an edited definition, same scenarios, same lanes, same output file.
python3 scripts/harness/tool_calls/first_call_validity.py \
  --masc-dir ~/me/.masc --tool-json /tmp/masc_ask.candidate.json --variant-name candidate \
  --scenarios scripts/harness/tool_calls/masc_ask.scenarios.json \
  --lanes glm-coding.glm-5.3-flash,kimi_coding.kimi-k3 \
  --reps 5 --out /tmp/masc_ask.jsonl

python3 scripts/harness/tool_calls/first_call_validity.py --summary-only --out /tmp/masc_ask.jsonl
```

- A lane is a `<provider>.<model>` name from the workspace's `runtime.toml`.
  The endpoint, the API model name, the credential variable and
  `max-concurrent` are read from there.
- Only `openai-compatible-http` providers with `env` credentials can be
  called. The subscription CLIs (Claude Code, Codex, Antigravity) put their
  own wrapper around each tool, so this harness cannot measure them.
- `--prior-call masc_ask.prior_call.json` puts one earlier call of the old
  shape into the conversation. Use it to measure whether models follow a
  changed schema or copy their history.
- Rate limits and timeouts are recorded as `transport_error` and left out of
  every rate.

## What it does not show

- The harness sends a short system prompt and one tool. A Keeper request holds
  its full prompt, memory, and every other tool, so production rates can be
  lower than these. Use the numbers to compare one definition with another,
  not as a forecast of production.
- The request carries the model's `temperature` from `runtime.toml`, but not
  masc's thinking or reasoning-effort controls. The provider's defaults apply
  to those.
- `TOOL_RULES["masc_ask"]` copies the checks in `lib/keeper/keeper_ask.ml`.
  Update it when those checks change.
