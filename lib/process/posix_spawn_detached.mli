(** A child that outlives the switch it was started on.

    It is started with posix_spawn(2), as {!Posix_spawn_process_mgr} starts
    its children, so a server running several domains can start it (fork(2)
    is refused there, which rules out {!Process_eio_detached}). It runs in a
    process group of its own (not a session of its own), reads [/dev/null]
    and writes [output] on both stdout and stderr. Nothing stops it on its
    own: when [sw] is released this process only stops waiting for it, and
    once this process has exited the child is reaped by whoever adopts it.
    A caller that no longer wants it runs {!stop_group}; once this process
    has exited, only {!stop_group_id} can reach it. *)

type t = {
  pid : int;  (** Also the child's process group. *)
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

(** Sends [signal] to every process in [t]'s group while one is left; a
    group with none left is not signalled, since its id may then name
    another group. *)
val signal_group : t -> int -> unit

type stopped =
  | Ended_on_term  (** The group emptied within the grace after SIGTERM. *)
  | Killed_after_grace  (** Members were left after the grace and got SIGKILL. *)

(** Ends [t]'s group: SIGTERM, then SIGKILL for whatever is left after
    [grace_s] seconds. Only that group is signalled, and only while it has
    members. *)
val stop_group : clock:_ Eio.Time.clock -> grace_s:float -> t -> stopped

(** {!group_has_members} for a group known only by its number. *)
val group_id_has_members : int -> bool

(** {!stop_group} for a group known only by its number: one started by a
    process that has since exited, such as a server before its restart.
    Whether the number still names that group is the caller's to establish
    first; a group that emptied may give its number to another. *)
val stop_group_id : clock:_ Eio.Time.clock -> grace_s:float -> int -> stopped

(** The process group [pid] is in now (getpgid(2)). [Error] when it cannot be
    told, a process that no longer runs among them. *)
val group_of_pid : int -> (int, string) result
