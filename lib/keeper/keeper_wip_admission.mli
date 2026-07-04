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
  goal_id : string option;
  category : category;
}

val scope_of_task :
  ?task_goal_index:(string, string list) Hashtbl.t -> Masc_domain.task -> scope

type caps = {
  max_global : int option;
  max_per_goal : int option;
  max_per_category : int option;
}

val default_caps : unit -> caps
(** WIP admission caps, resolved at call time from the [keeper.wip.*] runtime
    params (registered via {!Keeper_config_rp_helpers._rp_int}, so they surface in
    runtime.toml and the dashboard knob table rather than being env-only). Each
    knob's default reads [MASC_KEEPER_WIP_MAX_GLOBAL] / [_MAX_PER_GOAL] /
    [_MAX_PER_CATEGORY]: an unset knob keeps the historical
    default (16 / 3 / 4), a positive value overrides, and 0 (or a negative
    value, clamped to 0) disables that axis ([None] = unbounded, deferring to the
    remaining caps). A runtime.toml / dashboard override takes precedence over the
    env default. Read lazily per call. *)

type active_item = {
  id : string;
  scope : scope;
}

val task_is_active_wip :
  Masc_domain.task -> bool
val active_item_of_task :
  ?task_goal_index:(string, string list) Hashtbl.t -> Masc_domain.task -> active_item
val active_items_of_tasks :
  ?task_goal_index:(string, string list) Hashtbl.t ->
  Masc_domain.task list -> active_item list

type reject_reason =
  | Global_cap
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
