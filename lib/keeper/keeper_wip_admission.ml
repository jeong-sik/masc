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

let normalize value =
  value |> String.trim |> String.lowercase_ascii

let category_to_string = function
  | Feature -> "feature"
  | Fix -> "fix"
  | Refactor -> "refactor"
  | Docs -> "docs"
  | Chore -> "chore"
  | Ci -> "ci"
  | Test -> "test"
  | Other value -> normalize value

let category_of_string value =
  match normalize value with
  | "feature" | "feat" -> Feature
  | "fix" -> Fix
  | "refactor" -> Refactor
  | "docs" | "doc" -> Docs
  | "chore" -> Chore
  | "ci" -> Ci
  | "test" | "tests" -> Test
  | "" -> Other "other"
  | value -> Other value

let title_category title =
  let normalized = normalize title in
  let stop =
    [ String.index_opt normalized ':'
    ; String.index_opt normalized '('
    ; String.index_opt normalized ' '
    ]
    |> List.filter_map Fun.id
    |> function
    | [] -> String.length normalized
    | positions -> List.fold_left min max_int positions
  in
  if stop <= 0 then Other "other" else String.sub normalized 0 stop |> category_of_string

type scope = {
  repo : string option;
  goal_id : string option;
  category : category;
}

(* The task model carries no repo attribution (see [Masc_domain.task]); its only
   repo-ish field is [files], a heuristic path list we deliberately do not parse.
   A repoless task resolves to [None] and — exactly like a goalless task under the
   per-goal cap (RFC-0245, see [decide]) — is exempt from the per-repo cap,
   bounded only by the global/category caps. The per-repo cap stays live for any
   task that DOES resolve to a repo ([Some]), so the mechanism is preserved for
   when the task model carries one. Returning a single fallback repo here instead
   collapsed every fleet task into one [repo:<basename>] bucket, turning
   [max_per_repo] into a fleet-wide cap tighter than [max_global] — every keeper
   blocked once 6 tasks were active anywhere in the fleet. *)
let task_repo (_task : Masc_domain.task) : string option = None

let scope_of_task ?(task_goal_index = Hashtbl.create 0) (task : Masc_domain.task) =
  let goal_id =
    try Some (List.hd (Hashtbl.find task_goal_index task.id)) with Not_found -> None
  in
  { repo = task_repo task
  ; goal_id
  ; category = title_category task.title
  }

type caps = {
  max_global : int option;
  max_per_repo : int option;
  max_per_goal : int option;
  max_per_category : int option;
}

(* Historical hardcoded WIP admission caps. Kept as the env fallback so an
   unset environment reproduces the exact prior behaviour. *)
let default_max_global = 16
let default_max_per_repo = 12
let default_max_per_goal = 3
let default_max_per_category = 4

(* Startup env override for one WIP cap. Unset keeps the historical default; a
   positive integer sets the cap; "none"/"off"/a non-positive integer disables
   it ([None] = unbounded on that axis, so the remaining caps still apply); an
   unparseable value keeps the default. Read lazily per [decide] call (via
   [default_caps ()]) so a runtime.toml boot override resolves after boot, matching
   the other MASC_KEEPER_* knobs (e.g. [Keeper_turn_liveness]). These caps never
   reject a task that resolves to [repo = None] (see [task_repo]); the knobs exist
   for operators to tune fleet concurrency without a rebuild, not to gate repo
   access. *)
let wip_cap_from_env ~(env : string) ~(default : int) : int option =
  match Env_config_core.raw_value_opt env with
  | None -> Some default
  | Some raw ->
    let raw = String.lowercase_ascii (String.trim raw) in
    if String.equal raw "none" || String.equal raw "off"
    then None
    else (
      match int_of_string_opt raw with
      | Some n when n > 0 -> Some n
      | Some _ -> None
      | None -> Some default)

let default_caps () =
  { max_global =
      wip_cap_from_env ~env:"MASC_KEEPER_WIP_MAX_GLOBAL" ~default:default_max_global
  ; max_per_repo =
      wip_cap_from_env ~env:"MASC_KEEPER_WIP_MAX_PER_REPO" ~default:default_max_per_repo
  ; max_per_goal =
      wip_cap_from_env ~env:"MASC_KEEPER_WIP_MAX_PER_GOAL" ~default:default_max_per_goal
  ; max_per_category =
      wip_cap_from_env
        ~env:"MASC_KEEPER_WIP_MAX_PER_CATEGORY"
        ~default:default_max_per_category
  }

type active_item = {
  id : string;
  scope : scope;
}

let task_is_active_wip (task : Masc_domain.task) =
  match task.task_status with
  | Masc_domain.Claimed _ | Masc_domain.InProgress _ -> true
  | Masc_domain.Todo
  | Masc_domain.AwaitingVerification _
  | Masc_domain.Done _
  | Masc_domain.Cancelled _ -> false

let active_item_of_task ?task_goal_index (task : Masc_domain.task) =
  { id = task.id; scope = scope_of_task ?task_goal_index task }

let active_items_of_tasks ?task_goal_index tasks =
  tasks
  |> List.filter task_is_active_wip
  |> List.map (active_item_of_task ?task_goal_index)

type reject_reason =
  | Global_cap
  | Repo_cap
  | Goal_cap
  | Category_cap

let reject_reason_to_string = function
  | Global_cap -> "global_cap"
  | Repo_cap -> "repo_cap"
  | Goal_cap -> "goal_cap"
  | Category_cap -> "category_cap"

let reject_reason_axis = function
  | Global_cap -> "global"
  | Repo_cap -> "repo"
  | Goal_cap -> "goal"
  | Category_cap -> "category"

type rejection = {
  reason : reject_reason;
  current : int;
  limit : int;
  scope_key : string;
}

type decision =
  | Admit of { active_count_after_admit : int }
  | Reject of rejection

let same_string a b =
  String.equal (normalize a) (normalize b)

let same_goal a b =
  match a, b with
  | Some a, Some b -> same_string a b
  | None, None -> true
  | _ -> false

let same_repo a b =
  match a, b with
  | Some a, Some b -> same_string a b
  | None, None -> true
  | _ -> false

let same_category a b =
  String.equal (category_to_string a) (category_to_string b)

let count_matching predicate active =
  active |> List.filter predicate |> List.length

let global_key = "global"

let repo_key = function
  | Some repo -> Printf.sprintf "repo:%s" (normalize repo)
  | None -> "repo:<none>"

let goal_key = function
  | Some goal_id -> Printf.sprintf "goal:%s" (normalize goal_id)
  | None -> "goal:<none>"

let category_key category =
  Printf.sprintf "category:%s" (category_to_string category)

let active_counts ~scope active =
  [ global_key, List.length active
  ; ( repo_key scope.repo,
      count_matching (fun item -> same_repo item.scope.repo scope.repo) active )
  ; ( goal_key scope.goal_id,
      count_matching
        (fun item -> same_goal item.scope.goal_id scope.goal_id)
        active )
  ; ( category_key scope.category,
      count_matching
        (fun item -> same_category item.scope.category scope.category)
        active )
  ]

let reject_if_at_cap reason scope_key current = function
  | Some limit when limit >= 0 && current >= limit ->
    Some (Reject { reason; current; limit; scope_key })
  | _ -> None

let first_rejection checks =
  List.find_map Fun.id checks

let decide ?(caps = default_caps ()) active ~scope =
  let global_count = List.length active in
  let repo_count =
    count_matching (fun item -> same_repo item.scope.repo scope.repo) active
  in
  let goal_count =
    count_matching
      (fun item -> same_goal item.scope.goal_id scope.goal_id)
      active
  in
  let category_count =
    count_matching
      (fun item -> same_category item.scope.category scope.category)
      active
  in
  (* The per-goal cap exists to prevent *scope collisions* — multiple keepers
     working the same goal at once (merge conflicts, duplicated work). A task
     with no goal_id ([goal:<none>]) shares no goal scope with any other, so
     there is nothing to collide on. Applying [max_per_goal] to the [None]
     bucket instead lumps every unrelated goalless task into one fleet-wide
     cap, which starves claims once that bucket fills. Exempt [None] from the
     goal cap; the global/repo/category caps still bound goalless WIP. (RFC-0245) *)
  let goal_cap_check =
    match scope.goal_id with
    | Some _ ->
      reject_if_at_cap Goal_cap (goal_key scope.goal_id) goal_count
        caps.max_per_goal
    | None -> None
  in
  (* Mirror the per-goal exemption above: a task with no resolved repo
     ([repo:<none>]) shares no repo scope with any other, so it cannot collide.
     Applying [max_per_repo] to the [None] bucket lumps every repoless task into
     one fleet-wide cap — the collapse this module previously suffered. Exempt
     [None]; the global/category caps still bound repoless WIP. *)
  let repo_cap_check =
    match scope.repo with
    | Some _ ->
      reject_if_at_cap Repo_cap (repo_key scope.repo) repo_count caps.max_per_repo
    | None -> None
  in
  match
    first_rejection
      [ reject_if_at_cap Global_cap global_key global_count caps.max_global
      ; repo_cap_check
      ; goal_cap_check
      ; reject_if_at_cap Category_cap
          (category_key scope.category)
          category_count
          caps.max_per_category
      ]
  with
  | Some rejection -> rejection
  | None -> Admit { active_count_after_admit = global_count + 1 }

let decision_to_json = function
  | Admit { active_count_after_admit } ->
    `Assoc
      [ ("admitted", `Bool true)
      ; ("active_count_after_admit", `Int active_count_after_admit)
      ]
  | Reject { reason; current; limit; scope_key } ->
    `Assoc
      [ ("admitted", `Bool false)
      ; ("reason", `String (reject_reason_to_string reason))
      ; ("axis", `String (reject_reason_axis reason))
      ; ("current", `Int current)
      ; ("limit", `Int limit)
      ; ("scope_key", `String scope_key)
      ]
