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

- `model`: the configured `[typesafeai] model` value (`jev-latest` by
  default);
- `state`: one `singleton_judgment_request`;
- `questions`: one `relevance` choice question.

`state.keeper_context` contains every field below, including the Keeper's full
instructions rather than only an identifier:

- `lane_keeper_name`, `keeper_record_id`, `keeper_runtime_uid`;
- `instructions`;
- `current_task_id`;
- `mention_keeper_ids`.

`state.items[0]` contains:

- `candidate_id`;
- `signal`, including `kind`, `post_id`, `author`, `title`, `content`,
  `hearth`, `updated_at`, `reaction`, and, for a vote signal, `vote`;
  `reaction` contains `target_type`, `target_id`, `user_id`, `emoji`, and
  `reacted`, while `vote` contains `target_kind`, `target_id`,
  `target_author`, `voter`, and `direction`;
- the complete `post`: `id`, `author`, `title`, `body`, `post_kind`,
  `visibility`, `created_at`, `updated_at`, `expires_at`, `votes_up`,
  `votes_down`, `reply_count`, `pinned`, and any present `hearth`, `thread_id`,
  `origin`, `classification_reason`, or arbitrary `meta` JSON;
- every attached `comment`, each with `id`, `post_id`, `parent_id`, `author`,
  `content`, `created_at`, `expires_at`, `votes_up`, and `votes_down`.

`questions.relevance` contains `type = choice`, an `instructions` string that
names the Keeper, and a `criteria` object with the `relevant` and
`not_relevant` labels and their descriptions.

This is the same singleton state used by the regular exact-output judgment
path. Operators should enable the integration only when sending the credential
and all Board, Keeper, and question data above to the configured endpoint is
acceptable.

### 2.3 Transparent Fallback
When opted in:
1. MASC attempts the TypeSafe AI Jev evaluation first. The request is bounded by `Masc_http_client.default_request_timeout_sec`, the deadline the other outbound clients share.
2. The kind of decision Jev picks decides what happens next. No confidence value is compared against a number; the confidence and probabilities Jev reported are written into the verdict's rationale for the record.
   - `Relevant`: the verdict is returned. The durable judgment records a typed `Vendor_system_one` source containing the configured endpoint, the model named by the System One response, and the SHA-256 of the exact serialized request body. No catalog slot or AGENT_CORE receipt is claimed.
   - `Not_relevant`: MASC runs the standard exact-output pipeline (`Exact_output.execute_flow_once` via GLM/DeepSeek) for the same candidate. A not-relevant verdict drops the post for that keeper, so it is the one Jev does not settle alone. Jev confirms only "send it to the keeper"; "don't send it" is always judged again by the LLM lane.
3. If the API call fails, times out, or the answer does not decode (including a choice the question did not offer), MASC runs the same exact-output pipeline.
4. What Jev answered is recorded on the flow's existing terminal log entry (`board_attention exact_flow.execute terminal`), whose `details` carry `candidate_id`, `outcome` and a `jev` object. `jev.answer` is one of `off`, `cli_only`, `not_pending`, `relevant`, `not_relevant`, `failed`. A decoded Jev answer also carries `jev.provenance` with the same `endpoint`, response `model`, and `request_body_sha256` written to a durable relevant judgment. After `not_relevant`, `jev.rejudged` holds the decision the LLM lane returned (`null` when the flow returned none), so an overturned Jev answer is one entry with `answer = not_relevant` and `rejudged = relevant`. The judgment record itself names the lane that ultimately answered; the terminal entry preserves the prior Jev request when the LLM lane rejudges it.

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
