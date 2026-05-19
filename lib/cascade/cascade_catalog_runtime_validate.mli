(** Declarative cascade catalog validation. *)

val active_source_state :
  config_path:string -> Cascade_toml_materializer.source_state

val config_path_opt : unit -> string option

val runtime_required_profile_names :
  ?config_path:string ->
  unit ->
  string list

val validate_path_result :
  ?sw:Eio.Switch.t ->
  ?net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  config_path:string ->
  unit ->
  ( Cascade_catalog_runtime_cache.validation_result,
    Cascade_catalog_runtime_cache.rejection )
  result

val validate_path :
  ?sw:Eio.Switch.t ->
  ?net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  ?clock:float Eio.Time.clock_ty Eio.Resource.t ->
  config_path:string ->
  unit ->
  (Cascade_catalog_runtime_cache.snapshot, Cascade_catalog_runtime_cache.rejection)
  result
