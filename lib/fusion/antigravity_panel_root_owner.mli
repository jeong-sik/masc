(** Durable ownership of a disposable Antigravity HOME. The panel runtime uses
    a foreground process manager, whose child leads its own process group. *)

val initialize : root:string -> (unit, string) result
(** Publish that preparation has not attempted to spawn a client. Must finish
    before copying credentials or starting a client. *)

val before_spawn : root:string -> (unit, string) result
(** Publish uncertainty before entering the spawn boundary. A crash before the
    process group is recorded retains the HOME, even if no child was started. *)

val spawned : root:string -> pid:int -> (unit, string) result
(** Record the foreground child's group, including native tools that remain
    in it after the leader exits. Does not rely on inherited file descriptors. *)

val can_remove : root:string -> bool
(** True only for an owned, private, valid record that says no spawn was
    attempted, or whose recorded process group no longer exists (ESRCH).
    Missing, malformed, pending or unreadable ownership retains the HOME.
    Sweep callers must additionally establish that the creator has exited;
    normal cleanup runs only after the preparation/runtime scope has ended.
    Deliberately detached descendants are outside the foreground group contract. *)
