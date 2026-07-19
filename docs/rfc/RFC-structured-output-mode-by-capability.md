---
rfc: "structured-output-mode-by-capability"
title: "Select structured-output mode by provider capability (dissolve the json_schema single-lane SPOF)"
status: Draft
created: 2026-07-19
updated: 2026-07-19
author: vincent
supersedes: []
related: ["25266", "25192", "25268", "0126"]
tracking_issues: ["25266", "24838", "25051"]
---

# RFC-structured-output-mode-by-capability

- Status: Draft
- Boundary: How a structured-output consumer asks a provider for JSON is a
  per-runtime capability decision, not a fixed mode. Mode selection is MASC's;
  the request contract is OAS's.

## Summary

The compaction plan summarizer requests provider-native `json_schema`
unconditionally. On the live 16-keeper fleet only one runtime
(`ollama_cloud_native.minimax-m3-native-structured`) advertises `json_schema`,
so every keeper's structured compaction converges on that single endpoint.
`json_object`-only runtimes (GLM, DeepSeek, Kimi) are excluded even though they
can return constrained JSON. When the single `json_schema` endpoint hits its
provider weekly rate limit — observed live 2026-07-19 14:09Z,
`Rate limited: you (yousleepwhen) have reached your weekly usage limit` — all
compaction fails, histories overflow the model context (a live keeper request
reached 468,981 tokens against a 262,144 limit), and the fleet degrades.

This is not a new mechanism. `hitl_summary_worker` already selects between
`Native_structured` (provider-native `json_schema`) and a `Plain_json_text`
degradation per endpoint capability (`hitl_summary_worker.mli:36-40`). This RFC
extracts that decision into one shared capability-driven selector and has the
compaction summarizer — and any other structured consumer — use it, so
structured output is available on every runtime that can return JSON. That
removes the single lane, so the convergence and rate-limit SPOF cannot form.

## Problem (evidence)

- `keeper_compaction_llm_summarizer.ml` gates on a single predicate: if the
  provider does not support the compaction-plan `json_schema`, the candidate is
  skipped and the chain returns `None`. Only `json_schema`-capable runtimes
  qualify.
- Live runtime assignments route 12/16 keepers to `json_schema`-incapable chat
  models (deepseek-v4-flash x9, glm-coding x3). #25062 then routed their
  compaction to the shared `structured_judge` runtime, which is the sole
  `json_schema` endpoint (`ollama_cloud_native.minimax-m3-native-structured`).
- Consequence chain (live 2026-07-19): shared endpoint weekly-rate-limited →
  compaction summarizer fails → history not relieved → `context_budget`
  saturates (observed 468,981 > 262,144) → keeper cycle fails every turn →
  fleet running 3/10, others recovering. Tracked by #25266 (P1), #24838 (P0),
  #25051 (P0).

The runtime already carries both capabilities:
`supports_structured_output` (`json_schema`) and
`supports_response_format_json` (`json_object`). The summarizer consults only
the first.

## Contract

1. A structured-output request selects its mode from the runtime's declared
   capabilities, in this order:
   - `json_schema` (provider-native structured output) when
     `supports_structured_output`.
   - `json_object` (`response_format`) when `supports_response_format_json`.
   - Prompt-instructed JSON with a typed parse (the `Plain_json_text`
     degradation) only when neither is declared.
2. The selection is one SSOT function. `hitl_summary_worker`, the compaction
   summarizer, and structured judges call the same selector rather than each
   re-deciding.
3. A rate limit or outage on one runtime does not remove structured output from
   the fleet: every runtime that declares any of the three modes stays
   eligible.
4. Each mode returns a typed result. A parse failure in the `Plain_json_text`
   path is an explicit typed error, not a silent empty plan (RFC-0126).

## Non-goals / explicitly rejected

- Hardcoding a single "the structured lane" runtime. That is the SPOF this RFC
  removes.
- Silently downgrading to unvalidated prose JSON when `json_object` is
  available. `json_object` constrains the response; `Plain_json_text` is the
  last resort and its parse failure must surface (RFC-0126 silent-fallback
  discipline).
- Loosening the compaction-plan schema itself. The plan contract is unchanged;
  only the wire mode used to obtain it varies by capability.

## Remediation (implementation scope, for a follow-up PR)

1. Extract the `Native_structured | Json_object | Plain_json_text` selection
   from `hitl_summary_worker` into a shared module keyed on runtime
   capabilities.
2. Have `keeper_compaction_llm_summarizer` build its request through that
   selector instead of the single `json_schema` gate, so a `json_object`
   runtime (GLM/DeepSeek/Kimi) can return a valid compaction plan.
3. Apply the same selector to structured judges that currently assume
   `json_schema`.
4. Keep the typed compaction-plan parse; add the `json_object` and
   `Plain_json_text` decode paths with explicit typed failures.

## Verification

- A keeper assigned a `json_object`-only runtime (e.g. glm-coding) produces a
  valid compaction plan without touching the `json_schema` endpoint.
- Disabling the single `json_schema` runtime does not stop fleet-wide
  compaction; other capable runtimes carry it.
- A `Plain_json_text` parse failure surfaces a typed error, not an empty plan.
- Mode selection lives in one function; grep finds no second copy of the
  capability branch.
- Counterfactual: forcing every runtime to `json_schema`-only reproduces the
  single-lane convergence (a bug-model that the capability selector must not
  admit).

## Relationship to the compaction RFC family

- #25192 (per-Keeper compaction lane): complementary. It distributes load off a
  shared lane; this RFC removes the single lane entirely, so convergence is no
  longer possible to begin with.
- #25268 (deterministic structural floor): complementary. It provides a
  deterministic fallback when the LLM path fails; this RFC widens the LLM path
  so the floor is reached far less often.
- #25266 (issue): this RFC is its resolution.

## Open questions

- Do OpenAI/Anthropic runtimes (100% `json_schema`) get wired into the fleet as
  additional `json_schema` capacity, or is `json_object` breadth across the
  existing local/cloud runtimes sufficient? The two are not exclusive.
- Should `Plain_json_text` remain permitted at all once `json_object` covers the
  current fleet, or be retired as a mode to keep the surface small?
