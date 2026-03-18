(** Llm_client — OAS type adapters.

    Conversion functions between MASC {!Llm_types} and OAS {!Agent_sdk} types.
    For LLM calls use {!Llm_orchestration}, for types use {!Llm_types}.

    @since 2.61.0
    @since 2.114.0 — re-export removed *)

(** {1 OAS Type Adapters} *)

(** Map a masc-mcp model_spec to an OAS Provider.config. *)
val to_oas_provider : Llm_types.model_spec -> Agent_sdk.Provider.config option

(** Convert a masc message to an OAS Types.message.
    System messages return None (they belong in system_prompt). *)
val to_oas_message : Llm_types.message -> Agent_sdk.Types.message option

(** Convert an OAS Types.message back to a masc message. *)
val of_oas_message : Agent_sdk.Types.message -> Llm_types.message

(** Convert OAS api_usage to masc token_usage. *)
val of_oas_usage : Agent_sdk.Types.api_usage -> Llm_types.token_usage

(** Convert masc token_usage to OAS api_usage. *)
val to_oas_usage : Llm_types.token_usage -> Agent_sdk.Types.api_usage
