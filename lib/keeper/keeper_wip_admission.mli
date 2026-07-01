(** Pure WIP admission policy for keeper-owned implementation work. *)

type category =
  | Feature
  | Fix
  | Refactor
  | Docs
  | Chore
  | Ci
  | Test
  | Other of string

val category_to_string : category -> string
val category_of_string : string -> category
val title_category : string -> category

type scope = {
  repo : string option;
  goal_id : string option;
  category : category;
}

val scope_of_task :
  ?task_goal_index:(string, string list) Hashtbl.t -> Masc_domain.task -> scope

type caps = {
  max_global : int option;
  max_per_repo : int option;
  max_per_goal : int option;
  max_per_category : int option;
}

val default_caps : caps

type active_item = {
  id : string;
  scope : scope;
}

val task_is_active_wip : ?stale_threshold_s:float -> Masc_domain.task -> bool
val active_item_of_task :
  ?task_goal_index:(string, string list) Hashtbl.t -> Masc_domain.task -> active_item
val active_items_of_tasks :
  ?task_goal_index:(string, string list) Hashtbl.t -> ?stale_threshold_s:float ->
  Masc_domain.task list -> active_item list

type reject_reason =
  | Global_cap
  | Repo_cap
  | Goal_cap
  | Category_cap

val reject_reason_to_string : reject_reason -> string
val reject_reason_axis : reject_reason -> string

type rejection = {
  reason : reject_reason;
  current : int;
  limit : int;
  scope_key : string;
}

type decision =
  | Admit of { active_count_after_admit : int }
  | Reject of rejection

val active_counts :
  scope:scope -> active_item list -> (string * int) list

val decide :
  ?caps:caps ->
  active_item list ->
  scope:scope ->
  decision

val decision_to_json : decision -> Yojson.Safe.t
