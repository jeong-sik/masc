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

let resolve ~sw ~net ?provider_filter ~cascade_name ~runtime_cascade_name () =
  let named_resolution =
    Cascade_catalog_runtime
    .resolve_named_providers_strict_with_secondary_resolver
      ~sw ~net ?provider_filter ~cascade_name ()
  in
  let candidate_cfgs_result =
    match named_resolution with
    | Ok resolution -> Ok resolution.providers
    | Error detail -> Error detail
  in
  let tiered_providers_result =
    match named_resolution with
    | Ok resolution -> Ok resolution.tiered_providers
    | Error detail -> Error detail
  in
  let secondary_resolver =
    match named_resolution with
    | Ok resolution -> Some resolution.secondary_resolver
    | Error _ -> None
  in
  {
    configured_labels_result =
      Cascade_runtime.models_of_cascade_name_result runtime_cascade_name;
    candidate_cfgs_result;
    tiered_providers_result;
    secondary_resolver;
  }
