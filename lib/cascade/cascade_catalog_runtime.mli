(** Runtime-authoritative validated cascade catalog.

    The runtime still executes from [cascade.json], but when a sibling
    [cascade.toml] exists it becomes the authoring SSOT and [cascade.json] is
    materialized from it on load. This module validates the active source
    statically and keeps serving the last-known-good snapshot when a hot reload
    is rejected. Provider liveness is advisory runtime state and does not
    invalidate an otherwise-correct catalog.

    @stability Internal *)

type candidate_probe_status =
  | Probe_ok
  | Probe_skipped of string
  | Probe_not_applicable of string
  | Probe_error of string

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
}

type snapshot = {
  source_path : string;
  mtime : float;
  validated_at : float;
  profiles : profile_build list;
}

type rejection

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

val inspect_active :
  ?sw:Eio.Switch.t ->
  ?net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  ?clock:float Eio.Time.clock_ty Eio.Resource.t ->
  unit ->
  (state, rejection) result

val validate_path :
  ?sw:Eio.Switch.t ->
  ?net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  ?clock:float Eio.Time.clock_ty Eio.Resource.t ->
  config_path:string ->
  unit ->
  (snapshot, rejection) result
(** Returns the validated subset of profiles when the catalog is partly
    usable but some presets are rejected at runtime. Inspect
    {!inspect_active} when the caller needs the rejected-profile detail. *)

val resolve_declared_name :
  ?sw:Eio.Switch.t ->
  ?net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  ?clock:float Eio.Time.clock_ty Eio.Resource.t ->
  raw_name:string ->
  unit ->
  (string, string) result

val models_of_cascade_name :
  ?sw:Eio.Switch.t ->
  ?net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  ?clock:float Eio.Time.clock_ty Eio.Resource.t ->
  string ->
  (string list, string) result

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
(** Strict variant of {!resolve_named_providers} for execution paths.
    Provider filter resolution fails closed instead of silently
    broadening to the full provider set. *)

type secondary_resolution = {
  providers : Llm_provider.Provider_config.t list;
  secondary_resolver :
    int -> Llm_provider.Provider_config.t ->
    Llm_provider.Provider_config.t option;
}
(** Providers resolved from a named cascade plus an index-aware secondary
    lookup derived from the same ordered entries. The resolver is pure
    over this snapshot and does not re-read or re-rotate catalog state. *)

val resolve_named_providers_strict_with_secondary_resolver :
  ?sw:Eio.Switch.t ->
  ?net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  ?clock:float Eio.Time.clock_ty Eio.Resource.t ->
  ?provider_filter:string list ->
  cascade_name:string ->
  unit ->
  (secondary_resolution, string) result
(** Strict named-provider resolution that also precomputes RFC-0027 PR-9b
    secondary fallbacks from the same ordered weighted entries. Provider
    filters are applied to both primaries and secondaries. *)

val resolve_secondary_provider_for_primary :
  ?sw:Eio.Switch.t ->
  ?net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  ?clock:float Eio.Time.clock_ty Eio.Resource.t ->
  cascade_name:string ->
  primary:Llm_provider.Provider_config.t ->
  unit ->
  Llm_provider.Provider_config.t option
(** RFC-0027 PR-9b dual-track lookup. For a [primary] provider returned
    from {!resolve_named_providers} of [cascade_name], find the matching
    weighted entry and parse its [secondary] field (if any) into a fresh
    [Provider_config.t]. Returns [None] when the entry has no secondary,
    when the primary is not present in the cascade (e.g. cross-cascade
    fallback path), or when secondary parsing fails (unregistered scheme,
    invalid syntax). The lookup is read-only and does not mutate cascade
    state — secondary resolution is invoked only after the primary has
    been rejected by the tool-use gate. *)

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

val known_profile_names :
  ?sw:Eio.Switch.t ->
  ?net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  ?clock:float Eio.Time.clock_ty Eio.Resource.t ->
  unit ->
  (string list, string) result

val invalid_profile_errors :
  ?sw:Eio.Switch.t ->
  ?net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  ?clock:float Eio.Time.clock_ty Eio.Resource.t ->
  unit ->
  (string * string list) list
(** Profile-scoped validation errors from the active runtime catalog
    view. Returns [[]] when the catalog is fully validated. *)

val resolve_selection_trace :
  ?sw:Eio.Switch.t ->
  ?net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  ?clock:float Eio.Time.clock_ty Eio.Resource.t ->
  name:string ->
  unit ->
  (Cascade_config.selection_trace, string) result

val snapshot_to_yojson : snapshot -> Yojson.Safe.t
val rejection_to_yojson : rejection -> Yojson.Safe.t
val state_to_yojson : state -> Yojson.Safe.t

val invalidate_path : string -> unit

val runtime_required_profile_names :
  ?config_path:string ->
  unit ->
  string list

val install_snapshot_for_tests :
  source_path:string ->
  profile_names:string list ->
  unit

val reset_cache_for_tests : unit -> unit
