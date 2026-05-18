(** Registry orphan-update drop tracker. *)

val window_sec : float

(** Record one dropped registry update for [name] under [base_path].
    Returns [(count, breached_now)], where [breached_now] is true only when
    the count crosses the threshold in the active window. *)
val record : base_path:string -> string -> int * bool

(** Clear the drop window for a keeper after a successful registry update. *)
val clear : base_path:string -> string -> unit
