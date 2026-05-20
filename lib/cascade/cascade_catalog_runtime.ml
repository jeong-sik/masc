(* Stage 08 — facade preserving the public [Cascade_catalog_runtime]
   surface after the 1674-line split.

   Implementation lives in submodules under [lib/cascade/]:

   - [Cascade_catalog_runtime_cache]            types + singleton cache state
   - [Cascade_catalog_runtime_probe]            provider liveness probes
   - [Cascade_catalog_runtime_json]             boot-log serialization
   - [Cascade_catalog_runtime_validate]         validate_path_result boot path
   - [Cascade_catalog_runtime_resolve]          inspect/lookup orchestration
   - [Cascade_catalog_runtime_named_providers]  resolve_named_providers*

   Types below are re-exported transparently so callers that pattern
   match on [Validated _ | Validated_with_rejections _ |
   Serving_last_known_good _] or read record fields like
   [profile_build.name] / [candidate_runtime.model_string] remain
   source-compatible. *)

(* === Types (transparent re-exports) =================================== *)

type candidate_probe_status =
  Cascade_catalog_runtime_cache.candidate_probe_status =
  | Probe_ok
  | Probe_skipped of string
  | Probe_not_applicable of string
  | Probe_error of string

type candidate_probe = Cascade_catalog_runtime_cache.candidate_probe = {
  model_string : string;
  provider_kind : string;
  model_id : string;
  base_url : string;
  status : candidate_probe_status;
}

type candidate_runtime = Cascade_catalog_runtime_cache.candidate_runtime = {
  model_string : string;
  provider_cfg : Llm_provider.Provider_config.t;
}

type profile_build = Cascade_catalog_runtime_cache.profile_build = {
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

type snapshot = Cascade_catalog_runtime_cache.snapshot = {
  source_path : string;
  mtime : float;
  validated_at : float;
  profiles : profile_build list;
  default_profile_name : string;
}

type rejection = Cascade_catalog_runtime_cache.rejection

type state = Cascade_catalog_runtime_cache.state =
  | Validated of snapshot
  | Validated_with_rejections of {
      snapshot : snapshot;
      rejected_update : rejection;
    }
  | Serving_last_known_good of {
      snapshot : snapshot;
      rejected_update : rejection;
    }

type secondary_resolution =
  Cascade_catalog_runtime_named_providers.secondary_resolution = {
  providers : Llm_provider.Provider_config.t list;
  tiered_providers :
    Cascade_catalog_runtime_named_providers.tiered_provider list;
  secondary_resolver :
    int ->
    Llm_provider.Provider_config.t ->
    Llm_provider.Provider_config.t option;
}

(* === Function re-exports ============================================== *)

let inspect_active = Cascade_catalog_runtime_resolve.inspect_active
let validate_path = Cascade_catalog_runtime_validate.validate_path
let resolve_declared_name = Cascade_catalog_runtime_resolve.resolve_declared_name
let models_of_cascade_name = Cascade_catalog_runtime_resolve.models_of_cascade_name

let resolve_named_providers =
  Cascade_catalog_runtime_named_providers.resolve_named_providers

let resolve_named_providers_strict =
  Cascade_catalog_runtime_named_providers.resolve_named_providers_strict

let resolve_named_providers_strict_with_secondary_resolver =
  Cascade_catalog_runtime_named_providers
  .resolve_named_providers_strict_with_secondary_resolver

let resolve_secondary_provider_for_primary =
  Cascade_catalog_runtime_named_providers.resolve_secondary_provider_for_primary

let resolve_inference_params =
  Cascade_catalog_runtime_named_providers.resolve_inference_params

let resolve_strategy = Cascade_catalog_runtime_named_providers.resolve_strategy

let resolve_ollama_max_concurrent =
  Cascade_catalog_runtime_named_providers.resolve_ollama_max_concurrent

let resolve_cli_max_concurrent =
  Cascade_catalog_runtime_named_providers.resolve_cli_max_concurrent

let known_profile_names = Cascade_catalog_runtime_resolve.known_profile_names
let invalid_profile_errors = Cascade_catalog_runtime_resolve.invalid_profile_errors

let resolve_selection_trace =
  Cascade_catalog_runtime_named_providers.resolve_selection_trace

let snapshot_to_yojson = Cascade_catalog_runtime_json.snapshot_to_yojson
let rejection_to_yojson = Cascade_catalog_runtime_json.rejection_to_yojson
let state_to_yojson = Cascade_catalog_runtime_json.state_to_yojson
let candidate_probe_to_yojson = Cascade_catalog_runtime_json.candidate_probe_to_yojson

let invalidate_path = Cascade_catalog_runtime_cache.invalidate_path

let runtime_required_profile_names =
  Cascade_catalog_runtime_validate.runtime_required_profile_names

let install_snapshot_for_tests =
  Cascade_catalog_runtime_cache.install_snapshot_for_tests

let reset_cache_for_tests = Cascade_catalog_runtime_cache.reset_cache_for_tests
