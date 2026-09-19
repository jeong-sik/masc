# TypeSafe AI (System One Jev) Opt-in Integration Spec

**Date**: 2026-09-18  
**Status**: Experimental / Opt-in  
**Primary Target**: Exact-Output Lanes (`board_attention_exact`, `hitl_auto_judge`, `librarian_exact`, `verifier_exact`)

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
It activates only when `TYPESAFEAI_API_KEY` holds a non-blank value.
`MASC_TYPESAFEAI_ENABLED=false` (or `0`, `no`, `off`) turns it off even with a key;
the variable alone cannot turn it on.

### 2.2 Transparent Fallback
When opted in:
1. MASC attempts the TypeSafe AI Jev evaluation first. The request is bounded by `Masc_http_client.default_request_timeout_sec`, the deadline the other outbound clients share.
2. The kind of decision Jev picks decides what happens next. No confidence value is compared against a number; the confidence and probabilities Jev reported are written into the verdict's rationale for the record.
   - `Relevant`: the verdict is returned. The durable judgment records `source = Vendor_system_one { model }`, where `model` is the model the System One response says answered; no catalog slot or AGENT_CORE receipt is claimed.
   - `Not_relevant`: MASC runs the standard exact-output pipeline (`Exact_output.execute_flow_once` via GLM/DeepSeek) for the same candidate. A not-relevant verdict drops the post for that keeper, so it is the one Jev does not settle alone. Jev confirms only "send it to the keeper"; "don't send it" is always judged again by the LLM lane.
3. If the API call fails, times out, or the answer does not decode (including a choice the question did not offer), MASC runs the same exact-output pipeline.
4. What Jev answered is recorded on the flow's existing terminal log entry (`board_attention exact_flow.execute terminal`), whose `details` carry `candidate_id`, `outcome` and a `jev` object. `jev.answer` is one of `off`, `cli_only`, `not_pending`, `relevant`, `not_relevant`, `failed`. After `not_relevant`, `jev.rejudged` holds the decision the LLM lane returned (`null` when the flow returned none), so an overturned Jev answer is one entry with `answer = not_relevant` and `rejudged = relevant`. The judgment record itself is unchanged: it names the lane that answered, not what Jev said first.

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
