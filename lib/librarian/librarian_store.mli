(** One Keeper's Memory on disk: the snapshot and the commit log that names
    it (RFC librarian-call-only-proposes §8.2 steps 2 to 5, §8.6).

    A commit is on disk when its line is. The snapshot is written after the
    line and from it, so it is at most one line behind, and {!boot} writes it
    again from that line.

    Nothing here waits, takes the writer's lock or uses Eio. The writer holds
    [<keeper>.memory.lock] for as long as it lives and calls the commits
    where they cannot be cancelled. *)

module Current := Keeper_memory_os_current_types
module Digest := Agent_core.Checkpoint_objects

(** Why the store cannot be used. *)
type stop =
  | Log_diverged of
      { expected : Digest.digest (** The snapshot the log names. *)
      ; observed : Digest.digest (** The snapshot the file holds. *)
      }
  | Memory_unreadable (** The snapshot is absent, or is not one. *)
  | Log_unreadable (** The last line of the commit log does not decode. *)
  | Store_unwritable
  (** A read or a write failed, or there is no turn log to name. Booting
      again is the way out. *)
  | Raised of raised
  (** The writer's own code raised an exception it does not expect, while
      it booted or took an event (§9.2). No function here returns it.
      Booting again is the way out. *)

(** What was raised, as [Printexc.to_string] prints it, for an operator to
    read. Nothing matches on its words. *)
and raised = { detail : string }

(** The bytes at a snapshot path, as every reader of the file reads them
    first. No file is [Absent], something other than a regular file is
    [Not_a_snapshot_file], and a read that failed is [Not_read]. *)
val read_snapshot_bytes : string -> (string, Librarian_snapshot_fault.t) result

(** The snapshot the bytes are, or [None] when they do not decode as one. *)
val decode_snapshot : string -> Current.t option

(** The stop a snapshot fault is wherever the store meets it: absent and not
    a snapshot are [Memory_unreadable], a read that failed is
    [Store_unwritable]. *)
val stop_of_snapshot_fault : Librarian_snapshot_fault.t -> stop

(** A store whose snapshot is the one its last line names. *)
type t

(** Memory: the snapshot the last line names. *)
val memory : t -> Current.t

(** The last line. What was read, and what the Keeper was doing, are in it. *)
val tail : t -> Librarian_log.line

(** [memory_dir] holds the snapshot and the commit log, [turns_dir] the turn
    log.

    - No commit log, and a turn log: the first boot. A Keeper without a
      snapshot gets {!Librarian_envelope.empty}. A [Started] line names the
      snapshot and the place of the turn log's [Log_started]: its id, offset
      0 and its mark. A snapshot that is not one is [Memory_unreadable].
    - No commit log and no turn log, or a turn log whose first line is not a
      [Log_started]: [Store_unwritable]. [Started] has to name the turn log.
    - The last line does not decode: [Log_unreadable].
    - The snapshot is absent or is not one: [Memory_unreadable].
    - The snapshot is the one the last line names: the store.
    - The snapshot is the one the last line was committed on: it is written
      again from that line. Bytes that are not the ones the line names are
      not written: [Log_diverged].
    - Any other snapshot: [Log_diverged].
    - A read that fails for the snapshot, the commit log or the turn log, and
      a write that fails: [Store_unwritable]. A snapshot that was not read is
      not taken as absent.

    Only the first boot appends a line, so booting twice leaves what booting
    once does. *)
val boot
  :  memory_dir:string
  -> turns_dir:string
  -> keeper_id:string
  -> at:float
  -> (t, stop) result

type committed =
  | Committed of
      { store : t
      ; line : Librarian_log.commit
      }
  | Committed_without_snapshot of Librarian_log.commit
  (** The line is on disk and the snapshot was not written. The write is
      answered as usual, the store is [Store_unwritable], and {!boot} writes
      the snapshot from the line. *)
  | Stopped of stop (** No line was appended. *)
  | Not_a_snapshot of Librarian_envelope.refusal
  (** The effects do not make a snapshot from Memory. No line was appended
      and the store is as it was. *)

(** Commits a direct write whose plan is [effects]
    ({!Librarian_direct.plan} of [t]'s Memory at the same [at]).

    + The snapshot file is read. Bytes other than the ones the last line
      names are [Stopped (Log_diverged _)], no file is
      [Stopped Memory_unreadable], and a read that fails is
      [Stopped Store_unwritable].
    + The line is made: it follows the last line's [seq], is committed on the
      last line's snapshot, and carries the last line's reading position and
      working state, which a direct write does not move.
    + The line is appended at the end that was read and synced.
    + The snapshot is written.

    When the append fails, the tail is read again. This line there: it was
    appended. The line it was appended after, at the same end:
    [Stopped Store_unwritable]. Another line, or no file:
    [Stopped (Log_diverged _)]. *)
val commit_direct
  :  t
  -> at:float
  -> by:Librarian_effects.actor
  -> trace:string
  -> Librarian_direct.write
  -> Librarian_effects.t
  -> committed

(** Commits an answer whose plan is [plan] ({!Librarian_plan.of_answer} of
    [t]'s Memory at the same [at]), in the steps of {!commit_direct}. The
    line moves reading to [question.reach]: [covers_through] is [Through]
    its [line] and [within], and [covered] and [turn_log_offset] are its
    own. The turn log is the one the last line names. A [Replaced] working
    state is the line's as the answer wrote it, so [Replaced ""] leaves the
    empty text; [Kept] and [Not_valid_alone] carry the last line's.

    The cause is a [Read] of the question's id, trace and missing parts, by
    [slot]. Effects that add, see or remove a fact rewrite the snapshot with
    [librarian] as its source on [question.trace]. Effects that do none of
    these leave it: [after] is [basis] and the snapshot is not written. *)
val commit_read
  :  t
  -> at:float
  -> question:Librarian_read_result.question
  -> slot:string
  -> Librarian_plan.t
  -> committed

(** Commits an answer to the question that makes room (§7.4, §8.4), in the
    steps of {!commit_direct}. The line does not move reading: it carries the
    last line's reading position, so [covers_through] is where the item read
    alone ended. Its working state is the plan's as {!commit_read} takes it.
    The cause is a [Make_room] of the question's id and trace, by [slot].
    Effects that add, see or remove a fact rewrite the snapshot with
    [librarian] as its source on [question.trace]. The writer commits only a
    plan that {!changes}. *)
val commit_room
  :  t
  -> at:float
  -> question:Librarian_room_result.question
  -> slot:string
  -> Librarian_plan.t
  -> committed

(** Whether committing [plan] without moving reading changes anything: its
    effects add, see or remove a fact, or its working state is not the one
    the last line holds. [""] and no working state are the same: both hold
    none. An op that was not applied is no change: only an answer with an
    op that takes effect is committed (§7.4). *)
val changes : t -> Librarian_plan.t -> bool

(** Passes [hole] with no answer, in the steps of {!commit_direct}: the line
    moves reading to [reach] as {!commit_read} does, has no effects, keeps
    the working state, and leaves the snapshot: [after] is [basis]. *)
val commit_skip
  :  t
  -> at:float
  -> hole:Librarian_log.hole
  -> Librarian_read_result.reach
  -> committed

(** An operator's [Restart_reading] (§12.4): a [Skip] of [hole] whose line
    names [start]'s turn log and reads it from its first line, as a first
    boot does. Like {!commit_skip}, it keeps the working state and leaves
    the snapshot. *)
val commit_restart
  :  t
  -> at:float
  -> hole:Librarian_log.hole
  -> start:Keeper_turn_log_store.start
  -> committed

type adoption_refusal =
  | Snapshot_mismatch (** The snapshot file does not hold the bytes named. *)
  | Snapshot_unreadable (** It holds them, and they are not a snapshot. *)
  | Not_adopted of stop
  (** A read or a write failed, or reading has to start over and there is no
      turn log to name. Nothing the store holds was changed. *)

(** An operator says the bytes the snapshot file holds are Memory
    (RFC §8.7): the way out of a store stopped as [Log_diverged] or
    [Log_unreadable]. [observed] names those bytes. The writer decides
    whether a stopped store may be adopted; this does not look at why it
    stopped.

    The line it appends is read from the log as it is now.

    - The last line decodes: a commit whose cause is the adoption, committed
      on the snapshot that line names. Reading goes on where that line says.
    - The last line does not decode, or there is none: a [Started] line that
      names [observed]. The place reading had reached was in the line that is
      lost, so the turn log is read from its first line again.

    The snapshot file is not written. *)
val adopt
  :  memory_dir:string
  -> turns_dir:string
  -> keeper_id:string
  -> at:float
  -> by:string
  -> observed:Digest.digest
  -> (t, adoption_refusal) result
