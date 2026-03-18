(** Provider dispatch — config build, HTTP execution, response mapping.

    Converts MASC {!Llm_types.completion_request} to OAS
    {!Llm_provider.Provider_config.t} and calls
    {!Llm_provider.Complete.complete}.

    @since 2.107.0 *)

(** Execute a single LLM completion via OAS provider path. *)
val call_provider :
  ?timeout_sec:int ->
  ?cache:Llm_provider.Cache.t ->
  ?metrics:Llm_provider.Metrics.t ->
  Llm_types.completion_request ->
  (Llm_types.completion_response, string) result

(** GLM Cloud with pool-based model selection. *)
val call_glm_cloud_with_pool :
  ?timeout_sec:int ->
  ?cache:Llm_provider.Cache.t ->
  ?metrics:Llm_provider.Metrics.t ->
  Llm_types.completion_request ->
  (Llm_types.completion_response, string) result

(** Convert OAS api_response to MASC completion_response. *)
val completion_response_of_api_response :
  Llm_provider.Types.api_response -> Llm_types.completion_response

(** Convert MASC completion_response to OAS api_response (for cache serialization).
    Sets [id] to ["cached"] and [stop_reason] to [EndTurn]. *)
val api_response_of_completion_response :
  Llm_types.completion_response -> Llm_provider.Types.api_response

(** Build OAS provider config from completion request. *)
val provider_config_of_request :
  Llm_types.completion_request ->
  (Llm_provider.Provider_config.t * Llm_provider.Types.message list * Yojson.Safe.t list, string) result

(** Map model_spec to OAS Provider.config. *)
val to_oas_provider : Llm_types.model_spec -> Agent_sdk.Provider.config option

(** Convert MASC message to OAS message (None for System). *)
val to_oas_message : Llm_types.message -> Agent_sdk.Types.message option

(** Convert OAS message to MASC message. *)
val of_oas_message : Agent_sdk.Types.message -> Llm_types.message

(** Format HTTP error for logging. *)
val string_of_http_error : Llm_provider.Http_client.http_error -> string

val of_oas_usage : Agent_sdk.Types.api_usage -> Llm_types.token_usage
val to_oas_usage : Llm_types.token_usage -> Agent_sdk.Types.api_usage
