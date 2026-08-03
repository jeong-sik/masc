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
  -> int * int * int * bool * int option
(** [(unclaimed, claimable, failed, backlog_changed, observed_revision)].
    Uses the recovery-backed observation contract. [observed_revision] is
    [Some backlog.version] after a valid primary or recovery read and [None]
    when neither source is a valid current backlog. Counts are zero on the
    latter path but cannot be mistaken for an observed empty backlog because
    the typed revision is absent. *)

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
  -> Masc_domain.task option
(** Resolve [meta.current_task_id] to its backlog record (RFC-0315). [None]
    only when the keeper holds no task or the id is absent from the observed
    backlog. A failed primary and recovery read is logged, counted, and raised
    as {!Workspace.Backlog_read_failed}. *)

val count_running_keeper_fibers : config:Workspace.config -> int
(** Count live keeper fibers for [config.base_path].

    This intentionally does not read the legacy [.masc/agents/] registry; that
    registry may be empty while keeper fibers are healthy and running. *)
val compute_idle_seconds : meta:keeper_meta -> int
