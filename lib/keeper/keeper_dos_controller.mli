(** Frees the DOS controller of a holder who can no longer move, before a
    Keeper or HTTP caller's next move. *)

val holder_left : config:Workspace.config -> now:float -> string -> Tool_misc_dos_lane.holder_departure option
(** Returns why a controller holder can no longer act: a paused or stopped
    Keeper, or an expired Player credential. A missing or unreadable Player
    credential does not prove the holder has left. *)

val before_move : config:Workspace.config -> who:string -> unit
(** Lets a departed holder's controller go so that [who] can take it, and
    posts the board announcement. *)
