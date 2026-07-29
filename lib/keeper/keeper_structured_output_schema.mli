(** Provider-native JSON schemas for MASC LLM sub-call producers.

    These schemas are used as [response_format = JsonSchema _] at the OAS
    provider boundary. The existing domain parsers still own semantic
    validation after the provider returns JSON. *)

val librarian_episode_output_schema : Yojson.Safe.t
(** JSON object the librarian extraction provider must return. *)

val consolidation_plan_output_schema : Yojson.Safe.t
(** JSON object the per-keeper consolidation provider must return. *)

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
(** Set the single OAS structured-output request state for [schema]. *)

val without_response_format
  :  Llm_provider.Provider_config.t
  -> Llm_provider.Provider_config.t
(** Clear the OAS structured-output request state: the request states its output
    contract in its prompt and validates the parse downstream, so it asks the
    provider for no wire format at all. Use for call sites whose prompt spells
    out the object shape and whose parser is total — a malformed reply must
    already become a typed error rather than a bad write. Every provider then
    takes one identical request path with no capability branch. *)

val anti_rationalization_reviewer_provider_config
  :  Llm_provider.Provider_config.t
  -> Llm_provider.Provider_config.t
(** Provider config for the task anti-rationalization reviewer: clears the OAS
    structured-output request state. The verdict channel is the
    [report_review_verdict] tool call (exactly-once, total parser in
    [Task.Anti_rationalization]); a wire response format constrained only the
    final assistant text this surface never parses, and its capability branch
    rejected json_object-only providers, leaving every task nonterminal
    (2026-07-21 live incident). *)

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
    and compose {!without_response_format} themselves. *)
