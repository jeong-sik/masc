(** Synchronous ownership of one foreground process group. The leader remains
    waitable until the last group signal, so a recycled PID is never signalled.
    Descendants which deliberately leave the group are outside this contract. *)
type t

val create : unit -> t
(** Allocate ownership before starting the child. *)

val spawn :
  t -> string -> string list -> string array ->
  Unix.file_descr -> Unix.file_descr -> Unix.file_descr -> unit
(** Uses libc PATH lookup, just like [Unix.create_process_env]. *)

val poll : t -> Unix.process_status option
(** [None] means the leader is still running. On exit, clean remaining group
    members and reap the leader before returning its status. *)

val terminate : t -> Unix.process_status
(** Kill the owned group and reap its leader. Idempotent after completion.
    Matches the synchronous runner's existing immediate-KILL timeout policy. *)

val close : t -> unit
(** Release an owner, including one whose spawn failed before a child existed. *)
