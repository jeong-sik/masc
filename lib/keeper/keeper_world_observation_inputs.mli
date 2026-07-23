(** Input query helpers for keeper world observation. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

val backlog_updated_since_last_scheduled_autonomous
  :  meta:keeper_meta
  -> backlog:Masc_domain.backlog
  -> bool

val read_backlog_counts
  :  config:Workspace.config
  -> meta:keeper_meta
  -> int * int * int * int * bool

(** [task_is_self_authored ~meta task] is true when [task.created_by] is the
    keeper's own handle ([meta.name]).

    A keeper that treats its own output as work waiting for it closes a
    positive feedback loop: a persona whose response to "an unclaimed task
    exists" is to create a routing or report task produces a new unclaimed Todo
    authored by itself, which re-satisfies the trigger on the next observation.
    Self-authored tasks therefore stay in the [unclaimed] count (an honest view
    of the backlog) but are excluded from [claimable] in
    {!read_backlog_counts}. A task with no [created_by] has no known author and
    is never excluded. *)
val task_is_self_authored : meta:keeper_meta -> Masc_domain.task -> bool

val audit_tasks_without_actionable_verification_ids
  :  string list
  -> Masc_domain.task list
  -> (string * string) list
(** RFC-0323 G-5 readiness gate 3 (pure core): list AwaitingVerification tasks
    whose [verification_id] is absent from the given actionable request-id list.
    Each entry is (task_id, verification_id). An orphan never wakes — the wake
    join requires the record — so it is a silent starvation source under the
    default-on flip. Pure so tests can drive it without a verification store. *)

val audit_tasks_without_actionable_verification
  :  config:Workspace.config
  -> Masc_domain.task list
  -> (string * string) list
(** [audit_tasks_without_actionable_verification_ids] backed by the live
    verification store ([actionable_verification_request_ids]). For runtime
    diagnostics. *)

val read_current_task
  :  config:Workspace.config
  -> meta:keeper_meta
  -> Masc_domain.task option
(** Resolve [meta.current_task_id] to its backlog record (RFC-0315). [None]
    when the keeper holds no task, the id is absent from the backlog, or the
    backlog read fails (failure is logged and counted, never raised). *)

val count_running_keeper_fibers : config:Workspace.config -> int
(** Count live keeper fibers for [config.base_path].

    This intentionally does not read the legacy [.masc/agents/] registry; that
    registry may be empty while keeper fibers are healthy and running. *)
val compute_idle_seconds : meta:keeper_meta -> int
