(** Provider dispatch — config build, HTTP execution, response mapping.

    Converts MASC {!Llm_types.completion_request} to OAS
    {!Llm_provider.Provider_config.t} and calls
    {!Llm_provider.Complete.complete}.

    @since 2.107.0 *)

(** Execute a single LLM completion via OAS provider path.
    Returns OAS api_response directly — no MASC wrapper. *)
val call_provider :
  ?timeout_sec:int ->
  ?cache:Llm_provider.Cache.t ->
  ?metrics:Llm_provider.Metrics.t ->
  Llm_types.completion_request ->
  (Llm_provider.Types.api_response, string) result

(** GLM Cloud with pool-based model selection.
    Returns OAS api_response directly. *)
val call_glm_cloud_with_pool :
  ?timeout_sec:int ->
  ?cache:Llm_provider.Cache.t ->
  ?metrics:Llm_provider.Metrics.t ->
  Llm_types.completion_request ->
  (Llm_provider.Types.api_response, string) result

(** Build a provider config, messages, and tools from a completion request.
    Used by {!Llm_orchestration.call_provider_stream}. *)
val provider_config_of_request :
  Llm_types.completion_request ->
  (Llm_provider.Provider_config.t
   * Llm_provider.Types.message list
   * Yojson.Safe.t list, string) result

(** Human-readable string from an HTTP client error. *)
val string_of_http_error :
  Llm_provider.Http_client.http_error -> string

val to_oas_provider : Llm_types.model_spec -> Agent_sdk.Provider.config option
val to_oas_message : Llm_types.message -> Agent_sdk.Types.message option
val of_oas_message : Agent_sdk.Types.message -> Llm_types.message
val of_oas_usage : Agent_sdk.Types.api_usage -> Llm_types.token_usage
val to_oas_usage : Llm_types.token_usage -> Agent_sdk.Types.api_usage
