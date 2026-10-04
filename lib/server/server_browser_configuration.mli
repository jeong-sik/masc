(** Connect Browser admission to the configuration published by Runtime.
    Each new request reads that snapshot; close/status and accepted work
    remain independent of later activity changes. *)
val install_activity_observer : sw:Eio.Switch.t -> unit
