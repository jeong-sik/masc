# Ask typed questions with `masc_decide`

`masc_decide` is an experimental, explicitly invoked operator MCP tool. It sends
shared state text and named questions to an Ollama System One decision model.
It is not exposed in a Keeper's per-turn model tool list and does not
automatically decide approvals. Confidence
describes distribution concentration, not the correctness of an answer.

## Prepare a backend

For the default local backend, start Ollama v0.35.0 or later and run:

```sh
ollama pull nimble
```

MASC calls `http://127.0.0.1:11434/v1/systemone` from the process executing the
tool. The Ollama service and a System One model must be reachable there.
Local requests do not need an API key.

For `"backend": "cloud"`, set `OLLAMA_CLOUD_API_KEY` in that process's
environment before starting it. MASC calls `https://ollama.com/v1/systemone`
directly, using `clef:cloud` by default. This backend needs an Ollama account
with a paid plan or usage credits and spends those credits. It does not need
a local Ollama service. Routing a `:cloud` model through the local backend
instead requires Ollama v0.40.5 or later and a signed-in Ollama service.

These prerequisites follow Ollama's [API reference](https://docs.ollama.com/api/systemone)
and [decision guide](https://docs.ollama.com/capabilities/decision), checked
2026-10-19. Model support and pricing can change.

## Call the tool

Send this MCP `tools/call` request through your connected client:

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "tools/call",
  "params": {
    "name": "masc_decide",
    "arguments": {
      "backend": "local",
      "state": "Checkout returns HTTP 500; payments were not captured.",
      "questions": {
        "team": {
          "type": "choice",
          "instructions": "Which team should investigate?",
          "criteria": {"billing": "Payments and refunds", "technical": "Software errors"}
        },
        "outage": {"type": "noul", "instructions": "Is checkout unavailable?"},
        "urgency": {
          "type": "score",
          "instructions": "How urgently should this be investigated?",
          "criteria": ["Routine", "Soon", "Immediate"]
        }
      }
    }
  }
}
```

`state` is nonblank text, including JSON serialized as text. Each question
needs nonblank `instructions`. Question names contain 1–100 ASCII letters,
digits, `_`, `.` or `-`; a call accepts 1–64 questions. Choice accepts 2–255
named options, subject to the selected model's own limit. Descriptions are
strings or `null`. Noul permits omitted/null `criteria`, or an object with
optional `true`/`false` string or null descriptions. Score accepts 2–10
nonempty descriptions in increasing order. `model` overrides the backend's
default model; `timeout_sec` accepts 1–120 seconds and defaults to 60.

Successful tool data contains `result.answers`, keyed by the original question
names, plus backend, model and usage. Choice includes the selected key and
each requested key's probability. Noul is a probability between zero and one.
Score is on the zero-based rubric scale; the tool normalizes Ollama's indexed
legend and probabilities objects into arrays in the original rubric order.
Malformed criteria fail before a network call. Responses with unasked/missing
options, a changed rubric, nonfinite numbers or out-of-range probabilities
fail instead of becoming a successful decision. Rounded probabilities do not
have to sum to exactly one.

## Diagnose failures and stop use

- Connection failures: check the Ollama service from the tool process's machine.
- HTTP 404: check Ollama's version and whether the decision model is installed.
- Missing cloud key or HTTP 401/402: check the process credential and account
  access/credits.
- HTTP 400/413: check the question schema, model support and input size against
  the API reference. MASC does not truncate the submitted state.
- Response-contract errors: retain the error and correct the model/server
  mismatch; an invalid answer is not a usable judgement.

There is no feature-specific global enable switch. Stop exposing or calling
`masc_decide` in the operator MCP client to stop its use. No request is made
merely by listing the tool. Its descriptor is operator-only, so Keepers do not
receive it in their per-turn model surface. Do not add it to `keeper.tools.deny`:
that setting accepts model-visible tool names, and this entry would reject
the Keeper profile rather than disable the MCP tool.
