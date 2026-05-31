(** Named runtime resolution setup for keeper turn driver. *)

type secondary_resolver =
  int ->
  Llm_provider.Provider_config.t ->
  Llm_provider.Provider_config.t option

type t = {
  configured_labels_result : (string list, string) result;
  candidate_cfgs_result : (Llm_provider.Provider_config.t list, string) result;
  secondary_resolver : secondary_resolver option;
}

val resolve :
  sw:Eio.Switch.t ->
  net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  ?provider_filter:string list ->
  runtime_id:string ->
  runtime_runtime_id:string ->
  unit ->
  t
