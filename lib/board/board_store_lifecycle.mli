(** Force the sole protected lazy store. Root resolution, construction and
    ordered best-effort loading happen inside the force callback. *)
val global : unit -> Board_types.store

(** Test setup only, before concurrent fibers exist. Root resolution and store
    creation remain deferred until the next force. *)
val reset_global_for_test : unit -> unit
