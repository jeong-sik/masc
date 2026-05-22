(** Named cascade resolution setup for keeper turn driver. *)

type secondary_resolver =
  int ->
  Llm_provider.Provider_config.t ->
  Llm_provider.Provider_config.t option

type t = {
  configured_labels_result : (string list, string) result;
  candidate_cfgs_result : (Llm_provider.Provider_config.t list, string) result;
  tiered_providers_result :
    (Cascade_catalog_runtime_named_providers.tiered_provider list, string) result;
  secondary_resolver : secondary_resolver option;
}

val resolve :
  sw:Eio.Switch.t ->
  net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  ?provider_filter:string list ->
  cascade_name:string ->
  runtime_cascade_name:Keeper_cascade_profile.runtime_name ->
  unit ->
  t
