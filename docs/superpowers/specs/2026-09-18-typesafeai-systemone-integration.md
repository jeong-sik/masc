# TypeSafe AI (System One Jev) Opt-in Integration Spec

**Date**: 2026-09-18  
**Status**: Experimental / Opt-in  
**Primary Target**: `board_attention_exact`

---

## 1. Overview & Motivation

Large Language Models (LLMs) are autoregressive text generators trained for conversational human preference (RLHF/RLVR). Using them inside automated software backends to make closed-set decisions requires coercing free-form text into JSON and parsing it back, leading to:
- **Thinking Token Budget Drain**: Models spending their entire token budget on reasoning traces and returning empty content.
- **Provider Capability Fragmentation**: Inconsistent support for structured outputs (`response_format: json_schema` vs `json_object` vs text-only), leading to runtime incidents.
- **Latency & Cost Overhead**: Autoregressive decoding incurring 1–5s latency and high token prices.

**TypeSafe AI (`typesafe.ai`)** introduces **Jev**, a **System One** decision model trained via **RLCD (Reinforcement Learning for Calibrated Decisions)**:
- Returns typed, mathematically schema-bound decisions (Enum, float, probability distributions) directly without text generation.
- Ultra-low latency: **70–500ms** (parallel logit sampler).
- Cost: **$0.042 / million input tokens**, with **free output tokens**.
- Output primitives:
  - `Choice`: Selection from a discrete option set + confidence + probability distribution.
  - `Score`: Continuous rating along a defined rubric + confidence.
  - `Noul`: Calibrated true/false probability (0.0 to 1.0).

This specification defines the opt-in integration of TypeSafe AI Jev into MASC's exact-output decision paths under the `typesafeai` namespace.

---

## 2. Architecture & Opt-in Contract

### 2.1 Opt-in Invariant
By default, TypeSafe AI is **completely inert and disabled**.
It activates only when `TYPESAFEAI_API_KEY` holds a non-blank value. The key
is the one thing read from the environment; everything else about the lane is
the `[typesafeai]` table of runtime.toml (`Runtime_schema.typesafeai`, read
strictly: a misspelt key is a load error). `enabled = false` turns the lane off
even with a key; the table alone cannot turn it on.

Since RFC-librarian-absorb-gate (2026-09-21) two gates share the lane, each with
its own switch in that table: `board_attention` (this spec's Board attention
judgment, on by default, which is what the lane alone meant) and `absorb_gate`
(the librarian absorb gate, **off by default**: it sends the librarian's
memories to the vendor, which a deployment that set its key for this spec's
gate did not choose). `excluded_keepers` names keepers that neither gate ever
asks the vendor about: both gates reach the same endpoint, so one list answers
for both (this spec's gate sends the post and the keeper's context). A name
that is no keeper of the base path is reported at boot. A key turns the lane
on; the Board gate is turned off by name, the absorb gate is turned on by
name.

### 2.2 Data sent outside the MASC instance

Opting in sends an HTTP POST to the configured TypeSafe AI endpoint (default:
`https://api.typesafe.ai/v1/systemone`). The request carries these headers:

- `Authorization: Bearer <TYPESAFEAI_API_KEY>` — the configured credential is
  sent to that endpoint;
- `Content-Type: application/json` and `Accept: application/json`.

The JSON body has exactly three top-level fields:

- `model`: the `model` of the `[typesafeai] destinations` entry being asked
  (`jev-latest` for the default destination);
- `state`: `{ "signal": ... }`, the current signal only;
- `questions`: one `relevance` choice question.

`state.signal` contains `kind`, `post_id`, typed `comment_id`/`parent_id`,
`author`, `title`, `content`, `hearth`, `updated_at`, `reaction`, and, for a
vote signal, `vote`. `reaction` contains `target_type`, `target_id`,
`user_id`, `emoji`, and `reacted`, while `vote` contains `target_kind`,
`target_id`, `target_author`, `voter`, and `direction`. The post and comment
snapshot is not sent.

`questions.relevance` contains `type = choice`, an `instructions` string that
names the Keeper and lists its normalized `board_interests`, and a `criteria`
object with the `relevant`, `not_relevant` and `uncertain` labels and their
descriptions. Keeper instructions, record/runtime/task identity, and mention
lists are not sent.

The Keeper is named in the question rather than in the state. With the
Keeper's role in the state (the exact-output lane's
`singleton_judgment_request`), Jev answered relevant far more often; on
2026-10-01 a blind judge reading the production rule sided with the
question-only shape in 23 of the 26 cases where the two shapes disagreed.
The same shape lets one request carry one question per Keeper for the same
signal. Operators should enable the integration only when sending the
credential and the Board signal and Keeper interests above to the configured
endpoint is acceptable.

### 2.3 Transparent Fallback
When opted in:
1. MASC attempts the TypeSafe AI Jev evaluation first. The request is bounded by `Masc_http_client.default_request_timeout_sec`, the deadline the other outbound clients share.
2. Jev's decision and its confidence decide what happens next. The confidence and probabilities Jev reported are also written into the verdict's rationale for the record.
   - `Relevant` or `Not_relevant` with confidence at or above `[typesafeai] board_attention_confidence_floor` (default 0.3, `Runtime_schema.default_typesafeai`): the verdict is returned. The durable judgment records a typed `Vendor_system_one` source containing the configured endpoint, the model named by the System One response, and the SHA-256 of the exact serialized request body. No catalog slot or AGENT_CORE receipt is claimed.
   - Either decision below the floor, or an explicit `uncertain` answer: MASC runs the standard exact-output pipeline (`Exact_output.execute_flow_once`) for the same candidate. The floor follows TypeSafe's confidence-gated routing (https://docs.typesafe.ai/confidence.md); the comment on `default_typesafeai` records the measurement the default was set from.
3. If the API call fails, times out, or the answer does not decode (including a choice the question did not offer), MASC runs the same exact-output pipeline.
4. What Jev answered is recorded on the flow's existing terminal log entry (`board_attention exact_flow.execute terminal`), whose `details` carry `candidate_id`, `outcome` and a `jev` object. `jev.answer` is one of `off`, `cli_only`, `not_pending`, `relevant`, `not_relevant`, `low_confidence`, `uncertain`, `failed`. A decoded Jev answer also carries `jev.provenance` with the same `endpoint`, response `model`, and `request_body_sha256` written to a durable Jev judgment. After `low_confidence`, the entry also carries Jev's `decision`, `rationale` and `confidence`, and `jev.rejudged` holds the decision the LLM lane returned (`null` when the flow returned none), so an overturned Jev answer is one entry whose `decision` and `rejudged` differ. The judgment record itself names the lane that ultimately answered.

---

## 3. Modules Added

- `lib/typesafeai/typesafeai_types.mli` / `.ml`: System One primitives (`Choice`, `Score`, `Noul`), payload builders, and response parsers.
- `lib/typesafeai/typesafeai_config.mli` / `.ml`: Opt-in resolution and configuration defaults.
- `lib/typesafeai/typesafeai_client.mli` / `.ml`: Outbound HTTP client over `Masc_http_client.post_sync`.
- `lib/typesafeai/typesafeai_board_attention.mli` / `.ml`: Board attention candidate relevance judgment adapter.

---

## 4. Operational Invariants

1. **Closed Sum Types**: The relevance question offers every constructor of the `Keeper_board_attention_judgment.decision` variant (`all_of_decision`, derived by `ppx_enumerate`), under the labels `decision_to_string` gives the LLM lane, through one `Typesafeai_types.choice_set`. `choice_set` rejects an empty option list and shared labels. The request's criteria and the decoding of the answer are both built from that set, and a choice or probability key outside it decodes to `Error`.
2. **Deterministic Fallback**: Failure of the external TypeSafe AI endpoint never crashes the worker; the terminal entry records `jev.answer = failed` with the reason, and the configured exact catalog slots judge the candidate.
3. **Zero Blast Radius**: Existing tests and pipelines without `TYPESAFEAI_API_KEY` continue to run completely unaffected.
