(** What a process group signal that reached nobody means.

    Darwin's kill(2) to a process group answers EPERM when it signalled no
    member (XNU [killpg1], bsd/kern/kern_sig.c). It skips zombies, and it
    also skips a member whose exit has passed the point where it leaves the
    process lookup ([proc_prepareexit] sets [P_REF_DEAD], so [proc_find] in
    [pgrp_iterate] returns nothing) but has not yet become a zombie. Both are
    already on their way out. A member that is neither is alive, and an
    EPERM with such a member in the group is a real permission refusal. *)

type state =
  | Zombie
  | Exiting  (** Exit has begun ([P_WEXIT]); not yet a zombie. *)
  | Live

type member = { pid : int; parent : int; state : state }

val no_live_member : leader:int -> owner:int -> member list -> bool
(** [true] when the group still holds its [leader], a child of [owner] (so
    the numeric group id has not been reused), and every member is a zombie
    or exiting. An empty list names no leader and is [false]. *)

val group_has_no_live_member : int -> bool
(** {!no_live_member} for the group led by this process's own child [pgid],
    from the kernel's member snapshot. [false] when there is no snapshot,
    which is every platform but Darwin. *)
