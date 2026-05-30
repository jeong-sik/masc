(** Declarative cascade catalog validation. *)

val active_source_state :
  config_path:string -> Keeper_toml_materializer.source_state

val config_path_opt : unit -> string option

(* #19327/#19340 follow-up: [runtime_required_profile_names] removed (dead). *)

(** DI envelope for the post-profile route-target cross-check.  External
    callers (dashboard / boot probes) build this from {!Keeper_routes}
    before invoking validate; internal callers (resolve.ml) pass
    {!empty_route_data} to skip route-target validation when they only
    need profile validation.  See PR cycle resolution. *)
type route_data = {
  keeper_turn_target : string option;
  route_targets : string list;
  unknown_route_keys : string list;
}

val empty_route_data : route_data

val validate_path_result :
  ?sw:Eio.Switch.t ->
  ?net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  route_data:route_data ->
  config_path:string ->
  unit ->
  ( Keeper_catalog_runtime_cache.validation_result,
    Keeper_catalog_runtime_cache.rejection )
  result

val validate_path :
  ?sw:Eio.Switch.t ->
  ?net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  ?clock:float Eio.Time.clock_ty Eio.Resource.t ->
  route_data:route_data ->
  config_path:string ->
  unit ->
  (Keeper_catalog_runtime_cache.snapshot, Keeper_catalog_runtime_cache.rejection)
  result
