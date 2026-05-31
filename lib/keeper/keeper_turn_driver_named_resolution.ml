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

let resolve ~sw ~net ?provider_filter ~runtime_id ~runtime_runtime_id () =
  let _ = sw, net in
  let candidate_cfgs_result =
    match Runtime_oas_runner.resolve_runtime_providers ?provider_filter ~runtime_id () with
    | Ok providers -> Ok providers
    | Error detail -> Error detail
  in
  {
    configured_labels_result =
      Provider_runtime_projection.default_execution_model_strings_result runtime_runtime_id;
    candidate_cfgs_result;
    secondary_resolver = None;
  }
