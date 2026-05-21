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

type scope = {
  repo : string;
  goal_id : string option;
  category : category;
}

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

type reject_reason =
  | Global_cap
  | Repo_cap
  | Goal_cap
  | Category_cap

val reject_reason_to_string : reject_reason -> string

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
