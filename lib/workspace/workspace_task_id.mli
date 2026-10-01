(** Workspace_task_id — Task ID parsing and archive management.

    Public surface for [workspace_task_id.ml].  Encapsulates the lock-protected
    archive read/merge/write sequence so callers cannot bypass it.
    See issue #10751 for the broader [workspace/] [.mli] coverage push. *)

open Masc_domain

(** Parse a [task-N] identifier into its integer suffix.
    Returns [None] when the string does not match the [task-N] form
    (missing prefix, empty suffix, or non-integer suffix). *)
val task_id_to_int : string -> int option

(** The task rows of a parsed [tasks-archive.json]: the [{"tasks": [...]}]
    envelope's list, or [[]] for any other shape. The one place that knows
    the envelope, for the writers here and for readers outside. *)
val archive_entries_of_json : Yojson.Safe.t -> Yojson.Safe.t list

(** Read every task id stored in [tasks-archive.json] under the
    config's base path.  Returns an empty list when the archive
    file does not exist. *)
val read_archive_task_ids : Workspace_utils_backend_setup.config -> int list

(** Append [tasks] to [tasks-archive.json]. The tasks given are the current
    copies: each replaces the archive row with the same id, whatever that row
    holds (an older copy, or a row that does not decode as a task). Every other
    row stays as it is, rows with no id and repeated ids included.
    The read/merge/write sequence is wrapped in [with_file_lock] so
    concurrent callers cannot lose each other's archive entries.

    [Ok ()] means the archive now holds [tasks]. [Error] means the caller must
    not treat them as archived: the existing file could not be read, or the
    write failed. A missing file is an empty archive; a file that is blank,
    does not parse, or has no [tasks] list is an [Error] and is left as it was,
    never replaced by a new archive holding only [tasks].
    [Ok ()] without touching the file when [tasks] is empty. *)
val append_archive_tasks :
  Workspace_utils_backend_setup.config -> task list -> (unit, string) result

(** Non-terminal tasks currently sitting in [tasks-archive.json] — obligations a
    buggy GC pass stranded. An [AwaitingVerification] obligation must remain in
    the live backlog for an authority verdict. Read-only; pair with {!drop_archive_tasks}
    after the live backlog has been rewritten so a crash between the two cannot
    lose the task.  Unparseable entries are skipped. *)
val read_orphaned_nonterminal_tasks :
  Workspace_utils_backend_setup.config -> task list

(** Remove archive entries whose task id is in [ids], under the archive lock.
    Entries without an [id] field are preserved (an unreadable line is never
    silently dropped).  No-op on []. *)
val drop_archive_tasks :
  Workspace_utils_backend_setup.config -> ids:string list -> unit

(** Next task number =
    [max(existing backlog ids, deletion receipt ids, archive ids,
    durable event task ids) + 1].
    Event history remains authoritative after a workspace state restore, so
    omitting it can alias a new task onto an older lifecycle. Returns [1] when
    all four sources are empty. *)
val next_task_number :
  Workspace_utils_backend_setup.config -> backlog -> int
