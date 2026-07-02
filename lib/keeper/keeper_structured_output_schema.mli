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

val vision_analyze_output_schema : Yojson.Safe.t
(** JSON object the one-shot vision analyzer provider must return. *)

val operator_judge_output_schema : Yojson.Safe.t
(** JSON object the dashboard operator judge provider must return. *)

val governance_judge_output_schema : Yojson.Safe.t
(** JSON object the dashboard governance judge provider must return. *)

val fusion_judge_output_schema : Yojson.Safe.t

val compact_fusion_judge_output_schema : Yojson.Safe.t
(** JSON object the Fusion judge/refine/meta-judge provider must return. *)

val fusion_panel_answer_output_schema : Yojson.Safe.t
(** JSON object each Fusion panel provider must return. *)

val verification_verdict_output_schema : Yojson.Safe.t
(** JSON object the verification verdict providers must return. *)

val anti_rationalization_verdict_output_schema : Yojson.Safe.t
(** JSON object the task anti-rationalization reviewer provider must return. *)

val governance_resolved_tool_tokens : string list
(** Resolved tool names accepted by the dashboard governance judge. The
    provider schema and runtime parser both consume this list. *)

val apply_to_provider_config
  :  Yojson.Safe.t
  -> Llm_provider.Provider_config.t
  -> Llm_provider.Provider_config.t
(** Set both OAS structured-output fields for [schema]. *)

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
