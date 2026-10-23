(** The host's pass over Gecko profiles whose automation instance has ended.

    A Gecko browser can leave its worker's process group, for example by
    relaunching itself to apply an update, and it can recreate a deleted
    profile path when it does. The worker group's settlement therefore says
    nothing about it. Each pass looks at the instance directories its {!plan}
    named:
    - a profile nobody holds is locked by this process and removed under the
      lock;
    - a holder is sent SIGTERM;
    - a holder that still holds the profile, as the same process incarnation,
      the grace after its SIGTERM is sent SIGKILL.

    The grace bounds how long a process masc started may outlive its
    instance; it gates no work. Pending SIGTERMs are kept in memory, so after
    a restart the next pass starts again with SIGTERM. *)

type t

val termination_grace_seconds : float
(** 70 s, the grace the host uses. Firefox's shutdown watchdog crashes a
    shutdown that has not finished after [toolkit.asyncshutdown.crash_timeout]
    (60 s by default) plus [toolkit.asyncshutdown.crash_timeout_additional_wait]
    (10 s), in [toolkit/components/terminator/nsTerminator.cpp]. A holder still
    there after that is not shutting down. *)

val create : termination_grace_seconds:float -> t

type plan

val plan : root:string -> sweepable:(string -> bool) -> plan
(** Reads [root] once and keeps the instance directories [sweepable] accepts.
    Instance ids are never reused, so an instance accepted here cannot start
    again before the pass reaches it, and a directory made after this read is
    not in the plan. Make the plan where [sweepable] is decided; it is one
    directory read. *)

type signalled = { profile : string; pid : int; executable : string option }

type outcome =
  | Removed of string
  | Terminated of signalled
  | Killed of signalled
  | Kept of { path : string; reason : string }

val pass : t -> plan -> outcome list
(** The plan's blocking file and signal work, for a systhread. Passes on one
    [t] run one at a time. A profile whose holder got SIGTERM less than the
    grace ago yields no outcome. *)

val outcome_to_string : outcome -> string
