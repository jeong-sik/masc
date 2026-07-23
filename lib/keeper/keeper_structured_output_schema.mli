(** Provider-native JSON schemas for MASC LLM sub-call producers.

    These schemas are used as [response_format = JsonSchema _] /
    [output_schema = Some _] at the OAS provider boundary. The existing
    domain parsers still own semantic validation after the provider returns
    JSON. *)

val librarian_episode_output_schema : Yojson.Safe.t
(** JSON object the librarian extraction provider must return. *)

val consolidation_plan_output_schema : Yojson.Safe.t
(** JSON object the per-keeper consolidation provider must return. *)

val memory_bank_summary_output_schema : Yojson.Safe.t
(** JSON object the memory-bank summary provider must return. *)

(** Wire field names and action tokens for {!compaction_plan_output_schema};
    shared with the compaction-plan codec as the single source of truth. *)
val compaction_plan_field_decisions : string
val compaction_plan_field_unit_index : string
val compaction_plan_field_action : string
val compaction_plan_field_summary : string
val compaction_plan_action_keep : string
val compaction_plan_action_drop : string
val compaction_plan_action_summarize : string

val compaction_plan_output_schema : Yojson.Safe.t
(** JSON object the LLM compaction summarizer must return: exactly one typed
    decision for every eligible source unit. *)

val vision_analyze_output_schema : Yojson.Safe.t
(** JSON object the one-shot vision analyzer provider must return. *)

val fusion_judge_output_schema : Yojson.Safe.t
(** JSON object the Fusion judge/refine/meta-judge provider must return. *)

val failure_judgment_output_schema : Yojson.Safe.t
(** Strict independent Keeper failure-judgment verdict. Decision tokens are
    owned by {!Keeper_failure_judgment_contract}. *)

val board_attention_judgment_batch_output_schema : Yojson.Safe.t
(** Strict batch relevance verdict: one [verdicts] array whose items carry the
    exact candidate identity. Decision tokens are owned by
    {!Keeper_board_attention_judgment}. *)

val hitl_context_summary_schema : Yojson.Safe.t
(** JSON object the HITL context-summary worker provider must return. *)

val apply_to_provider_config
  :  Yojson.Safe.t
  -> Llm_provider.Provider_config.t
  -> Llm_provider.Provider_config.t
(** Set both OAS structured-output fields for [schema]. *)

val apply_hitl_summary_schema_to_config
  :  Llm_provider.Provider_config.t
  -> Llm_provider.Provider_config.t
(** Set both OAS structured-output fields for {!hitl_context_summary_schema}. *)

val without_response_format
  :  Llm_provider.Provider_config.t
  -> Llm_provider.Provider_config.t
(** Clear both OAS structured-output fields: the request states its output
    contract in its prompt and validates the parse downstream, so it asks the
    provider for no wire format at all. Use for call sites whose prompt spells
    out the object shape and whose parser is total — a malformed reply must
    already become a typed error rather than a bad write. Every provider then
    takes one identical request path with no capability branch. *)

val anti_rationalization_reviewer_provider_config
  :  Llm_provider.Provider_config.t
  -> Llm_provider.Provider_config.t
(** Provider config for the task anti-rationalization reviewer: clears both
    OAS structured-output fields. The verdict channel is the
    [report_review_verdict] tool call (exactly-once, total parser in
    [Task.Anti_rationalization]); a wire response format constrained only the
    final assistant text this surface never parses, and its capability branch
    rejected json_object-only providers, leaving every task nonterminal
    (2026-07-21 live incident). *)

val apply_schema_json_mode_or_prompt_tier
  :  log_label:string
  -> Yojson.Safe.t
  -> Llm_provider.Provider_config.t
  -> Llm_provider.Provider_config.t
(** Three-tier response-format selection (#25266): enforce [schema] when the
    provider supports strict json_schema; else set JSON mode ([JsonMode]) when
    the provider supports json_object; else prompt only. Use ONLY where the
    prompt already states the schema and the parser validates the response —
    the json_object tier drops the strict guarantee. *)

val validate_provider_config
  :  Yojson.Safe.t
  -> Llm_provider.Provider_config.t
  -> (unit, string) result
(** Validate that [provider_cfg] can accept [schema] at the OAS boundary. *)

val provider_config_accepts_schema
  :  Yojson.Safe.t
  -> Llm_provider.Provider_config.t
  -> bool
(** True when [validate_provider_config] accepts [provider_cfg]. *)

val provider_config_accepts_schema_or_json_mode
  :  Yojson.Safe.t
  -> Llm_provider.Provider_config.t
  -> bool
(** True when the provider can enforce [schema] (strict) OR honor JSON mode
    (#25266). Eligibility gate for structured lanes that have a
    json_object fallback; a provider with neither capability is rejected. *)

val for_deterministic_subcall
  :  max_tokens:int option
  -> Llm_provider.Provider_config.t
  -> Llm_provider.Provider_config.t
(** Provider shape shared by MASC's deterministic LLM subcalls (librarian
    extraction, memory-OS consolidation): no tool choice, no parallel tool
    use, and thinking fully suppressed.

    Thinking suppression is the load-bearing part. Reasoning-capable
    providers otherwise spend the whole output budget on thinking and return
    an empty visible text; consolidation observed 256 consecutive empty
    responses that way on 2026-07-20, and the tuning removed them.

    Each call site previously spelled the same six fields by hand, with the
    second site's comment reading "Mirror the librarian tuning" — the
    N-of-M shape RFC-0000 §9 rejects. Deriving from here means a new
    subcall inherits the shape instead of re-deriving it, and dropping the
    suppression becomes a visible override rather than an omission.

    [max_tokens] is passed through because the budget is genuinely
    site-specific (a consolidation plan over hundreds of rows needs more
    room than a per-turn summary); everything else is not.

    This does NOT apply the response-format/schema tier — sites differ there
    and compose {!without_response_format} or
    {!apply_schema_json_mode_or_prompt_tier} themselves. *)
