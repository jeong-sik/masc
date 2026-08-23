(** Workspace backlog persistence — read / write the canonical
    [tasks/backlog.json] document with structural recovery. *)


val backlog_path : Workspace_utils_backend_setup.config -> string
val backlog_lock_path : Workspace_utils_backend_setup.config -> string
val backlog_recovery_path : Workspace_utils_backend_setup.config -> string
val read_backlog_r : Workspace_utils_backend_setup.config ->
           (Masc_domain.backlog, string) result
(** Strict authoritative read for code that may make a durable decision or
    mutation. A recovered [.last-good] snapshot is rejected. *)
type backlog_recovery = {
  primary_error : string;
  recovery_path : string;
}
type backlog_observation = {
  observed_backlog : Masc_domain.backlog;
  recovered_from : backlog_recovery option;
}
val read_backlog_observation_with_source_r :
  Workspace_utils_backend_setup.config -> (backlog_observation, string) result
(** Read-only observation with explicit recovery provenance. Recovered data is
    still available to status surfaces, but callers can mark it degraded. *)
val read_backlog_observation_r : Workspace_utils_backend_setup.config ->
           (Masc_domain.backlog, string) result
(** Read-only observation. A valid [.last-good] snapshot remains visible when
    the primary backlog is unreadable. *)
val read_backlog : Workspace_utils_backend_setup.config -> Masc_domain.backlog
val write_backlog :
  ?after_commit:(unit -> unit) ->
  Workspace_utils_backend_setup.config ->
  Masc_domain.backlog ->
  unit
(** [write_backlog ?after_commit config backlog] commits the primary SSOT,
    stamping [version] to [backlog.version + 1] and [last_updated] to the
    commit time. Callers pass the snapshot they read with only its payload
    mutated; they must not pre-increment either stamp.

    then attempts the recovery copy. Recovery-copy failure is logged and does
    not turn a committed primary mutation into a reported failure.
    Non-transition callers (GC, init, query) omit the callback.
    Raises [Backlog_write_failed] only when the primary SSOT did not commit. *)

exception Backlog_read_failed of string
exception Backlog_write_failed of string

type write_backlog_outcome =
  { committed_revision : int
  ; primary_mirror_error : string option
  ; recovery_error : string option
  ; post_commit_error : string option
  }

val write_backlog_result :
  ?after_commit:(unit -> unit) ->
  Workspace_utils_backend_setup.config ->
  Masc_domain.backlog ->
  (write_backlog_outcome, string) result
(** Result-returning variant of {!write_backlog}. [Error] means the primary
    SSOT did not commit. It applies the same single-commit-point stamping
    contract: [version] becomes the input snapshot's version plus one and
    [last_updated] becomes the commit time. A [max_int] input revision is
    rejected before either primary or recovery is written. Failures after a
    primary commit are returned in the corresponding [Ok] fields and logged
    explicitly. *)
