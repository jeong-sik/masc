(** Runtime-authoritative validated cascade catalog.

    The active runtime [cascade.json] is the only authoritative catalog.
    This module validates the active file, probes every configured
    candidate through the same OAS execution surface as production turns,
    and keeps serving the last-known-good snapshot when a hot reload is
    rejected.

    @stability Internal *)

type candidate_probe_status =
  | Probe_ok
  | Probe_error of string

type candidate_probe = {
  model_string : string;
  provider_kind : string;
  model_id : string;
  base_url : string;
  status : candidate_probe_status;
}

type snapshot
type rejection

type state =
  | Validated of snapshot
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
  sw:Eio.Switch.t ->
  net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  config_path:string ->
  (snapshot, rejection) result

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
  cascade_name:string ->
  unit ->
  (Llm_provider.Provider_config.t list, string) result

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

val install_snapshot_for_tests :
  source_path:string ->
  profile_names:string list ->
  unit

val reset_cache_for_tests : unit -> unit
