open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

let current_task_id_opt (meta : keeper_meta) =
  Option.map Keeper_id.Task_id.to_string meta.current_task_id

let primary_goal_id_opt (meta : keeper_meta) =
  match meta.active_goal_ids with
  | goal_id :: _ -> Some goal_id
  | [] -> None

(** Cross-check [meta.active_goal_ids] against the live MASC goal store.
    Returns only goal IDs that actually exist. Logs pruned IDs at warn level. *)
let validate_active_goal_ids ~(config : Workspace.config) ~(meta : keeper_meta) () =
  let valid_goal_ids, invalid_goal_ids =
    List.partition
      (fun goal_id -> Option.is_some (Goal_store.get_goal config ~goal_id))
      meta.active_goal_ids
  in
  if invalid_goal_ids <> [] then
    Log.Keeper.warn ~keeper_name:meta.name
      "pruned %d invalid goal_ids from active_goal_ids: %s"
      (List.length invalid_goal_ids)
      (String.concat ", " invalid_goal_ids);
  valid_goal_ids

let backend_of_meta (meta : keeper_meta) =
  match meta.sandbox_profile with
  | Docker -> "docker"
  | Local -> "local"

let task_is_linked_to_keeper_goals ?(task_goal_index = Hashtbl.create 0) goal_ids (task : Masc_domain.task) =
  let task_goal_ids =
    try Hashtbl.find task_goal_index task.id with Not_found -> []
  in
  List.exists
    (fun goal_id -> List.mem goal_id task_goal_ids)
    goal_ids

(* A task is claimable-by-a-fresh-keeper only in [Todo]. Enumerate every
   [task_status] variant so a new constructor forces a decision here rather than
   silently widening "claimable" to e.g. a future [BlockedOnReview]. *)
let task_is_unclaimed_todo (task : Masc_domain.task) =
  match task.task_status with
  | Masc_domain.Todo -> true
  | Masc_domain.AwaitingVerification _
  | Masc_domain.Claimed _
  | Masc_domain.InProgress _
  | Masc_domain.Done _
  | Masc_domain.Cancelled _
  | Masc_domain.OperatorBlocked _ ->
    false

(* Closed set of claim-scope modes. Was a bare [string] (#20674): producers
   and consumers matched on free string literals, so the compiler could not
   force a consumer to handle a new mode, and a dropped producer left a dead
   [empty_goal_scope_fallback_all_tasks] arm frozen in the consumer. A closed
   variant makes every producer/consumer exhaustive at compile time. *)
type claim_scope_mode =
  | All_tasks
  | Active_goal_ids
  | Empty_goal_scope_fallback_all_tasks

let claim_scope_mode_to_string = function
  | All_tasks -> "all_tasks"
  | Active_goal_ids -> "active_goal_ids"
  | Empty_goal_scope_fallback_all_tasks -> "empty_goal_scope_fallback_all_tasks"

type claim_goal_scope = {
  task_filter : Masc_domain.task -> bool;
  mode : claim_scope_mode;
  effective_goal_ids : string list;
  fallback_reason : string option;
}

(* Pure in-memory scope derived from [meta] alone — no disk read. The
   [active_goal_ids] hard filter; an empty scope means all_tasks. *)
let meta_only_claim_goal_scope ?task_goal_index (meta : keeper_meta) =
  match meta.active_goal_ids with
  | [] ->
      {
        task_filter = (fun (_task : Masc_domain.task) -> true);
        mode = All_tasks;
        effective_goal_ids = [];
        fallback_reason = None;
      }
  | goal_ids ->
      {
        task_filter = task_is_linked_to_keeper_goals ?task_goal_index goal_ids;
        mode = Active_goal_ids;
        effective_goal_ids = goal_ids;
        fallback_reason = None;
      }

(* Resolve the claim filter for a keeper's [active_goal_ids].

   Goal-scope is a *priority hint*, not a hard gate: a keeper must never sit idle
   while the backlog holds claimable work. When the keeper's active goals have no
   claimable (Todo + unclaimed) task linked to them, widen the filter back to
   all_tasks and record [fallback_reason] so the widening is visible.

   Restores the [allow_empty_goal_scope_fallback] stopgap (RFC-0067 §1, PR
   #13673) that was dropped when the resolver was simplified to a pure in-memory
   match. Without it, a keeper whose goal carries no live task — or whose backlog
   tasks are all goal_id=None — is starved indefinitely (the observed
   "scope-blocked deadlock"). Note RFC-0067 §3's proposed *atomicity* design
   (scope-version tokens) is a separate, unimplemented direction; this is the
   stopgap, reinstated by operator decision, not that design.

   [resolve_claim_goal_scope] reads the backlog ([get_tasks_safe], a disk read)
   to test for a claimable scoped task. Call
   [resolve_claim_goal_scope_for_tasks] when the caller already loaded the
   backlog. Kept off the pure signal-only observation resolver
   ([resolve_observation_claim_goal_scope]). *)
let resolve_claim_goal_scope_for_tasks ~(config : Workspace.config)
    ~(meta : keeper_meta) ~(tasks : Masc_domain.task list) () =
  match meta.active_goal_ids with
  | [] -> meta_only_claim_goal_scope meta
  | goal_ids ->
    let task_goal_index = Workspace_goal_index.build_task_goal_index_for_config config in
    let scoped_claimable_exists =
      List.exists (fun task ->
             task_is_unclaimed_todo task
             && task_is_linked_to_keeper_goals ~task_goal_index goal_ids task)
        tasks
    in
    if scoped_claimable_exists then meta_only_claim_goal_scope ~task_goal_index meta
    else
      {
        task_filter = (fun (_task : Masc_domain.task) -> true);
        (* [Keeper_tool_task_runtime.claim_scope_context_suffix] exhaustively
           matches this constructor; the variant keeps the two sites in sync. *)
        mode = Empty_goal_scope_fallback_all_tasks;
        effective_goal_ids = goal_ids;
        fallback_reason = Some "no_scoped_claimable_tasks";
      }

let resolve_claim_goal_scope ~(config : Workspace.config) ~(meta : keeper_meta) () =
  let tasks = Workspace.get_tasks_safe config in
  resolve_claim_goal_scope_for_tasks ~config ~meta ~tasks ()

let resolve_observation_claim_goal_scope ~(config : Workspace.config)
    ~(meta : keeper_meta) () =
  (* Signal-only: the observation surface just needs the scope hint, not the
     claimability-aware fallback. Stays pure-meta so the per-turn observation
     path adds no backlog disk read. *)
  ignore config;
  meta_only_claim_goal_scope meta

let task_is_blocked (task : Masc_domain.task) =
  (* Enumerate every [task_status] variant so the compiler flags any new
     constructor here. The old [_ -> false] silently extended "not blocked"
     to any future status (e.g. a hypothetical [BlockedOnReview]) which
     would be exactly the wrong default for a blocked-task detector.
     RFC-0323 G-6: [AwaitingVerification] is the normal completion lane
     (submit -> verifier approve), not a blocked state — no current status
     is blocked; the exhaustive match stays as the decision point for any
     future genuinely-blocked constructor. *)
  match task.task_status with
  | Masc_domain.AwaitingVerification _
  | Masc_domain.Todo
  | Masc_domain.Claimed _
  | Masc_domain.InProgress _
  | Masc_domain.Done _
  | Masc_domain.Cancelled _
  | Masc_domain.OperatorBlocked _ ->
    false

let goal_progress_json ~(config : Workspace.config) (meta : keeper_meta) =
      let task_goal_index =
        Workspace_goal_index.build_task_goal_index_for_config config
      in
      let tasks =
        Workspace.get_tasks_safe config
        |> List.filter
             (task_is_linked_to_keeper_goals
                ~task_goal_index
                meta.active_goal_ids)
      in
      let linked_task_count = List.length tasks in
      let done_task_count =
        List.fold_left
          (fun acc (task : Masc_domain.task) ->
            if Masc_domain.task_status_is_done task.task_status then acc + 1 else acc)
          0 tasks
      in
      let open_task_count =
        List.fold_left
          (fun acc (task : Masc_domain.task) ->
            if Masc_domain.task_status_is_terminal task.task_status then acc else acc + 1)
          0 tasks
      in
      let blocked_task_count =
        List.fold_left
          (fun acc (task : Masc_domain.task) ->
            if task_is_blocked task then acc + 1 else acc)
          0 tasks
      in
      let convergence =
        if linked_task_count = 0 then `Null
        else `Float (float_of_int done_task_count /. float_of_int linked_task_count)
      in
      `Assoc
        [
          ("active_goal_count", `Int (List.length meta.active_goal_ids));
          ("linked_task_count", `Int linked_task_count);
          ("done_task_count", `Int done_task_count);
          ("open_task_count", `Int open_task_count);
          ("blocked_task_count", `Int blocked_task_count);
          ("convergence", convergence);
        ]

let approval_policy_effective_json ~base_path (meta : keeper_meta) =
  Keeper_approval_queue.policy_summary_json ~base_path ~keeper_name:meta.name

let string_opt_json = function
  | Some value when String.trim value <> "" -> `String value
  | _ -> `Null

let int_opt_json = function
  | Some value -> `Int value
  | None -> `Null

let nonempty_list = function
  | Some values -> values
  | None -> []

let backend_detail_keys =
  [ "sandbox_profile"; "network_mode"; "backend"; "sandbox_target" ]

let is_backend_detail_key key = List.mem key backend_detail_keys

let redact_backend_details = function
  | `Assoc fields ->
      `Assoc
        (List.filter
           (fun (key, _) -> not (is_backend_detail_key key))
           fields)
  | json -> json

let path_resolution_contract_json =
  `Assoc
    [ "read_implicit_cwd", `Bool false
    ; "read_explicit_cwd_supported", `Bool true
    ; ( "read_basis"
      , `String
          "Read file_path resolves against explicit cwd when cwd is provided; otherwise \
           it is relative to the keeper sandbox/allowed_paths. It does not inherit \
           Execute cwd implicitly." )
    ; ( "discover_before_read"
      , `String
          "When unsure, inspect visible paths with the currently exposed read/listing \
           tools before Read. For repo files, use cwd=\"repos/<repo>\" plus \
           file_path=\"lib/...\", or use file_path=\"repos/<repo>/lib/...\"."
      )
    ; ( "execute_path_basis"
      , `String
          "Execute path arguments resolve against cwd. If cwd=\"repos/<repo>\" is set, \
           pass repo-relative paths such as lib/...; do not repeat the repo prefix \
           as repos/<repo>/lib/..." )
    ; ( "masc_state_basis"
      , `String
          ".masc runtime state is not a sandbox filesystem target. Use keeper \
           task/context tools for .masc state instead of Read/Grep/Execute paths \
           under .masc." )
    ]

let runtime_observability_contract_json_from_fields ~keeper_name ?agent_name ?trace_id
    ?session_id ?generation ?keeper_turn_id ?task_id ?goal_ids
    ?sandbox_profile ?sandbox_root ?allowed_paths ?network_mode ?approval_mode
    ?runtime_profile () : Yojson.Safe.t =
  `Assoc
    [
      ("keeper_name", `String keeper_name);
      ("agent_name", string_opt_json agent_name);
      ("trace_id", string_opt_json trace_id);
      ("session_id", string_opt_json session_id);
      ("generation", int_opt_json generation);
      ("keeper_turn_id", int_opt_json keeper_turn_id);
      ("task_id", string_opt_json task_id);
      ("goal_ids", Json_util.json_string_list (nonempty_list goal_ids));
      ("sandbox_profile", string_opt_json sandbox_profile);
      ("sandbox_root", string_opt_json sandbox_root);
      ("allowed_paths", Json_util.json_string_list (nonempty_list allowed_paths));
      ("path_resolution", path_resolution_contract_json);
      ("network_mode", string_opt_json network_mode);
      ("approval_mode", string_opt_json approval_mode);
      ("runtime_profile", string_opt_json runtime_profile);
    ]

let runtime_contract_json_from_fields ~keeper_name ?agent_name ?trace_id
    ?session_id ?generation ?keeper_turn_id ?task_id ?goal_ids
    ?sandbox_profile ?sandbox_root ?allowed_paths ?network_mode ?approval_mode
    ?runtime_profile () : Yojson.Safe.t =
  runtime_observability_contract_json_from_fields
    ~keeper_name
    ?agent_name
    ?trace_id
    ?session_id
    ?generation
    ?keeper_turn_id
    ?task_id
    ?goal_ids
    ?sandbox_profile
    ?sandbox_root
    ?allowed_paths
    ?network_mode
    ?approval_mode
    ?runtime_profile
    ()
  |> redact_backend_details


let json_string_field name = function
  | `Assoc _ as json -> Json_util.get_string_nonempty json name
  | _ -> None

let first_string_field names json =
  List.find_map (fun name -> json_string_field name json) names

let path_like_key key =
  let key = String.lowercase_ascii key in
  key = "cwd" || key = "dir" || key = "directory" || key = "file"
  || String_util.contains_substring key "path"

let collect_observed_paths json =
  let rec loop acc = function
    | `Assoc fields ->
        List.fold_left
          (fun acc (key, value) ->
            match value with
            | `String path when path_like_key key && String.trim path <> "" ->
                path :: acc
            | other -> loop acc other)
          acc fields
    | `List values -> List.fold_left loop acc values
    | _ -> acc
  in
  loop [] json
  |> List.sort_uniq String.compare

let target_kind_of_input input target_path =
  match json_string_field "target_kind" input with
  | Some value -> value
  | None -> (
      match json_string_field "kind" input with
      | Some value -> value
      | None -> (
          match target_path with
          | Some _ -> "path"
          | None -> "tool"))

let action_radius_json ~tool_name ~input ~success ~duration_ms ?error
    ?sandbox_target () : Yojson.Safe.t =
  let action_key =
    first_string_field [ "action"; "action_key"; "op"; "cmd"; "command" ] input
    |> Option.value ~default:tool_name
  in
  let target_path =
    first_string_field
      [
        "target_path";
        "path";
        "file_path";
        "repo_path";
        "cwd";
      ]
      input
  in
  `Assoc
    [
      ("tool_name", `String tool_name);
      ("action_key", `String action_key);
      ("target_kind", `String (target_kind_of_input input target_path));
      ("target_path", string_opt_json target_path);
      ("sandbox_target", string_opt_json sandbox_target);
      ("observed_paths", Json_util.json_string_list (collect_observed_paths input));
      ("success", `Bool success);
      ("duration_ms", `Float duration_ms);
      ("error", string_opt_json error);
    ]

let runtime_contract_json ~(config : Workspace.config) (meta : keeper_meta) : Yojson.Safe.t =
  let goal_progress = goal_progress_json ~config meta in
  let blocked_task_count =
    Safe_ops.json_int "blocked_task_count" ~default:0 goal_progress
  in
  `Assoc
    [
      ("task_id", Json_util.string_opt_to_json (current_task_id_opt meta));
      ("goal_id", Json_util.string_opt_to_json (primary_goal_id_opt meta));
      ("goal_ids", `List (List.map (fun goal_id -> `String goal_id) meta.active_goal_ids));
      ("goal_progress", goal_progress);
      ("blocked_task_count", `Int blocked_task_count);
      ("approval_policy_effective", approval_policy_effective_json ~base_path:config.base_path meta);
    ]

let runtime_observability_contract_json ~(config : Workspace.config) (meta : keeper_meta) : Yojson.Safe.t =
  let sandbox_target = backend_of_meta meta in
  match runtime_contract_json ~config meta with
  | `Assoc fields ->
    `Assoc
      ([
         ("sandbox_profile", `String (sandbox_profile_to_string meta.sandbox_profile));
         ("network_mode", `String (network_mode_to_string meta.network_mode));
         ("backend", `String sandbox_target);
         ("sandbox_target", `String sandbox_target);
       ]
       @ fields)
  | json -> json
