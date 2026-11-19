(** One Keeper's writer: the fiber that owns its Memory store
    (RFC librarian-call-only-proposes §8.2, §8.6, §9).

    The fiber takes [<keeper>.memory.lock], boots the store, and then takes
    one event at a time from its mailbox. What an event does is
    {!Librarian_machine}'s to say. A write waits for one commit and for
    nothing else: events that arrive during the boot wait in the mailbox and
    are handled in the order they came.

    A reader does not go through the mailbox. {!status} is a value the
    writer replaces after every event. *)

module Digest := Agent_core.Checkpoint_objects

type t

(** What a Keeper's request reads: how far the turn log is read, and what the
    Keeper was doing (§11.1). *)
type view =
  { covers_through : Librarian_log.position
  ; covered : Keeper_turn_log.mark
  ; working_state : string option
  }

(** The view a line of the commit log gives. *)
val view : Librarian_log.line -> view

type status =
  | Booting (** The lock or the store is being opened. *)
  | Open of Librarian_log.line (** The last line of the commit log. *)
  | Stopped of Librarian_store.stop
  | Retired (** The fiber has ended. This writer takes nothing more. *)

(** Starts the fiber on [sw]. It ends when the writer retires or [sw] does.

    [now] stamps every line. [registered] says whether the Keeper is in the
    Keeper registry: a {!retire} that finds it there is dropped.

    The lock is taken without waiting. A writer that does not get it is
    [Stopped Store_unwritable], and {!resume} tries again. The lock is held
    until the fiber ends. *)
val start
  :  sw:Eio.Switch.t
  -> now:(unit -> float)
  -> registered:(unit -> bool)
  -> Librarian_machine.place
  -> t

val status : t -> status

(** A direct write. Returns when the writer has answered it: for a write
    that commits, after the line is synced and the snapshot written. *)
val write
  :  t
  -> by:Librarian_effects.actor
  -> trace:string
  -> Librarian_direct.write
  -> Librarian_machine.write_answer

val resume : t -> Librarian_machine.act_answer
val adopt : t -> by:string -> observed:Digest.digest -> Librarian_machine.act_answer

type retirement =
  | Retired_now (** The lock is released and the fiber has ended. *)
  | Still_registered (** The Keeper is registered. The writer goes on. *)

(** Ends the writer of a Keeper that is no longer registered. Returns after
    the lock is released, so the Keeper's files can be removed. *)
val retire : t -> retirement
