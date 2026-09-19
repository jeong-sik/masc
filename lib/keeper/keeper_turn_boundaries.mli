(** Where each finished keeper turn left the durable history (RFC
    librarian-lifecycle §4.6).

    A finished turn appends one line to a per-keeper append-only
    [<keeper>.turn-boundaries.jsonl], after its checkpoint is saved. The line
    names the turn and the end of the saved history in the atom vocabulary of
    {!Runtime_model_input_tail_window}: how many atoms the checkpoint holds and
    the digest of the message that opens the last one. A turn's start is not
    written; the end an earlier line states is that start.

    {2 What a reader may rely on}

    - A line that cannot be built or written does not fail the turn: the
      checkpoint is already durable. After a transient append failure the next
      line's span covers both turns, so nothing is lost.
    - A crash in the middle of an append can leave the file ending mid-line.
      Every later append is then refused until process-start recovery
      ([Fs_compat.recover_private_jsonl_durable_locked_result]) truncates the
      torn tail. That call belongs to the reader's boot path (RFC §8 step 4),
      not to this module; until it runs, turns of that keeper go unrecorded.
    - A reader orders the [Atom_history] lines of one trace by [end_atom], not
      by their position in the file: a position is a value, and a value does
      not depend on when a line reached the file. Turns of one keeper do not
      overlap -- the Keeper Owner runs one child turn at a time and holds that
      slot until the whole child returns, so the append is inside it
      ({!Keeper_owner}) -- and a reader may rely on that. [turn_ref] is still
      not a key: the turn number is read from the keeper's meta when the turn
      starts, and a trace rotation changes the trace while that count keeps
      running.
    - [last_atom_digest] is computed from the checkpoint the save returned. On
      the store's payload-encode recovery path the bytes on disk are a recovery
      copy with the unencodable json dropped, while the save still returns the
      original (masc #37018). If the message that opens the last atom carried
      that json, the digest describes bytes that were not stored. Rare.

    The file is never rewritten or trimmed -- not by this module and not by
    anything else. The one thing that removes it removes it whole: the keeper
    purge, whose artifact list is fixed in code and not chosen per run
    ({!Keeper_shutdown_types.dashboard_purge_artifact_plan}). So line [n] of this
    file is line [n] for as long as the file exists, and a reader that counts
    lines is counting something that does not shift under it.

    That is the trade this file makes, so the size is worth stating. One line
    per finished turn, 266 bytes for a line whose digest is a sha256; the live
    fleet ran 61 turns per keeper per day over 2026-09-18..19, which is 5.9 MB
    per keeper per year. If that ever has to be bounded, the bound cannot be a
    trim -- it has to drop the whole file, the way the purge does, together
    with whatever reads it. *)

type position =
  | Atom_history of
      { end_atom : int
      ; last_atom_digest : string
      }
      (** The saved checkpoint holds [end_atom] atoms, so [end_atom] is the
          exclusive end of its history. [last_atom_digest] is
          {!Runtime_model_input_tail_window.atom_opening_digest} of atom
          [end_atom - 1]. *)
  | Empty_atom_history  (** A checkpoint was saved and holds no atom. *)
  | No_atom_history
      (** The runtime keeps no Agent-Core checkpoint (an official client), so
          the turn has no atom history to end. *)
  | Stale_noop
      (** An Agent-Core turn whose checkpoint save was a stale no-op: a newer
          writer owns the canonical checkpoint, and this turn's messages are
          not in the durable history. The line is kept, with no span of its
          own, because a reader counts finished turns in lines. *)

(** Whether the turn began from a durable history. The keeper run context
    already knows this ([Keeper_run_context.loaded_checkpoint_present]); a
    reader cannot infer it. [Fresh_history] covers every way a history starts
    over without a marker of its own: a new trace, a purged or superseded
    checkpoint, and a checkpoint that could not be read. *)
type history_at_start =
  | Fresh_history  (** No checkpoint was loaded: the history began empty. *)
  | Continued_history  (** A checkpoint was loaded and the turn appended to it. *)

(** What a line states. One constructor today. The wire form carries a [kind]
    tag from the first line ever written, so a later kind of line is a new
    constructor rather than a new field on a strictly decoded line. *)
type event =
  | Turn_ended of
      { turn_ref : Ids.Turn_ref.t
            (** The finished turn. Its trace id is the keeper trace id, which
                is also the session id of the checkpoint. *)
      ; history_at_start : history_at_start
      ; position : position
      }

type record =
  { recorded_at : float (** Unix seconds, when the finished turn built its line. *)
  ; event : event
  }

val path_for_keepers_dir : keepers_dir:string -> keeper_id:string -> string

(** {1 Position} *)

(** The position of a saved checkpoint's messages. Pure. No atom is
    [Empty_atom_history]. [Error] when
    {!Runtime_model_input_tail_window.annotate} counts atoms and
    {!Runtime_model_input_tail_window.atom_opening_digest} has no opening
    message for the last one; no digest is made up for it. *)
val position_of_messages : Agent_core.Types.message list -> (position, string) result

(** {1 Codec} *)

val record_to_json : record -> Yojson.Safe.t

(** Field-exact for the line's [kind], and [position] is field-exact for its
    own [kind]: an unknown [kind], an unknown [history_at_start] token, or a
    field its kind does not carry is rejected, never defaulted. [recorded_at]
    must be finite, [last_atom_digest] non-blank, [end_atom] at least one, and
    [turn_ref] a reference {!Ids.Turn_ref.of_string} reads back. *)
val record_of_json : Yojson.Safe.t -> (record, Keeper_memory_os_types.wire_error) result

(** {1 Store} *)

type append_error =
  | Invalid_record of Keeper_memory_os_types.wire_error
  | Write_failed of
      { path : string
      ; message : string
      }

val append_error_to_string : append_error -> string

(** One record in one durable append -- fsynced, and rolled back when the
    write fails -- or an error and nothing written. A record {!record_of_json}
    would reject is not written. A store that ends mid-line refuses the
    append, as every durable JSONL store here does, so a crash during an
    append is reported rather than written over. *)
val append
  :  keepers_dir:string
  -> keeper_id:string
  -> record
  -> (unit, append_error) result

type read_error =
  | Not_json of string
  | Malformed of Keeper_memory_os_types.wire_error
  | Incomplete_line
      (** The file's last line has no newline: an append that never
          completed. *)

val read_error_to_string : read_error -> string

(** Every line in file order, numbered as in the file, each decoded or
    rejected on its own. Read under the writer's lock, so no append is half
    visible. A missing file is no lines; a file that cannot be read is
    [Error]. *)
val read
  :  keepers_dir:string
  -> keeper_id:string
  -> ((int * (record, read_error) result) list, string) result
