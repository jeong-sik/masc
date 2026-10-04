(** Connect Browser admission to the configuration published by Runtime.
    Each new request reads that snapshot; close/status and accepted work
    remain independent of later activity changes. *)
val install_activity_observer : sw:Eio.Switch.t -> unit

(** Capture one immutable configuration for all Browser rows in an inventory. *)
val activity_snapshot : unit -> Browser_lane.Lane_name.t -> Browser_lane.activity
