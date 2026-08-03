(** Input query helpers for keeper world observation. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

type backlog_edge_observation =
  | Backlog_read_unavailable of string
  | Recovery_backlog of
      { revision : int
      ; projection_sha256 : string
      ; recovery : Workspace.backlog_recovery
      }
  | Observed_backlog of
      { revision : int
      ; projection_sha256 : string
      ; updated_since_last_scheduled_autonomous : bool
      }
val backlog_edge_observation_to_string : backlog_edge_observation -> string
(** Render model-safe provenance without storage paths or parser error text.
    Detailed failures stay in logs and metrics. *)
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
  -> projection_sha256:string
  -> bool
(** RFC-0357 §3.2 backlog edge:
    the revision advances and the exact non-self-authored task projection
    differs from the paired consumed projection. Wall clocks, task titles,
    and semantic string matching are not inputs. *)

val relevant_backlog_projection_sha256
  :  meta:keeper_meta
  -> Masc_domain.task list
  -> string
(** Stable SHA-256 of typed task JSON after excluding only self-authored Todo
    rows. Input list order does not affect the result. *)

val read_backlog_counts
  :  config:Workspace.config
  -> meta:keeper_meta
  -> int * int * int * backlog_edge_observation
(** [(unclaimed, claimable, failed, backlog_edge)]. Uses the recovery-backed
    observation contract. A successful primary read carries one inseparable
    revision/projection/edge value. A recovery read carries its revision and
    projection as read-only facts but cannot form an authoritative edge;
    [Backlog_read_unavailable] carries the failure rather than fabricating an
    empty backlog. *)

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
