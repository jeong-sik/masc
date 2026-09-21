(** How far the Librarian has read the official-client turns of a keeper (RFC
    librarian-lifecycle §10-3).

    An official-client turn leaves no atoms: its end line says
    [No_atom_history], and what it said lives in the history files of its
    trace, keyed by [turn_ref]. So the position for these turns is not an atom
    but a line of the turn-boundary log: the last [No_atom_history] end line
    whose fragments a round read and committed. Lines are appended under a
    lock and never rewritten, so the number only grows.

    This is not {!Keeper_librarian_progress.t.boundary_lines_seen}. That count
    is what a round had seen before it loaded the checkpoint (RFC §4.4 row
    3c); it moves on a baseline and on a narrowed round, neither of which read
    an official line, and the offline purge must leave it alone (§10-2).

    Path: [<keepers_dir>/<keeper>/librarian-official-progress.json], beside
    the atom position. [keepers_dir] is {!Workspace.keepers_runtime_dir}.
    Reading and path computation create no directory.

    [read] returning [Ok None] means "never read": the file is absent. A file
    that exists but cannot be read or decoded is an [Error]; it is never taken
    as "never read", because that would present every official turn as
    unread. Single writer: the keeper's Librarian round. *)

type t = { boundary_line : int  (** 1-based line of the turn-boundary log. *) }

val path_for_keepers_dir : keepers_dir:string -> keeper_id:string -> string

val to_json : t -> Yojson.Safe.t
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
  | Invalid_progress of Keeper_memory_os_types.wire_error
  | Write_failed of
      { path : string
      ; message : string
      }

val write_error_to_string : write_error -> string

(** Atomic replace; the parent directory is created. *)
val write : keepers_dir:string -> keeper_id:string -> t -> (unit, write_error) result
