(** Frees the DOS controller of a holder whose Keeper stopped, before a
    Keeper's call that needs the controller. *)

val holder_left : config:Workspace.config -> string -> bool
(** [true] when [holder] is a Keeper that is paused or stopped, including a
    Keeper whose stop finished and left the registry but kept its meta.
    [false] for a Keeper that is running or on its way back, and for a name
    that is not a Keeper. *)

val before_move : config:Workspace.config -> who:string -> unit
(** Lets a stopped holder's controller go so that [who] can take it, and
    posts the board announcement. *)
