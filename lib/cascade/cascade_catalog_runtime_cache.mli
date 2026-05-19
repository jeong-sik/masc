(** Shared cache state and transparent data types for
    {!Cascade_catalog_runtime}. *)

type candidate_probe_status =
  | Probe_ok
  | Probe_skipped of string
  | Probe_not_applicable of string
  | Probe_error of string

val probe_timeout_sec : float

type candidate_probe = {
  model_string : string;
  provider_kind : string;
  model_id : string;
  base_url : string;
  status : candidate_probe_status;
}

type candidate_runtime = {
  model_string : string;
  provider_cfg : Llm_provider.Provider_config.t;
}

type profile_build = {
  name : string;
  weighted_entries : Cascade_config_loader.weighted_entry list;
  inference_params : Cascade_config_loader.inference_params;
  api_key_env_overrides : (string * string) list;
  strategy : Cascade_strategy.t;
  ollama_max_concurrent : int option;
  cli_max_concurrent : int option;
  candidates : candidate_runtime list;
  probes : candidate_probe list;
  required_capability_profile : string option;
}

type profile_snapshot = profile_build

type snapshot = {
  source_path : string;
  mtime : float;
  validated_at : float;
  profiles : profile_snapshot list;
  default_profile_name : string;
}

type profile_rejection = {
  name : string;
  errors : string list;
  probes : candidate_probe list;
}

type rejection = {
  source_path : string;
  attempted_mtime : float option;
  checked_at : float;
  errors : string list;
  profiles : profile_rejection list;
}

type state =
  | Validated of snapshot
  | Validated_with_rejections of {
      snapshot : snapshot;
      rejected_update : rejection;
    }
  | Serving_last_known_good of {
      snapshot : snapshot;
      rejected_update : rejection;
    }

type validation_result = {
  snapshot : snapshot;
  rejected_update : rejection option;
}

type cache = {
  active_snapshot : snapshot option;
  rejected_update : rejection option;
}

val cache : cache ref
val with_cache_lock : (unit -> 'a) -> 'a
val reset_cache_for_tests : unit -> unit
val invalidate_path : string -> unit
val install_snapshot_for_tests : source_path:string -> profile_names:string list -> unit
val same_snapshot_key : snapshot -> path:string -> mtime:float -> bool
val same_rejection_key : rejection -> path:string -> mtime:float -> bool
val profile_lookup : profile_snapshot list -> string -> profile_snapshot option
val profile_names_of_snapshot : snapshot -> string list
