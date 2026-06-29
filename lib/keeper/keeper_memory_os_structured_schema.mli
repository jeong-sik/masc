(** Provider-native JSON schemas for Memory OS LLM producers.

    These schemas are used as [response_format = JsonSchema _] /
    [output_schema = Some _] at the OAS provider boundary. The existing
    domain parsers still own semantic validation after the provider returns
    JSON. *)

val librarian_episode_output_schema : Yojson.Safe.t
(** JSON object the librarian extraction provider must return. *)

val consolidation_plan_output_schema : Yojson.Safe.t
(** JSON object the per-keeper consolidation provider must return. *)

val apply_to_provider_config
  :  Yojson.Safe.t
  -> Llm_provider.Provider_config.t
  -> Llm_provider.Provider_config.t
(** Set both OAS structured-output fields for [schema]. *)
