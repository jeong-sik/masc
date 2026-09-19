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
   - `Not_relevant`: MASC logs `board_attention_typesafeai_not_relevant_rejudged` with Jev's rationale and runs the standard exact-output pipeline (`Exact_output.execute_flow_once` via GLM/DeepSeek) for the same candidate. A not-relevant verdict drops the post for that keeper, so it is the one Jev does not settle alone.
3. If the API call fails, times out, or the answer does not decode (including a choice the question did not offer), MASC logs `board_attention_typesafeai_fallback` and runs the same exact-output pipeline.

---

## 3. Modules Added

- `lib/typesafeai/typesafeai_types.mli` / `.ml`: System One primitives (`Choice`, `Score`, `Noul`), payload builders, and response parsers.
- `lib/typesafeai/typesafeai_config.mli` / `.ml`: Opt-in resolution and configuration defaults.
- `lib/typesafeai/typesafeai_client.mli` / `.ml`: Outbound HTTP client over `Masc_http_client.post_sync`.
- `lib/typesafeai/typesafeai_board_attention.mli` / `.ml`: Board attention candidate relevance judgment adapter.

---

## 4. Operational Invariants

1. **Closed Sum Types**: The relevance question offers the `Keeper_board_attention_judgment.decision` variant (`Relevant | Not_relevant`) through one `Typesafeai_types.choice_set`. The request's criteria and the decoding of the answer are both built from that set, and a choice or probability key outside it decodes to `Error`.
2. **Deterministic Fallback**: Failure of the external TypeSafe AI endpoint never crashes the worker; it logs a fallback event and proceeds with the configured exact catalog slots.
3. **Zero Blast Radius**: Existing tests and pipelines without `TYPESAFEAI_API_KEY` continue to run completely unaffected.
