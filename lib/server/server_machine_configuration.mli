(** Bind both machine owners to the atomic Runtime configuration. Installing or
    removing this observer never touches a machine, controller or checkpoint. *)
val install_activity_observers : sw:Eio.Switch.t -> unit
