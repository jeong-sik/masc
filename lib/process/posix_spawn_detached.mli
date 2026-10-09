(** A child that outlives the switch it was started on.

    It is started with posix_spawn(2), as {!Posix_spawn_process_mgr} starts
    its children, so a server running several domains can start it (fork(2)
    is refused there, which rules out {!Process_eio_detached}). It runs in a
    process group of its own (not a session of its own), reads [/dev/null]
    and writes [output] on both stdout and stderr. Nothing stops it on its
    own: when [sw] is released this process only stops waiting for it, and
    once this process has exited the child is reaped by whoever adopts it;
    a caller that no longer wants it runs {!stop_group}. *)

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

(** Asks [t]'s process group to end: SIGTERM first, SIGKILL once [grace_s]
    has passed with members still there. Best effort — a group that already
    ended, or a pid the OS gave to another process, reads as stopped, and
    nothing outside the group is signalled. *)
val stop_group : clock:'a Eio.Time.clock -> ?grace_s:float -> t -> unit
