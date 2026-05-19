(** Cache-aware cascade catalog resolution. *)

val inspect_active :
  ?sw:Eio.Switch.t ->
  ?net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  ?clock:float Eio.Time.clock_ty Eio.Resource.t ->
  unit ->
  (Cascade_catalog_runtime_cache.state, Cascade_catalog_runtime_cache.rejection)
  result

val lookup_active_profile :
  ?sw:Eio.Switch.t ->
  ?net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  ?clock:float Eio.Time.clock_ty Eio.Resource.t ->
  string ->
  ( Cascade_catalog_runtime_cache.snapshot
    * string
    * Cascade_catalog_runtime_cache.profile_snapshot,
    string )
  result

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
