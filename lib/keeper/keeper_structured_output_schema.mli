(** Domain JSON schemas for MASC LLM sub-call parsers and exact-output flows.

    They describe the expected value for prompt instructions and local parsing;
    MASC does not send them through provider-native response formats. *)

val librarian_current_output_schema : Yojson.Safe.t
(** JSON object the current-memory Librarian must return. *)

val fusion_judge_output_schema : Yojson.Safe.t
(** JSON object the Fusion judge/refine/meta-judge provider must return. *)

val board_attention_judgment_batch_output_schema : Yojson.Safe.t
(** Strict batch relevance verdict: one [verdicts] array whose items carry the
    exact candidate identity. Decision tokens are owned by
    {!Keeper_board_attention_judgment}. *)

val hitl_context_summary_schema : Yojson.Safe.t
(** JSON object the HITL context-summary worker provider must return. *)

val without_response_format
  :  Llm_provider.Provider_config.t
  -> Llm_provider.Provider_config.t
(** Clear the AGENT_CORE structured-output response format: the request states its output
    contract in its prompt and validates the parse downstream, so it asks the
    provider for no wire format at all. Use for call sites whose prompt spells
    out the object shape and whose parser is total — a malformed reply must
    already become a typed error rather than a bad write. Every provider then
    takes one identical request path with no capability branch. *)

val anti_rationalization_reviewer_provider_config
  :  Llm_provider.Provider_config.t
  -> Llm_provider.Provider_config.t
(** Provider config for the task anti-rationalization reviewer: clears the AGENT_CORE
    structured-output response format. The verdict channel is the
    [report_review_verdict] tool call (exactly-once, total parser in
    [Task.Anti_rationalization]); a wire response format constrained only the
    final assistant text this surface never parses, and its capability branch
    rejected json_object-only providers, leaving every task nonterminal
    (2026-07-21 live incident). *)

val for_deterministic_subcall
  :  max_tokens:int option
  -> Llm_provider.Provider_config.t
  -> Llm_provider.Provider_config.t
(** Provider shape shared by MASC's deterministic LLM subcalls: no tool choice,
    no parallel tool use, and thinking fully suppressed.

    Thinking suppression is the load-bearing part. Reasoning-capable
    providers otherwise spend the whole output budget on thinking and return
    an empty visible text; production deterministic subcalls observed that
    failure mode before this shared tuning removed it.

    Deriving from this function means a new subcall inherits the shape instead
    of re-deriving it, and dropping the suppression becomes a visible override
    rather than an omission.

    [max_tokens] is passed through because the budget is genuinely
    site-specific to each bounded input contract; everything else is not.

    This does NOT clear [response_format] — callers compose
    {!without_response_format} themselves. *)
