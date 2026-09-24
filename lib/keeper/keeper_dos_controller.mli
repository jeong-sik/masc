(** Frees the DOS controller of a holder whose Keeper stopped, before a
    Keeper's call that needs the controller. *)

val holder_left : base_path:string -> string -> bool
(** [true] when [holder] is a Keeper that is paused, stopped, crashed or
    offline. A name with no registry entry is [false]. *)

val before_move : base_path:string -> who:string -> unit
(** Lets a stopped holder's controller go so that [who] can take it, and
    queues the board announcement; the tool call that follows posts it. *)
