(** Named-provider resolution helpers for {!Cascade_catalog_runtime}. *)

val resolve_named_providers :
  ?sw:Eio.Switch.t ->
  ?net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  ?clock:float Eio.Time.clock_ty Eio.Resource.t ->
  ?provider_filter:string list ->
  ?require_tool_choice_support:bool ->
  ?require_tool_support:bool ->
  ?runtime_mcp_policy:Llm_provider.Llm_transport.runtime_mcp_policy ->
  cascade_name:string ->
  unit ->
  (Llm_provider.Provider_config.t list, string) result

val resolve_named_providers_strict :
  ?sw:Eio.Switch.t ->
  ?net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  ?clock:float Eio.Time.clock_ty Eio.Resource.t ->
  ?provider_filter:string list ->
  ?require_tool_choice_support:bool ->
  ?require_tool_support:bool ->
  ?runtime_mcp_policy:Llm_provider.Llm_transport.runtime_mcp_policy ->
  cascade_name:string ->
  unit ->
  (Llm_provider.Provider_config.t list, string) result

type secondary_resolution = {
  providers : Llm_provider.Provider_config.t list;
  secondary_resolver :
    int ->
    Llm_provider.Provider_config.t ->
    Llm_provider.Provider_config.t option;
}

val resolve_named_providers_strict_with_secondary_resolver :
  ?sw:Eio.Switch.t ->
  ?net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  ?clock:float Eio.Time.clock_ty Eio.Resource.t ->
  ?provider_filter:string list ->
  cascade_name:string ->
  unit ->
  (secondary_resolution, string) result

val resolve_secondary_provider_for_primary :
  ?sw:Eio.Switch.t ->
  ?net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  ?clock:float Eio.Time.clock_ty Eio.Resource.t ->
  cascade_name:string ->
  primary:Llm_provider.Provider_config.t ->
  unit ->
  Llm_provider.Provider_config.t option

val resolve_inference_params :
  ?sw:Eio.Switch.t ->
  ?net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  ?clock:float Eio.Time.clock_ty Eio.Resource.t ->
  name:string ->
  unit ->
  (Cascade_config_loader.inference_params, string) result

val resolve_strategy :
  ?sw:Eio.Switch.t ->
  ?net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  ?clock:float Eio.Time.clock_ty Eio.Resource.t ->
  name:string ->
  unit ->
  (Cascade_strategy.t, string) result

val resolve_ollama_max_concurrent :
  ?sw:Eio.Switch.t ->
  ?net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  ?clock:float Eio.Time.clock_ty Eio.Resource.t ->
  name:string ->
  unit ->
  (int option, string) result

val resolve_cli_max_concurrent :
  ?sw:Eio.Switch.t ->
  ?net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  ?clock:float Eio.Time.clock_ty Eio.Resource.t ->
  name:string ->
  unit ->
  (int option, string) result

val resolve_selection_trace :
  ?sw:Eio.Switch.t ->
  ?net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  ?clock:float Eio.Time.clock_ty Eio.Resource.t ->
  name:string ->
  unit ->
  (Cascade_config.selection_trace, string) result
