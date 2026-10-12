(** A child that outlives the switch it was started on.

    It is started with posix_spawn(2), as {!Posix_spawn_process_mgr} starts
    its children, so a server running several domains can start it (fork(2)
    is refused there, which rules out {!Process_eio_detached}). It runs in a
    process group of its own (not a session of its own), reads [/dev/null]
    and writes [output] on both stdout and stderr. Nothing stops it on its
    own: when [sw] is released this process only stops waiting for it, and
    once this process has exited the child is reaped by whoever adopts it.
    A caller that no longer wants it runs {!stop_group}, also once this
    process has exited and another holds only its number. *)

type t = {
  pid : int;  (** Also the child's process group. *)
  started : string option;
      (** When the child started ({!process_start}), read before anything
          here could reap it, so the number was still the child's. *)
  exited : Unix.process_status option Eio.Promise.t;
      (** Resolved when the child is reaped while [sw] is still on; never
          resolved after [sw] is released. [None] when another waiter in this
          process reaped it first, so its status is not known here. *)
}

(** [argv]'s first element is the executable's path, used as given: no PATH
    lookup. [output] may be any descriptor, standard ones included. [Error]
    names the call that failed, what it failed on and why: posix_spawn and
    the executable, or the opening or copying of a descriptor. *)
val spawn :
  sw:Eio.Switch.t ->
  argv:string list ->
  env:string array ->
  output:Unix.file_descr ->
  (t, string) result

(** Whether a process other than a reaped child is left in [t]'s group: the
    child's own children stay there unless they leave it. Darwin answers
    EPERM for a group whose members are all exiting or zombies, which reads
    as none left (see {!Process_group_members}). *)
val group_has_members : t -> bool

(** Whether a process is left in the group numbered [group]. [false] for 0
    and 1, which kill(2) reads as this process's own group and as every
    process: so neither is ever signalled here. A group whose processes
    another account owns is there, whether or not this process may signal
    it. *)
val group_id_has_members : int -> bool

type stopped =
  | Ended_on_term  (** The group emptied within the grace after SIGTERM. *)
  | Killed_after_grace
      (** Members were left after the grace and got SIGKILL. The stop waits up
          to a second more for them to end; whether they did is
          {!group_id_has_members}' to say. *)
  | Left_alone
      (** [same_group] said the number no longer names the group meant, so
          the signal due then was not sent. *)

(** Ends the group numbered [group]: SIGTERM, then SIGKILL for whatever is
    left after [grace_s] seconds. Before each signal [same_group ()] says
    whether the number still names the group meant: a group that empties
    gives its number up, and a later process may lead a group with it. Only
    that group is signalled, and only while it has members. *)
val stop_group :
  clock:_ Eio.Time.clock -> grace_s:float -> same_group:(unit -> bool) -> int -> stopped

(** When the process numbered [pid] started, as a token no later process
    given that number shares: Darwin's p_starttime to the microsecond, from
    the kernel's process table; Linux's boot id and /proc starttime. A child
    not yet reaped still reads. [None] when no such process is there, or
    the platform gives neither. It starts no process, so it never yields. *)
val process_start : int -> string option

(** The process group [pid] is in now (getpgid(2)). [Error] when it cannot be
    told, a process that no longer runs among them. *)
val group_of_pid : int -> (int, string) result
