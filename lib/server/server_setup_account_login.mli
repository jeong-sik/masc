(** Call only after CanAdmin authentication. Session control also checks the
    authenticated actor and canonical workspace. No browser paths or commands. *)
val start : actor:string -> base_path:string -> body:string ->
  Httpun.Request.t -> Httpun.Reqd.t -> unit
val control : actor:string -> base_path:string -> body:string ->
  Httpun.Request.t -> Httpun.Reqd.t -> unit

val status : actor:string -> base_path:string ->
  Httpun.Request.t -> Httpun.Reqd.t -> unit
