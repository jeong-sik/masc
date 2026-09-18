(** Where each finished keeper turn left the durable history (RFC
    librarian-lifecycle §4.6).

    A finished turn appends one line to a per-keeper append-only
    [<keeper>.turn-boundaries.jsonl], after its checkpoint is saved. The line
    names the turn and the end of the saved history in the atom vocabulary of
    {!Runtime_model_input_tail_window}: how many atoms the checkpoint holds and
    the digest of the message that opens the last one. A turn's start is not
    written; the end an earlier line states is that start.

    [masc_keeper_clear] is the other writer. It empties a history outside any
    turn, and appends a [History_cleared] line once the emptied checkpoint is
    saved.

    {2 What a reader may rely on}

    - A line that cannot be built or written does not fail the turn: the
      checkpoint is already durable. After a transient append failure the next
      line's span covers both turns, so nothing is lost.
    - A crash in the middle of an append can leave the file ending mid-line.
      Every later append is then refused until process-start recovery
      ([Fs_compat.recover_private_jsonl_durable_locked_result]) truncates the
      torn tail. That call belongs to the reader's boot path (RFC §8 step 4),
      not to this module; until it runs, turns of that keeper go unrecorded.
    - File order is not turn order. The checkpoint save is serialized by the
      session lock; this append happens after that lock is released. A reader
      orders the [Atom_history] lines of one trace by [end_atom], not by their
      position in the file, and must not assume [turn_ref] is unique: two turns
      of one keeper that finish together both take the next turn number.
    - A history starts over in two ways, and each leaves a line that is written
      after the fact: a [Turn_ended] line with [Fresh_history], or a
      [History_cleared] line. Neither moves a reader's position by itself. A
      reader whose position no longer matches the checkpoint (the digest of
      atom [end_atom - 1] differs, or that atom is gone) looks for such a line
      of the same trace that was appended after it last confirmed its
      position. With one, it starts again from atom zero; without one, the
      mismatch has no explanation and the reader stops. A position that still
      matches is kept whatever lines there are: the clear was undone by a turn
      that saved over it.
    - [last_atom_digest] is computed from the checkpoint the save returned. On
      the store's payload-encode recovery path the bytes on disk are a recovery
      copy with the unencodable json dropped, while the save still returns the
      original (masc #37018). If the message that opens the last atom carried
      that json, the digest describes bytes that were not stored. Rare.

    The file is never rewritten or trimmed by this module. *)

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

(** What a line states. The wire form carries a [kind] tag from the first line
    ever written, so a kind of line is a constructor rather than a field on a
    strictly decoded line. *)
type event =
  | Turn_ended of
      { turn_ref : Ids.Turn_ref.t
            (** The finished turn. Its trace id is the keeper trace id, which
                is also the session id of the checkpoint. *)
      ; history_at_start : history_at_start
      ; position : position
      }
  | History_cleared of { trace_id : string }
      (** [masc_keeper_clear] saved the checkpoint of this trace with no atom
          in it ({!Keeper_history_clear}). The turn after a clear loads that
          checkpoint, so its line says [Continued_history] while its
          [end_atom] starts over near zero; only the clear knows why, and this
          line is where it says so.

          The line is appended after the emptied checkpoint is saved, never
          before. It does not say the history is still empty: a turn that was
          running during the clear saves its own, full history over the
          emptied one. *)

type record =
  { recorded_at : float (** Unix seconds, when the writer built the line. *)
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
    must be finite, [last_atom_digest] and [trace_id] non-blank, [end_atom] at
    least one, and [turn_ref] a reference {!Ids.Turn_ref.of_string} reads
    back. *)
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
