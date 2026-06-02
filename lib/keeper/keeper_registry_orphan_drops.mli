(** Orphan update-drop window accounting for {!Keeper_registry}.

    This module owns the small mutable CAS state used to decide when repeated
    updates against a missing keeper should escalate from DEBUG-only drops to
    the single threshold WARN/metric edge. *)

val threshold : int
(** Number of drops inside {!window_sec} that trips the edge. *)

val window_sec : float
(** Drop-count window in seconds. *)

val record : base_path:string -> string -> int * bool
(** Record one orphan drop for [(base_path, name)].

    Returns [(count, breached_now)]. [breached_now] is [true] exactly on the
    transition from below-threshold to at-threshold within an active window. *)

val clear : base_path:string -> string -> unit
(** Clear drop state for [(base_path, name)] after the keeper is found again. *)
