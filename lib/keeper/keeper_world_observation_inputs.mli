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

val backlog_updated_since_last_scheduled_autonomous
  :  meta:keeper_meta
  -> backlog:Masc_domain.backlog
  -> bool
(** RFC-0357 §3.2 backlog edge:
    [backlog.version > meta.runtime.proactive_rt.last_consumed_backlog_revision].
    A monotonic revision compare — wall clocks, ISO8601 parsing, and the
    zero-point special case of the previous implementation are gone by
    construction. *)

val read_backlog_counts
  :  config:Workspace.config
  -> meta:keeper_meta
  -> int * int * int * bool * int option
(** [(unclaimed, claimable, failed, backlog_edge, observed_revision)].
    [observed_revision] is [Some backlog.version] on a successful read and
    [None] when the read failed — admission records only actually observed
    revisions, so a failed read can neither fire the edge nor move the
    consumption clock. *)

(** [task_is_self_authored_todo ~meta task] is true when an unclaimed [Todo]
    was authored by the keeper's own stable handle ([meta.name]).

    A keeper that treats its own output as work waiting for it closes a
    positive feedback loop: a persona whose response to "an unclaimed task
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
