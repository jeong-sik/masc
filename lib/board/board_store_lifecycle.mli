(** Force the sole protected lazy store. Root resolution, construction and
    ordered best-effort loading happen inside the force callback. *)
val initialize_store : Board_types.store -> (unit, Board_types.board_error) result
(** Quiescent fresh-store initialization shared by explicit stores and global.
    Loads all sources best effort and recovers an original deletion decision.
    Refused/unknown owners cannot be reset by calling this again. *)

val global : unit -> Board_types.store

(** Test setup only, before concurrent fibers exist. Root resolution and store
    creation remain deferred until the next force. *)
val reset_global_for_test : unit -> unit
