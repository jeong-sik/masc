(** How far a keeper's Librarian has read (RFC librarian-lifecycle §4.6).

    One JSON object in [<keepers_dir>/<keeper>.librarian-progress.json], next
    to the keeper's turn-boundary log ({!Keeper_turn_boundaries}). It is a
    value, not a pointer into that log: the trace, how many atoms of its saved
    history have been read, and the digest of the message that opens the last
    of them. The log's file order is not turn order, so a line number could
    not say this.

    {2 What the store promises}

    - No file is [Ok None]: the keeper has not been read yet. That is a fact,
      not a guess, and nothing else reads as it. A file that cannot be read or
      decoded is an [Error]; it is never turned into "not read yet", because
      that would make the whole history look unread.
    - {!write} replaces the file atomically, so a reader sees the old value or
      the new one. A value {!of_json} would refuse is not written.
    - One writer: the keeper's Librarian loop. The store does not serialize
      writers and does not take the turn-boundary log's lock. A purge removes
      both files without that lock, so what keeps a purged position from being
      written back is the order the purge follows, not a lock: it stops the
      keeper's loop and sees it finished before it removes the files (RFC §8
      step 4). *)

type position =
  { trace_id : string
  ; end_atom : int
      (** The atoms [[0, end_atom)] of the trace's saved history have been
          read. At least one: a position exists only once something was
          read, or a line was taken as the baseline. *)
  ; last_atom_digest : string
      (** {!Runtime_model_input_tail_window.atom_opening_digest} of atom
          [end_atom - 1], as the turn-boundary line that was the cut point
          stated it. *)
  }

type t =
  { position : position
  ; boundary_lines_seen : int
      (** How many newline-terminated lines the turn-boundary log held in the
          snapshot the round read {e before} it loaded the checkpoint. A
          restart line beyond this count was appended after the position last
          moved (RFC §4.4 row 3c). Counted once, at the start of the round:
          a count taken when the file is written would step over lines the
          round never looked at. *)
  }

val path_for_keepers_dir : keepers_dir:string -> keeper_id:string -> string

(** {1 Codec} *)

val to_json : t -> Yojson.Safe.t

(** Field-exact. [trace_id] and [last_atom_digest] must be non-blank,
    [end_atom] at least one, [boundary_lines_seen] not negative. Nothing is
    defaulted. *)
val of_json : Yojson.Safe.t -> (t, Keeper_memory_os_types.wire_error) result

(** {1 Store} *)

type read_error =
  | Unreadable of
      { path : string
      ; message : string
      }
  | Not_json of
      { path : string
      ; message : string
      }
  | Malformed of
      { path : string
      ; error : Keeper_memory_os_types.wire_error
      }

val read_error_to_string : read_error -> string

(** [Ok None] when there is no file. *)
val read : keepers_dir:string -> keeper_id:string -> (t option, read_error) result

type write_error =
  | Invalid_progress of Keeper_memory_os_types.wire_error
  | Write_failed of
      { path : string
      ; message : string
      }

val write_error_to_string : write_error -> string

(** Replace the file with [t] ({!Fs_compat.save_file_atomic_strict}: the
    payload and the parent directory are fsynced before success is reported).
    After an [Error] the file holds the old value or the new one; the next
    {!read} says which. *)
val write : keepers_dir:string -> keeper_id:string -> t -> (unit, write_error) result
