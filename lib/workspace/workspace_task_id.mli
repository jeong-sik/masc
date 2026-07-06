(** Workspace_task_id — Task ID parsing and archive management.

    Public surface for {!Workspace_task_id.ml}.  Encapsulates the lock-protected
    archive read/merge/write sequence so callers cannot bypass it.
    See issue #10751 for the broader [workspace/] [.mli] coverage push. *)

open Masc_domain

(** Parse a [task-N] identifier into its integer suffix.
    Returns [None] when the string does not match the [task-N] form
    (missing prefix, empty suffix, or non-integer suffix). *)
val task_id_to_int : string -> int option

(** Read every task id stored in [tasks-archive.json] under the
    config's base path.  Returns an empty list when the archive
    file does not exist. *)
val read_archive_task_ids_result :
  Workspace_utils_backend_setup.config -> (int list, string) result

val read_archive_task_ids : Workspace_utils_backend_setup.config -> int list

(** Append [tasks] to [tasks-archive.json], deduplicating by task id.
    The read/merge/write sequence is wrapped in [with_file_lock] so
    concurrent callers cannot lose each other's archive entries.
    No-op when [tasks] is empty. *)
val append_archive_tasks :
  Workspace_utils_backend_setup.config -> task list -> unit

val append_archive_tasks_result :
  Workspace_utils_backend_setup.config -> task list -> (unit, string) result

(** Non-terminal tasks currently sitting in [tasks-archive.json] — obligations a
    buggy GC pass stranded (RFC-0220: an [AwaitingVerification] obligation must
    stay claimable by a verifier).  Read-only; pair with {!drop_archive_tasks}
    after the live backlog has been rewritten so a crash between the two cannot
    lose the task.  The [_result] variant returns [Error] when the archive
    cannot be read or any archive entry cannot be decoded as a task; the legacy
    wrapper logs that error and returns [[]]. *)
val read_orphaned_nonterminal_tasks :
  Workspace_utils_backend_setup.config -> task list

val read_orphaned_nonterminal_tasks_result :
  Workspace_utils_backend_setup.config -> (task list, string) result

(** Remove archive entries whose task id is in [ids], under the archive lock.
    Entries without an [id] field are preserved (an unreadable line is never
    silently dropped).  No-op on []. *)
val drop_archive_tasks :
  Workspace_utils_backend_setup.config -> ids:string list -> unit

val drop_archive_tasks_result :
  Workspace_utils_backend_setup.config -> ids:string list -> (unit, string) result

(** Next task number = [max(existing backlog ids, archive ids) + 1].
    Returns [1] when both backlog and archive are empty. *)
val next_task_number_result :
  Workspace_utils_backend_setup.config -> backlog -> (int, string) result

val next_task_number :
  Workspace_utils_backend_setup.config -> backlog -> int
