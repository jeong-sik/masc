val fd_warn_threshold : int option
(** fd-pressure admission threshold. [None] disables the gate (and its
    per-call [/dev/fd] scan); [Some n] rejects admission at 90% of [n]. *)

val approximate_open_fd_count : unit -> int
