(** The host's pass over Gecko profiles whose automation instance has ended.

    A Gecko browser can leave its worker's process group, for example by
    relaunching itself to apply an update, and it can recreate a deleted
    profile path when it does. The worker group's settlement therefore says
    nothing about it. Each pass looks at every instance directory under the
    profile root that no live instance owns:
    - a profile nobody holds is locked by this process and removed under the
      lock;
    - a holder is sent SIGTERM;
    - a holder that still holds the profile on the next pass, as the same
      process incarnation, is sent SIGKILL.

    The grace between the two signals is one pass. It bounds how long a
    process masc started may outlive its instance; it gates no work. The
    pending SIGTERMs are kept in memory, so after a restart the next pass
    starts again with SIGTERM. *)

type t

val create : unit -> t

type signalled = { profile : string; pid : int; executable : string option }

type outcome =
  | Removed of string
  | Terminated of signalled
  | Killed of signalled
  | Kept of { path : string; reason : string }

val pass : t -> root:string -> live:(string -> bool) -> outcome list
(** [live instance_id] is true for an instance the host still owns, including
    one whose cleanup is pending or that the operator retained; its directory
    is not touched. *)

val outcome_to_string : outcome -> string
