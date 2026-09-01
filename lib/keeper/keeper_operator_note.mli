(** One sentence an operator puts into a keeper's next turn (RFC-0366).

    An instruction that is true for one turn — "the openssl decision landed,
    task-195 can resume" — had no path that matched its lifetime. Board posts
    need a tool call to be read. Chat operations accumulate in the conversation.
    [Explicit_write] memory reaches the recall block and stays there until the
    librarian replaces it or an exact [Explicit_retract] commit removes it;
    using durable memory for a one-turn instruction is therefore the wrong
    lifetime. #26729 is that shape.

    {1 One turn, and the record stays}

    A note is rendered by the next turn that assembles, then stamped consumed.
    The file is not deleted: deleting it would make "delivered" and "never
    existed" the same observation, and the first question an operator asks is
    whether it went in. [consumed_turn] answers that.

    Writing a note replaces the previous one. This is not a queue — a queue
    accumulates, which is what the chat path already does and what one-turn
    lifetime exists to avoid. *)

type note =
  { text : string
  ; created_at : float
  ; created_by : string
  ; consumed_at : float option
  ; consumed_turn : int option
  }

val path_for : Workspace.config -> string -> string

type write_error =
  | Unknown_keeper of string
  | Empty_text
  | Too_large of
      { bytes : int
      ; max_bytes : int
      }
  | Write_failed of string

val write_error_to_string : write_error -> string

(** Replace this keeper's pending note. Text above the byte cap is rejected
    rather than truncated: a truncated instruction is a different instruction,
    and the operator who wrote it would not know which one arrived. *)
val write :
  config:Workspace.config
  -> keeper:string
  -> text:string
  -> created_by:string
  -> (note, write_error) result

type read_error =
  | Read_unknown_keeper of string
  | No_note
  | Malformed of string

val read_error_to_string : read_error -> string

val read : config:Workspace.config -> keeper:string -> (note, read_error) result

(** The note this turn should render, if any. [None] when there is no note or
    the stored one was already consumed — a consumed note stays on disk as a
    delivery record and must not render again. *)
val pending : config:Workspace.config -> keeper:string -> note option

(** Stamp the stored note as consumed by [absolute_turn]. Called after the block
    is assembled, so a turn that failed to assemble does not burn the note.
    Failure degrades to a warning: the note already reached the prompt, and
    losing the stamp costs the delivery record, not the delivery. *)
val mark_consumed : config:Workspace.config -> keeper:string -> absolute_turn:int -> unit

(** The rendered block text, or [None] for an empty note. *)
val render : note -> string option

val to_json : note -> Yojson.Safe.t
