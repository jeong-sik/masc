(** One Keeper's writer: the fiber that owns its Memory store
    (RFC librarian-call-only-proposes §8.2, §8.6, §9).

    The fiber takes [<keeper>.memory.lock], starts the store (the turn log's
    first line, then the boot: §8.6), and then takes one event at a time
    from its mailbox. What an event does is
    {!Librarian_machine}'s to say. A write waits for one commit and for
    nothing else: events that arrive during the boot wait in the mailbox and
    are handled in the order they came.

    An ask runs in a fiber of its own, on the writer's switch, and its
    result comes back through the mailbox. After every event the writer
    starts or cancels that fiber as {!Librarian_machine.fiber_change} says.
    A commit is not cancelled. A writer that ends cancels its ask. The ask
    reads the tail the writer shows while it waits for its next event, so
    it never reads a commit halfway.

    A reader does not go through the mailbox. {!status} is a value the
    writer replaces after every event.

    The writer says when the snapshot file holds a new revision, through
    {!Keeper_memory_commit_notifications}: after a commit that rewrote it,
    and when the store opens. The caller of a write has its answer first.

    Every function here can be called from any domain. {!run} is the
    exception: it is the fiber. *)

module Digest := Agent_core.Checkpoint_objects

type t

(** The writer's lock is [<keeper><lock_suffix>] in the Memory directory. The
    file is empty: only holding it means anything. *)
val lock_suffix : string

val lock_path_for_keepers_dir : keepers_dir:string -> keeper_id:string -> string

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

(** A writer that is [Booting] and does nothing until {!run}. What is sent
    to it before then waits in its mailbox.

    - [now] stamps every line.
    - [registered] says whether the Keeper is in the Keeper registry: a
      {!retire} that finds it there is dropped.
    - [declared] is the declaration of now. The writer boots with none and
      reads this as its first event, and again for every
      {!declaration_changed}.
    - [ask] asks one question ({!Librarian_ask.run}) about the Keeper's
      stores [stores]. It and [ask_room] run in a fiber under the writer's
      switch, so they answer every failure as a result: only cancellation
      and the reserved exceptions ({!Llm_provider.Reserved_exn}) leave them.
    - [start_turn_log] is the store start's first step
      ({!Keeper_turn_log_store_start.run}), run before every boot: the first
      and the one a [Resume] does. [Error] stops the store as
      [Store_unwritable], with its text in the log. The writer only calls
      it: it writes no turn log line itself. *)
val create
  :  now:(unit -> float)
  -> registered:(unit -> bool)
  -> declared:(unit -> Librarian_machine.declared option)
  -> stores:Librarian_unit_content.stores
  -> ask:(Librarian_ask.input -> Librarian_read_result.t)
  -> ask_room:(Librarian_ask.room_input -> Librarian_room_result.t)
  -> start_turn_log:(unit -> (unit, string) result)
  -> Librarian_machine.place
  -> t

(** The writer's fiber: call it once, in a fiber of its own. It returns when
    the writer retires. An exception its own code raises while it boots or
    takes an event stops this writer as [Stopped (Raised _)], and the fiber
    goes on taking events (§9.2). Only cancellation and the reserved
    exceptions leave it, and they end the switch it runs in.

    The lock is taken without waiting. A writer that does not get it is
    [Stopped Store_unwritable], and {!resume} tries again. The lock is held
    until [run] returns. *)
val run : t -> unit

val status : t -> status

(** What the writer holds, for the operator's row (§12): the value of its
    state machine while it runs, which {!status} is read from. *)
type held =
  | Held_booting (** The lock or the store is being opened. *)
  | Held of Librarian_machine.t
  | Held_retired (** The fiber has ended. *)

val held : t -> held

(** A [Closed] or a [Reset] line was appended to the Keeper's turn log. The
    hint carries nothing: the writer reads the turn log. *)
val turn_closed : t -> unit

(** The maintenance tick. *)
val pulse : t -> unit

(** The declaration may have changed. The writer reads it when it takes
    this. *)
val declaration_changed : t -> unit

type 'answer asked =
  | Answered of 'answer
  | Ended
  (** The writer ended before it took the request. Nothing was done with
      it. Whether the Keeper has another writer is the registry's to say. *)

(** A direct write. Returns when the writer has answered it: for a write
    that commits, after the line is synced and the snapshot written. *)
val write
  :  t
  -> by:Librarian_effects.actor
  -> trace:string
  -> Librarian_direct.write
  -> Librarian_machine.write_answer asked

val resume : t -> Librarian_machine.act_answer asked
val adopt : t -> by:string -> observed:Digest.digest -> Librarian_machine.act_answer asked

val restart_reading
  :  t
  -> observed:Keeper_turn_log.Log_id.t
  -> Librarian_machine.act_answer asked

type retirement =
  | Retired_now (** The lock is released and the fiber has ended. *)
  | Still_registered (** The Keeper is registered. The writer goes on. *)

(** Ends the writer of a Keeper that is no longer registered. Returns after
    the lock is released, so the Keeper's files can be removed. A writer
    that has ended already is [Retired_now]. *)
val retire : t -> retirement
