(** Input query helpers for keeper world observation. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

type current_task_observation =
  | No_current_task
  | Current_task of Masc_domain.task
  | Recovered_current_task of
      { task : Masc_domain.task
      ; recovery : Workspace.backlog_recovery
      }
  | Current_task_missing of
      { task_id : Keeper_id.Task_id.t
      ; recovery : Workspace.backlog_recovery option
      }
  | Current_task_unavailable of
      { task_id : Keeper_id.Task_id.t
      ; error : string
      }

val read_backlog_counts
  :  config:Workspace.config
  -> meta:keeper_meta
  -> int * int * int * int option
(** [(unclaimed, claimable, failed, observed_revision)].
    Uses the source-preserving observation contract. [observed_revision] is
    [Some backlog.version] only after a valid primary read and [None] when the
    primary is unreadable, including when a recovery snapshot is available.
    Counts are zero on the latter path, so stale recovery data cannot drive a
    wake or appear claimable. The typed revision absence preserves the degraded
    observation instead of fabricating an empty authoritative backlog. *)

(** [task_is_self_authored_todo ~meta task] is true when an unclaimed [Todo]
    was authored by the keeper's own stable handle ([meta.name]).

    A keeper that treats its own output as work waiting for it closes a
    positive feedback loop: a Keeper whose response to "an unclaimed task
    exists" is to create a routing or report task produces a new unclaimed Todo
    authored by itself, which re-satisfies the trigger on the next observation.
    Self-authored tasks therefore stay in the [unclaimed] count (an honest view
    of the backlog) but are excluded from [claimable] in
    {!read_backlog_counts}. A task with no [created_by] has no known author and
    is never excluded. *)
val task_is_self_authored_todo : meta:keeper_meta -> Masc_domain.task -> bool

val read_current_task
  :  config:Workspace.config
  -> meta:keeper_meta
  -> current_task_observation
(** Resolve [meta.current_task_id] without collapsing absence, recovery, and
    unreadability. A primary task is authoritative; a recovery task is
    explicitly non-authoritative; a missing task id remains visible; and a
    typed read failure is counted and returned as [Current_task_unavailable]
    so an expected observation failure cannot crash the Keeper cycle.
    Cancellation and unexpected exceptions are re-raised. *)

val count_running_keeper_fibers : config:Workspace.config -> int
(** Count live keeper fibers for [config.base_path].

    This intentionally does not read the legacy [.masc/agents/] registry; that
    registry may be empty while keeper fibers are healthy and running. *)
val compute_idle_seconds : meta:keeper_meta -> int
