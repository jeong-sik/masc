(** Coord_task_id — Task ID parsing and archive management.

    Public surface for {!Coord_task_id.ml}.  Encapsulates the lock-protected
    archive read/merge/write sequence so callers cannot bypass it.
    See issue #10751 for the broader [coord/] [.mli] coverage push. *)

open Masc_domain

(** Parse a [task-N] identifier into its integer suffix.
    Returns [None] when the string does not match the [task-N] form
    (missing prefix, empty suffix, or non-integer suffix). *)
val task_id_to_int : string -> int option

(** Read every task id stored in [tasks-archive.json] under the
    config's base path.  Returns an empty list when the archive
    file does not exist. *)
val read_archive_task_ids : Coord_utils_backend_setup.config -> int list

(** Append [tasks] to [tasks-archive.json], deduplicating by task id.
    The read/merge/write sequence is wrapped in [with_file_lock] so
    concurrent callers cannot lose each other's archive entries.
    No-op when [tasks] is empty. *)
val append_archive_tasks :
  Coord_utils_backend_setup.config -> task list -> unit

(** Next task number = [max(existing backlog ids, archive ids) + 1].
    Returns [1] when both backlog and archive are empty. *)
val next_task_number :
  Coord_utils_backend_setup.config -> backlog -> int
