(** Where a keeper's next request starts, and what it was in the middle of
    (RFC keeper-context-window-in-tokens §7 (라)).

    A request carries the atoms from this position to the end of the saved
    history. The position is the Librarian's: the atoms before it are in the
    keeper's memory, so the request does not carry them again. It is written
    by the Librarian round that absorbed them, once its Memory commit landed,
    and read once per turn while the request is composed.

    This is not {!Keeper_librarian_progress}. That file is the Librarian's
    own reading position and a round may move it without a Memory commit (a
    baseline, a recovered receipt). This one says what a request may leave
    out, so it moves only behind an absorbed range, and it carries what the
    Librarian said it was in the middle of. The two files are separate
    because a reader of one must not be able to mistake the other's meaning.

    Path: [<keepers_dir>/<keeper>/window-position.json], beside the Librarian
    files. [keepers_dir] is {!Workspace.keepers_runtime_dir}. Reading creates
    no directory.

    [read] returning [Ok None] means the Librarian has not absorbed anything
    yet. A file that exists and cannot be read or decoded is an [Error]; it
    is never taken as "nothing absorbed", because that would silently send
    the whole history. Single writer: the keeper's Librarian round. *)

(** What the Librarian said the keeper was in the middle of when it absorbed
    up to {!t.position}. The keeper reads this in its next request, so a
    range that ends mid-task does not look finished. *)
type in_progress =
  | Absent_at_baseline
      (** The position was set as a baseline, without a model call: nothing
          was absorbed, so nothing is claimed about what is in progress. *)
  | Nothing_in_progress  (** The Librarian read the range and found nothing open. *)
  | Stated of string  (** Non-blank. *)

type t =
  { position : Keeper_librarian_progress.position
      (** The first atom a request carries is [position.end_atom]. The digest
          is the one the Librarian position holds: the opening of atom
          [end_atom - 1], which is the last atom absorbed. Atom [end_atom]
          does not exist yet when this is written. *)
  ; in_progress : in_progress
  ; recorded_at : float
  }

val path_for_keepers_dir : keepers_dir:string -> keeper_id:string -> string

(** {1 Codec} *)

val to_json : t -> Yojson.Safe.t

(** Field-exact, nothing defaulted. [Stated] rejects a blank text, and the
    position is validated as {!Keeper_librarian_progress} validates its own. *)
val of_json : Yojson.Safe.t -> (t, Keeper_memory_os_types.wire_error) result

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
val read : keepers_dir:string -> keeper_id:string -> (t option, read_error) result

type write_error =
  | Invalid_position of Keeper_memory_os_types.wire_error
  | Write_failed of
      { path : string
      ; message : string
      }

val write_error_to_string : write_error -> string

(** Atomic replace; the parent directory is created. *)
val write : keepers_dir:string -> keeper_id:string -> t -> (unit, write_error) result

(** What the stored position says about the history a turn is about to send.
    Pure: [digest_at] is
    {!Runtime_model_input_tail_window.atom_opening_digest} of that history and
    [atom_count] its atom count. *)
type view =
  | Absorbed of t
      (** The position names an atom of this history and the message that
          opens the atom before it is the one the Librarian read. *)
  | Empty_history  (** The history has no atom, so there is nothing to leave out. *)
  | Absent  (** No file: the Librarian has absorbed nothing yet. *)
  | Outlived of
      { recorded : t
      ; reason : outlived
      }
      (** The file is readable and does not describe this history. *)

and outlived =
  | Other_trace of string  (** The stored trace, which is not the turn's. *)
  | Atom_missing of
      { end_atom : int
      ; atom_count : int
      }  (** The position is past the end of this history. *)
  | Message_differs of
      { end_atom : int
      ; stored_digest : string
      ; history_digest : string option
      }
      (** The atom is there and the message that opens the one before it is
          not the message the Librarian read. The history was rewritten. *)

val view_of_history
  :  t option
  -> trace_id:string
  -> digest_at:(int -> string option)
  -> atom_count:int
  -> view
