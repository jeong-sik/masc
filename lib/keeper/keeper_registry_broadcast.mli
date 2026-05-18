(** Keeper registry dashboard broadcast helpers. *)

val composite_changed : name:string -> ts_unix:float -> unit
val phase_failure : name:string -> exn -> unit
