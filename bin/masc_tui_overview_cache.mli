(** The Overview's last input snapshots and their derived projections.
    Inputs are immutable lists replaced by the loader. A cache retains only
    the latest snapshot of each projection; it never caches a clock-derived
    age or a rendered line. Keep one instance for the renderer's lifetime. *)
type t

val create : unit -> t

val team :
  t ->
  keepers:Masc_tui_types.overview_keeper list ->
  tasks:Masc.Tui_decode.task list ->
  attention:Masc_tui_types.attention_item list ->
  Masc_tui_overview_team.t

val goal_status_of_id :
  t -> Masc_domain.task list -> string -> Masc_domain.task_status option
(** Resolve against the full backlog, including completed tasks. When an id
    occurs twice, the first occurrence wins, as in the original linear read. *)

val backlog : t -> Masc_domain.task list -> Masc_tui_overview_tasks.backlog
