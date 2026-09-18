(** Where each finished keeper turn left the durable history (RFC
    librarian-is-the-brain §4.3).

    A finished turn appends one line to a per-keeper append-only
    [<keeper>.turn-boundaries.jsonl], after its checkpoint is saved. The line
    names the turn and the end of the saved history in the atom vocabulary of
    {!Runtime_model_input_tail_window}: how many atoms the checkpoint holds and
    the digest of the message that opens the last one. A turn's start is not
    written; the end the previous line states is that start.

    A line that cannot be built or written does not fail the turn: the
    checkpoint is already durable, and the next line then closes a span of two
    turns. An agent-core turn whose checkpoint save was a stale no-op writes no
    line, because the checkpoint on disk is a newer writer's. The file is never
    rewritten or trimmed. *)

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

type record =
  { recorded_at : float (** Unix seconds, when the finished turn built its line. *)
  ; session_id : string
        (** The keeper trace id, which is the session id of its checkpoint. *)
  ; turn_ref : Ids.Turn_ref.t (** The finished turn. *)
  ; position : position
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

(** Field-exact, and [position] is field-exact for its [kind]: an unknown
    [kind] or a field its kind does not carry is rejected, never defaulted.
    [recorded_at] must be finite, [session_id] and [last_atom_digest]
    non-blank, [end_atom] at least one, and [turn_ref] a reference
    {!Ids.Turn_ref.of_string} reads back. *)
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
