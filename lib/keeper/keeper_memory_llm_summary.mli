(** Runtime adapter for opt-in LLM-backed keeper memory-bank consolidation. *)

val summary_max_tokens : int

type complete_fn =
  sw:Eio.Switch.t ->
  net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  ?clock:float Eio.Time.clock_ty Eio.Resource.t ->
  config:Llm_provider.Provider_config.t ->
  messages:Agent_sdk.Types.message list ->
  unit ->
  (Agent_sdk.Types.api_response, Llm_provider.Http_client.http_error) result

val is_direct_completion_provider :
  Llm_provider.Provider_config.t -> bool

val provider_for_summary :
  Llm_provider.Provider_config.t -> Llm_provider.Provider_config.t

val summary_schema_supported : Llm_provider.Provider_config.t -> bool

val messages_for_summary :
  trace_id:string -> texts:string list -> Agent_sdk.Types.message list

type summary_parse_error =
  | Empty_summary_response
  | Invalid_structured_response of string

module For_testing : sig
  val summary_text_of_response : Agent_sdk.Types.api_response -> string option

  val summary_text_result_of_response :
    Agent_sdk.Types.api_response -> (string, summary_parse_error) result

  (** Emits the [masc_keeper_memory_llm_summary_outcomes_total] counter.
      Exposed for the label-redaction regression test; the [provider]
      label value is the neutral runtime lane, never the model id. *)
  val record_summary_outcome :
    runtime_id:string ->
    outcome:Keeper_memory_llm_summary_outcome.t ->
    unit

  val summarize_with_provider :
    ?complete:complete_fn ->
    ?clock:float Eio.Time.clock_ty Eio.Resource.t ->
    ?timeout_sec:float ->
    ?runtime_id:string ->
    sw:Eio.Switch.t ->
    net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
    provider_cfg:Llm_provider.Provider_config.t ->
    trace_id:string ->
    texts:string list ->
    unit ->
    string option
  (** Test-only access to the provider-call boundary. *)
end

val make :
  ?complete:complete_fn ->
  ?timeout_sec:float ->
  runtime_id:string ->
  keeper_name:string ->
  unit ->
  Keeper_memory_bank.memory_consolidation_summarizer option
