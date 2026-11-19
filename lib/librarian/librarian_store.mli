(** One Keeper's Memory on disk: the snapshot and the commit log that names
    it (RFC librarian-call-only-proposes §8.2 steps 2 to 5, §8.6).

    A commit is on disk when its line is. The snapshot is written after the
    line and from it, so it is at most one line behind, and {!boot} writes it
    again from that line.

    Nothing here waits, takes the writer's lock or uses Eio. The writer holds
    [<keeper>.memory.lock] for as long as it lives and calls {!commit_direct}
    where it cannot be cancelled. *)

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
    - A read that fails for the commit log or the turn log, and a write that
      fails: [Store_unwritable].

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
      names are [Stopped (Log_diverged _)].
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
