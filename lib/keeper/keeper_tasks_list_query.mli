(** Explicit selection before task pagination. All supplied predicates are ANDed.
    Text search is literal, ASCII case-insensitive, over title and description;
    it does not infer relevance or change task state. *)
type t =
  { task_ids : string list option
  ; assignee : string option
  ; goal_id : string option
  ; query : string option
  }

type lifecycle_filter =
  | Active_tasks
  | Active_and_done_tasks
  | All_statuses
  | Exact_status of Masc_domain.Task_status_tag.t
(** Resolved once before matching, paging and revision calculation. Discovery
    defaults to active tasks. Exact IDs with neither lifecycle argument present
    default to all states; explicit status/include_done retain their meaning. *)

val of_args : Yojson.Safe.t -> (t, string) result
val to_yojson : t -> Yojson.Safe.t
val equal : t -> t -> bool
val matches : t -> goal_task_ids:string list option -> Masc_domain.task -> bool
(** [goal_task_ids] comes from the authoritative Goal link registry when a
    Goal is selected. Registry read errors must be returned to the caller. *)

val lifecycle_filter_of_args : selection:t -> Yojson.Safe.t -> (lifecycle_filter, string) result
(** An explicit null status retains the unfiltered active default. A supplied
    include_done must be boolean. Exact status takes precedence over that flag. *)
val lifecycle_filter_to_yojson : lifecycle_filter -> Yojson.Safe.t
val lifecycle_filter_of_yojson : Yojson.Safe.t -> lifecycle_filter option
val lifecycle_filter_equal : lifecycle_filter -> lifecycle_filter -> bool
val matches_lifecycle : lifecycle_filter -> Masc_domain.task -> bool
