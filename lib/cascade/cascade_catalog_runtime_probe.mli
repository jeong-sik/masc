open Cascade_catalog_runtime_cache

val provider_kind_string : Llm_provider.Provider_config.t -> string

val public_runtime_provider_label : string

val public_runtime_model_label : string

val candidate_probe_error : candidate_runtime -> string -> candidate_probe

val candidate_probe_ok : candidate_runtime -> candidate_probe

val candidate_probe_skipped : candidate_runtime -> string -> candidate_probe

val candidate_probe_not_applicable : candidate_runtime -> string -> candidate_probe

val local_probe_unavailable_reason : string

val cloud_probe_not_applicable_reason : string

val profile_probes : candidate_runtime list -> candidate_probe list

val normalize_endpoint_url : string -> string

val endpoint_status_for_candidate : endpoint_status list -> candidate_runtime -> endpoint_status

val profile_probes_from_statuses :
  endpoint_status list -> candidate_runtime list -> candidate_probe list

val attach_probe_results :
  ?sw:Eio.Switch.t -> ?net:Eio.Net.t -> profile_snapshot list -> unit

val probe_health_value : probe_status -> float

val record_probe_metrics : profile_snapshot list -> unit
