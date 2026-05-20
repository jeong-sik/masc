(** Placeholder builders for the cached [/health?full=1] fields. *)

val full_health_cached_field_names : string list
val full_health_field_is_cached : string -> bool

val full_health_component_placeholder
  :  ?error:string
  -> status:string
  -> string
  -> Yojson.Safe.t

val full_health_placeholder_fields
  :  ?error:string
  -> ?status:string
  -> unit
  -> (string * Yojson.Safe.t) list

val cached_full_health_fields : Yojson.Safe.t -> (string * Yojson.Safe.t) list
