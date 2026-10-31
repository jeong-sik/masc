(** Workspace backlog persistence — read / write the canonical
    [tasks/backlog.json] document with structural recovery. *)


val backlog_path : Workspace_utils_backend_setup.config -> string
val backlog_lock_path : Workspace_utils_backend_setup.config -> string
val backlog_recovery_path : Workspace_utils_backend_setup.config -> string

module Task_id_map : Map.S with type key = string

type prepared_backlog =
  { backlog : Masc_domain.backlog
  ; tasks_by_id : Masc_domain.task Task_id_map.t
  ; active_assignees_by_task_id : string Task_id_map.t
  ; priority_ordered_tasks : Masc_domain.task list
  ; claimable_ordered_tasks : Masc_domain.task list
  }
(** Immutable derived index built once per decoded backlog snapshot and cached
    alongside the canonical [backlog] record under the file's [(mtime, size)].
    Eliminates repeated $O(T \log T)$ sorting and $O(T)$ linear scans across
    [keeper_tasks_list], [claim_next_r], and [claim_task_r]. *)

val compare_task_priority_order : Masc_domain.task -> Masc_domain.task -> int
val prepare_backlog : Masc_domain.backlog -> prepared_backlog

val read_prepared_backlog_r :
  Workspace_utils_backend_setup.config -> (prepared_backlog, string) result

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
type prepared_backlog_observation = {
  observed_prepared : prepared_backlog;
  recovered_from : backlog_recovery option;
}
val read_prepared_backlog_observation_with_source_r :
  Workspace_utils_backend_setup.config ->
  (prepared_backlog_observation, string) result
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
    explicitly. The pure JSON projection and encoding use the shared CPU pool
    when available; storage, mutation observers and [after_commit] remain on
    the caller. [last_updated] is stamped inside that job, after any wait for
    a worker. The primary write and the recovery copy write run as the
    protected step of the caller's backlog lease
    ({!Workspace_utils_ops.commit_under_held_lease}): the owner check, lease
    renewal and both writes happen inside the lock key's fence, so no writer
    that takes the lease over can commit between them. When another
    acquisition holds the lease nothing is written and the result is
    [Error]. The primary stays the commit point: a failed recovery write
    after it is reported in [recovery_error], and observers and
    [after_commit] still run. *)

(** Repair primary mirrors and recovery copies with the current primary
    snapshot without incrementing its revision. Caller holds the backlog lock.
    Pure JSON projection and encoding use the shared CPU pool when available;
    storage and mutation observers remain on the caller. The primary and
    recovery writes are protected by the caller's lease exactly as in
    {!write_backlog_result}. *)
val repair_backlog_copies_result :
  Workspace_utils_backend_setup.config -> Masc_domain.backlog -> (unit, string) result

(** Test seam: runs inside the lease's fence between the primary write and
    the recovery copy write of {!write_backlog_result} and
    {!repair_backlog_copies_result}. Production never sets it. *)
val between_backlog_copy_writes_hook : (unit -> unit) Atomic.t

type copy_consistency = Copies_consistent | Copies_unavailable of string list
(** Compare recovery and configured local mirrors once against a primary snapshot.
    Caller holds the backlog lock so the observation cannot mix commit revisions. *)
val observe_copy_consistency :
  Workspace_utils_backend_setup.config -> Masc_domain.backlog -> copy_consistency
