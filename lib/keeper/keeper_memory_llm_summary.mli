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

val messages_for_summary :
  trace_id:string -> texts:string list -> Agent_sdk.Types.message list

val make :
  ?complete:complete_fn ->
  ?provider_filter:string list ->
  ?timeout_sec:float ->
  cascade_name:string ->
  keeper_name:string ->
  unit ->
  Keeper_memory_bank.memory_consolidation_summarizer option
