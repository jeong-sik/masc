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

type backlog_observation_source =
  | Primary
  | Recovery of Workspace.backlog_recovery
  | Unavailable of string

val backlog_observation_source_to_string : backlog_observation_source -> string

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
  -> int * int * int * bool * int option * string option * backlog_observation_source
(** [(unclaimed, claimable, failed, backlog_edge, observed_revision,
    observed_projection_sha256, source)]. Counts may come from a recovery
    snapshot for read-only context, but [observed_revision] and
    [observed_projection_sha256] are [None] unless the primary SSOT was read;
    a recovery snapshot can never fire or consume the scheduled edge. An
    unavailable source returns typed [Unavailable] with no fabricated counts
    or revision, while independent observation stimuli continue. *)

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
