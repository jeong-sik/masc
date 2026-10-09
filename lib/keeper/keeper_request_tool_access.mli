(** Tools actually offered by one request and the deferred tools its live
    discovery loader can obtain. This is not a projection from runtime metadata. *)
type t

type route = Direct | Discoverable | Unavailable

val create :
  offered:Agent_core.Tool.t list -> deferred_names:string list ->
  loader_alive:bool -> t

val offered : t -> Agent_core.Tool.t list
val route : t -> name:string -> route
