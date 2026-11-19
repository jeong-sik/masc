(** What one event does to one Keeper's writer
    (RFC librarian-call-only-proposes §9.3), for the states and events that
    exist before the Librarian asks a model: the store is open, stopped, or
    its Keeper is gone, and what arrives is a direct write or an operator's
    act.

    Every function is synchronous and returns the next state with the
    answer. The store does the I/O. The fiber that owns a Keeper's writer
    boots first and then calls one of these for each event it takes from its
    mailbox, where it cannot be cancelled; events that arrive during the
    boot wait there. *)

module Digest := Agent_core.Checkpoint_objects

(** Where one Keeper's files are: the snapshot and the commit log in
    [memory_dir], the turn log in [turns_dir]. *)
type place =
  { memory_dir : string
  ; turns_dir : string
  ; keeper_id : string
  }

type state =
  | Idle of Librarian_store.t (** The store is open. Nothing is being asked. *)
  | Stopped of Librarian_store.stop

(** Opens the store: [Idle], or [Stopped] with the reason. *)
val boot : place -> at:float -> state

(** Why a Keeper's Memory takes neither a write nor an act. *)
type unavailable =
  | Store_stopped of Librarian_store.stop
  | Keeper_retired
  (** The Keeper is not registered, so it has no writer. No state here
      answers this: a writer that retires ends, and whoever looks for the
      Keeper's writer finds none. *)

type write_answer =
  | Written of Librarian_log.commit (** The line that was committed. *)
  | Already_held
  | Already_done
  | Already_absent
  | Refused of Librarian_direct.refusal
  | Not_a_snapshot of Librarian_envelope.refusal
  (** The plan's effects do not make a snapshot. Nothing was written. *)
  | Unavailable of unavailable

(** A direct write (§8.5).

    - [Idle]: the write is planned against Memory and, when the plan writes,
      committed. An answer that writes no line leaves the state as it was.
    - A commit that finds the snapshot or the log other than it left them
      stops the store, and the write is [Unavailable (Store_stopped _)].
    - A commit whose line is on disk and whose snapshot is not is answered
      [Written]: it is committed. The store stops as [Store_unwritable] and
      the next boot writes the snapshot from the line.
    - [Stopped s]: [Unavailable (Store_stopped s)]. *)
val write
  :  state
  -> at:float
  -> by:Librarian_effects.actor
  -> trace:string
  -> Librarian_direct.write
  -> state * write_answer

type act_refusal =
  | Nothing_to_resume
  | Not_stopped
  | Snapshot_mismatch
  | Snapshot_unreadable
  | Act_unavailable of unavailable

type act_answer =
  | Done
  | Not_done of act_refusal

(** An operator starts a stopped store again: [boot], once more. The writer
    passes the boot it ran when it started, which takes its lock before it
    opens the store. [Done] says the boot ran; the state says how it ended.
    A store that is not stopped is [Not_done Nothing_to_resume], and [boot]
    is not called. *)
val resume : boot:(unit -> state) -> state -> state * act_answer

(** An operator adopts the snapshot file of a store stopped as
    [Log_diverged] or [Log_unreadable] (§8.7). A store stopped for another
    reason is [Act_unavailable (Store_stopped _)]: booting again is its way
    out. A store that is not stopped is [Not_stopped]. A refusal leaves the
    state as it was. *)
val adopt
  :  place
  -> state
  -> at:float
  -> by:string
  -> observed:Digest.digest
  -> state * act_answer
