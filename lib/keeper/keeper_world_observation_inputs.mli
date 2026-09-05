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

type claimable_task_identity =
  { task_id : Keeper_id.Task_id.t }

(** One task this keeper holds that declares exact Skill references.
    [held_task_id] is the task id; [held_skills] preserves source, package,
    name, and content revision in declaration order. The current task is never
    listed here: its own block carries its references. *)
type held_task_skills =
  { held_task_id : string
  ; held_skills : Skill_reference.t list
  }

type backlog_snapshot =
  { unclaimed_count : int
  ; claimable_tasks : claimable_task_identity list
  ; failed_count : int
  ; revision : int option
  ; held_task_skills : held_task_skills list
        (** Skills named by the other tasks this keeper holds (Claimed or
            InProgress), read off the same backlog as the counts. *)
  }

val held_task_skills_of_tasks
  :  config:Workspace.config
  -> meta:keeper_meta
  -> Masc_domain.task list
  -> held_task_skills list
(** Pure projection over an already-read task list: the tasks held by
    [meta] (same actor identity a transition uses) that name a skill, minus
    [meta.current_task_id]. The tool surface uses it on the tasks it already
    reads; the observation uses it on the backlog it already reads. *)

val read_held_task_skills : config:Workspace.config -> meta:keeper_meta -> held_task_skills list
(** {!held_task_skills_of_tasks} over one primary backlog read, for the lane
    that builds its prompt without a world observation. A failed or recovered
    read yields [] and counts an observation failure. *)

val read_backlog_snapshot : config:Workspace.config -> meta:keeper_meta -> backlog_snapshot
(** One source-preserving primary backlog read. [claimable_tasks] and its count,
    [unclaimed_count], [failed_count], and [revision] therefore cannot describe
    different backlog revisions. Only typed task identities cross into prompt
    observation; task titles remain behind the task-tool boundary. *)

val tasks_with_identities_memoized
  :  Masc_domain.task list
  -> ((Masc_domain.task * Keeper_id.Task_id.t) list, string) result
(** Typed identities for [tasks], answered from a one-entry memo when [tasks]
    is physically the list last seen. The backlog store returns the same
    decoded record while the file is unchanged, so repeated observations of an
    unchanged backlog do not validate every task id again. *)

(** [task_is_self_authored_todo ~meta task] is true when an unclaimed [Todo]
    was authored by the keeper's own stable handle ([meta.name]).

    A keeper that treats its own output as work waiting for it closes a
    positive feedback loop: a Keeper whose response to "an unclaimed task
    exists" is to create a routing or report task produces a new unclaimed Todo
    authored by itself, which re-satisfies the trigger on the next observation.
    Self-authored tasks therefore stay in the [unclaimed] count (an honest view
    of the backlog) but are excluded from [claimable_tasks] in
    {!read_backlog_snapshot}. A task with no [created_by] has no known author and
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
