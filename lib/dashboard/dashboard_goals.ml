(** Dashboard Goals — goal tree with explicit task linkage, health badges,
    and goal-first detail evidence. *)

open Yojson.Safe.Util

type tree_node = {
  goal : Goal_store.goal;
  children : tree_node list;
  tasks : (Types.task * string) list;
  convergence : float;  (** 0.0 .. 1.0 completion ratio *)
  health : string;
  badges : string list;
  last_activity_at : string;
  stagnation_seconds : int;
  linked_keeper_names : string list;
  pending_approval_count : int;
  infra_risk_count : int;
  linkage_source : string;
  linkage_warning_count : int;
  status_reason : string;
}

type goal_detail_keeper = {
  meta : Keeper_types.keeper_meta;
  latest_receipt : Yojson.Safe.t option;
}

let title_contains_goal_tag ~goal_id title =
  let pattern = Printf.sprintf "[goal:%s]" goal_id in
  try
    let _ =
      Re.Str.search_forward
        (Re.Str.regexp_string (String.lowercase_ascii pattern))
        (String.lowercase_ascii title) 0
    in
    true
  with Not_found -> false

let task_is_linked_to_goal (task : Types.task) goal_id =
  match task.goal_id with
  | Some typed_goal_id -> String.equal typed_goal_id goal_id
  | None -> title_contains_goal_tag ~goal_id task.title

let task_linkage_source_opt (task : Types.task) goal_id =
  match task.goal_id with
  | Some task_goal_id when String.equal task_goal_id goal_id -> Some "explicit"
  | Some _ -> None
  | None ->
      if title_contains_goal_tag ~goal_id task.title then Some "title_tag"
      else None

let task_conflicts_with_goal_tag (task : Types.task) goal_id =
  match task.goal_id with
  | Some task_goal_id ->
      (not (String.equal task_goal_id goal_id))
      && title_contains_goal_tag ~goal_id task.title
  | None -> false

let task_assignee (task : Types.task) : string option =
  Types.task_assignee_of_status task.task_status

let task_status_label (task : Types.task) : string =
  match task.task_status with
  | Types.Todo -> "pending"
  | Types.Claimed _ -> "claimed"
  | Types.InProgress _ -> "in_progress"
  | Types.AwaitingVerification _ -> "awaiting_verification"
  | Types.Done _ -> "completed"
  | Types.Cancelled _ -> "cancelled"

let task_is_terminal (task : Types.task) : bool =
  Types.task_status_is_terminal task.task_status

let task_is_done (task : Types.task) : bool =
  Types.task_status_is_done task.task_status

let task_updated_at (task : Types.task) : string =
  match task.task_status with
  | Types.Done { completed_at; _ } -> completed_at
  | Types.Cancelled { cancelled_at; _ } -> cancelled_at
  | Types.InProgress { started_at; _ } -> started_at
  | Types.AwaitingVerification { submitted_at; _ } -> submitted_at
  | Types.Claimed { claimed_at; _ } -> claimed_at
  | Types.Todo -> task.created_at

let dedupe_sort values =
  values |> List.sort_uniq String.compare

let link_source_of_values values =
  let normalized =
    values
    |> List.filter (fun value -> value <> "" && not (String.equal value "none"))
    |> dedupe_sort
  in
  match normalized with
  | [] -> "none"
  | [ source ] -> source
  | _ -> "mixed"

let receipt_error_kind json =
  json |> member "error" |> member "kind" |> to_string_option

let receipt_error_message json =
  json |> member "error" |> member "message" |> to_string_option

let receipt_sandbox_effective_kind json =
  json |> member "sandbox" |> member "effective_kind" |> to_string_option

let receipt_approval_profile json =
  json |> member "approval" |> member "profile" |> to_string_option

let receipt_cascade_name json =
  json |> member "cascade" |> member "name" |> to_string_option

let receipt_cascade_outcome json =
  json |> member "cascade" |> member "outcome" |> to_string_option

let receipt_cascade_fallback_applied json =
  json |> member "cascade" |> member "fallback_applied" |> to_bool_option
  |> Option.value ~default:false

let receipt_outcome json =
  json |> member "outcome" |> to_string_option

let receipt_started_at json =
  json |> member "started_at" |> to_string_option

let receipt_ended_at json =
  json |> member "ended_at" |> to_string_option

let receipt_has_error json =
  match receipt_error_kind json with
  | Some _ -> true
  | None ->
      (match receipt_outcome json with
       | Some "completed" | Some "success" | Some "not_observed" | None -> false
       | Some _ -> false)

let receipt_has_sandbox_risk json =
  match receipt_sandbox_effective_kind json with
  | Some "observe_only" -> true
  | Some "local_playground" -> false
  | Some "worktree" -> false
  | Some "docker" -> false
  | Some _ | None -> false

let receipt_has_cascade_risk json =
  receipt_cascade_fallback_applied json
  ||
  match receipt_cascade_outcome json with
  | Some "passed_to_next_model" -> true
  | _ -> false

let iso_max left right =
  if String.compare left right >= 0 then left else right

let latest_iso ?fallback values =
  match values with
  | [] -> fallback
  | first :: rest ->
      Some (List.fold_left iso_max first rest)

let stagnation_threshold_seconds = function
  | Goal_store.Short -> 6 * 3600
  | Goal_store.Mid -> 24 * 3600
  | Goal_store.Long -> 72 * 3600

let human_duration seconds =
  if seconds < 3600 then Printf.sprintf "%dm" (seconds / 60)
  else if seconds < 86400 then Printf.sprintf "%dh" (seconds / 3600)
  else Printf.sprintf "%dd" (seconds / 86400)

let compute_convergence (goal : Goal_store.goal) linked_tasks children =
  let goal_done_weight =
    match goal.status with
    | Goal_store.Done -> 1.0
    | Goal_store.Active | Goal_store.Paused | Goal_store.Dropped -> 0.0
  in
  let task_count = List.length linked_tasks in
  let done_count =
    List.length
      (List.filter
         (fun ((task, _) : Types.task * string) -> task_is_done task)
         linked_tasks)
  in
  let task_ratio =
    if task_count = 0 then goal_done_weight
    else float_of_int done_count /. float_of_int task_count
  in
  let child_ratios =
    List.map (fun (child : tree_node) -> child.convergence) children
  in
  let child_avg =
    match child_ratios with
    | [] -> task_ratio
    | rs ->
        let sum = List.fold_left ( +. ) 0.0 rs in
        sum /. float_of_int (List.length rs)
  in
  if task_count > 0 && children <> [] then
    (task_ratio +. child_avg) /. 2.0
  else if children <> [] then
    child_avg
  else
    task_ratio

let approval_matches_goal goal_id approval_json =
  let goal_ids =
    approval_json |> member "goal_ids" |> to_list
    |> List.filter_map to_string_option
  in
  List.mem goal_id goal_ids
  ||
  match approval_json |> member "goal_id" |> to_string_option with
  | Some pending_goal_id -> String.equal pending_goal_id goal_id
  | None -> false

let keeper_name_matches_meta metas name =
  List.exists (fun (meta : Keeper_types.keeper_meta) -> String.equal meta.name name) metas

let keeper_name_of_assignee metas assignee =
  match Keeper_types.canonical_keeper_name_from_agent_name assignee with
  | Some keeper_name -> Some keeper_name
  | None ->
      if keeper_name_matches_meta metas assignee then Some assignee
      else None

let goal_status_to_health = function
  | Goal_store.Done -> Some "done"
  | Goal_store.Paused -> Some "paused"
  | Goal_store.Dropped -> Some "blocked"
  | Goal_store.Active -> None

let goal_health_reason ~goal_status ~blocked_by_receipt ~child_blocked
    ~pending_approvals ~sandbox_risk ~cascade_risk ~fsm_risk ~stalled
    ~linkage_warning_count ~stagnation_seconds ~child_at_risk =
  match goal_status_to_health goal_status with
  | Some "done" -> "Goal status is done."
  | Some "paused" -> "Goal status is paused."
  | Some "blocked" -> "Goal status is dropped."
  | Some _ | None ->
      if blocked_by_receipt then "Recent keeper execution ended with an error."
      else if child_blocked then "A linked sub-goal is blocked."
      else if pending_approvals > 0 then
        Printf.sprintf "%d approval request(s) are still pending."
          pending_approvals
      else if sandbox_risk then
        "Linked keeper is constrained by the current sandbox or scope."
      else if cascade_risk then
        "Latest keeper run fell back within the configured cascade."
      else if fsm_risk then
        "Linked task is waiting on FSM verification or remediation."
      else if stalled then
        Printf.sprintf "No linked activity for %s."
          (human_duration stagnation_seconds)
      else if linkage_warning_count > 0 then
        "Legacy title tags conflict with explicit goal linkage."
      else if child_at_risk then
        "A linked sub-goal is at risk."
      else
        "Linked tasks and keepers are progressing."

let tree_health ~goal_status ~blocked_by_receipt ~child_blocked ~at_risk =
  match goal_status_to_health goal_status with
  | Some health -> health
  | None ->
      if blocked_by_receipt || child_blocked then "blocked"
      else if at_risk then "at_risk"
      else "on_track"

let tree_badges ~pending_approvals ~sandbox_risk ~cascade_risk ~fsm_risk ~stalled
    ~linkage_warning_count =
  let badges = ref [] in
  if pending_approvals > 0 then badges := "awaiting_approval" :: !badges;
  if sandbox_risk then badges := "sandbox" :: !badges;
  if cascade_risk then badges := "cascade" :: !badges;
  if fsm_risk then badges := "fsm" :: !badges;
  if stalled then badges := "stalled" :: !badges;
  if linkage_warning_count > 0 then badges := "linkage_warning" :: !badges;
  List.rev !badges

type build_context = {
  now_ts : float;
  all_tasks : Types.task list;
  pending_approvals : Yojson.Safe.t list;
  keeper_metas : Keeper_types.keeper_meta list;
  latest_receipts : (string * Yojson.Safe.t) list;
}

let rec build_tree context goals goal =
  let child_goals =
    List.filter
      (fun (candidate : Goal_store.goal) ->
        candidate.parent_goal_id = Some goal.Goal_store.id)
      goals
  in
  let children = List.map (build_tree context goals) child_goals in
  let linked_tasks =
    context.all_tasks
    |> List.filter_map (fun task ->
           task_linkage_source_opt task goal.Goal_store.id
           |> Option.map (fun source -> (task, source)))
  in
  let direct_linkage_source =
    linked_tasks |> List.map snd |> link_source_of_values
  in
  let linkage_warning_count =
    List.length
      (List.filter
         (fun task -> task_conflicts_with_goal_tag task goal.Goal_store.id)
         context.all_tasks)
  in
  let direct_pending_approvals =
    context.pending_approvals
    |> List.filter (approval_matches_goal goal.Goal_store.id)
  in
  let direct_task_keeper_names =
    linked_tasks
    |> List.filter_map (fun ((task, _) : Types.task * string) ->
           match task_assignee task with
           | Some assignee ->
               keeper_name_of_assignee context.keeper_metas assignee
           | None -> None)
  in
  let direct_goal_keeper_names =
    context.keeper_metas
    |> List.filter (fun (meta : Keeper_types.keeper_meta) ->
           List.mem goal.Goal_store.id meta.active_goal_ids)
    |> List.map (fun (meta : Keeper_types.keeper_meta) -> meta.name)
  in
  let direct_linked_keeper_names =
    dedupe_sort (direct_task_keeper_names @ direct_goal_keeper_names)
  in
  let direct_receipts =
    direct_linked_keeper_names
    |> List.filter_map (fun keeper_name ->
           List.assoc_opt keeper_name context.latest_receipts)
  in
  let child_blocked =
    List.exists (fun (child : tree_node) -> String.equal child.health "blocked")
      children
  in
  let child_at_risk =
    List.exists
      (fun (child : tree_node) ->
        String.equal child.health "at_risk"
        || String.equal child.health "blocked")
      children
  in
  let direct_last_activity_values =
    goal.Goal_store.updated_at
    :: (linked_tasks
        |> List.map (fun ((task, _) : Types.task * string) -> task_updated_at task))
    @ (direct_pending_approvals
       |> List.filter_map (fun json ->
              json |> member "requested_at_iso" |> to_string_option))
    @ (direct_receipts |> List.filter_map receipt_ended_at)
  in
  let child_last_activity_values =
    children |> List.map (fun child -> child.last_activity_at)
  in
  let last_activity_at =
    latest_iso
      ~fallback:goal.Goal_store.updated_at
      (direct_last_activity_values @ child_last_activity_values)
    |> Option.value ~default:goal.Goal_store.updated_at
  in
  let stagnation_seconds =
    int_of_float
      (max 0.0
         (context.now_ts
          -. Types.parse_iso8601 ~default_time:context.now_ts last_activity_at))
  in
  let direct_sandbox_risk =
    List.exists receipt_has_sandbox_risk direct_receipts
  in
  let direct_cascade_risk =
    List.exists receipt_has_cascade_risk direct_receipts
  in
  let blocked_by_receipt =
    List.exists receipt_has_error direct_receipts
  in
  let direct_fsm_risk =
    List.exists
      (fun ((task, _) : Types.task * string) ->
        match task.task_status with
        | Types.AwaitingVerification _ | Types.Cancelled _ -> true
        | Types.Todo | Types.Claimed _ | Types.InProgress _ | Types.Done _ ->
            false)
      linked_tasks
  in
  let stalled =
    stagnation_seconds >= stagnation_threshold_seconds goal.Goal_store.horizon
  in
  let direct_badges =
    tree_badges ~pending_approvals:(List.length direct_pending_approvals)
      ~sandbox_risk:direct_sandbox_risk ~cascade_risk:direct_cascade_risk
      ~fsm_risk:direct_fsm_risk ~stalled ~linkage_warning_count
  in
  let badges =
    dedupe_sort
      (direct_badges
       @ List.concat_map (fun (child : tree_node) -> child.badges) children)
  in
  let pending_approval_count =
    List.length direct_pending_approvals
    + List.fold_left
        (fun acc (child : tree_node) -> acc + child.pending_approval_count)
        0 children
  in
  let direct_infra_risk_count =
    List.length
      (List.filter
         (fun json ->
           receipt_has_error json || receipt_has_sandbox_risk json
           || receipt_has_cascade_risk json)
         direct_receipts)
  in
  let infra_risk_count =
    direct_infra_risk_count
    + List.fold_left
        (fun acc (child : tree_node) -> acc + child.infra_risk_count)
        0 children
  in
  let linked_keeper_names =
    dedupe_sort
      (direct_linked_keeper_names
       @ List.concat_map
           (fun (child : tree_node) -> child.linked_keeper_names)
           children)
  in
  let linkage_source =
    link_source_of_values
      (direct_linkage_source
       :: List.map (fun (child : tree_node) -> child.linkage_source) children)
  in
  let at_risk =
    pending_approval_count > 0
    || infra_risk_count > 0
    || direct_fsm_risk
    || stalled
    || linkage_warning_count > 0
    || child_at_risk
  in
  let health =
    tree_health ~goal_status:goal.Goal_store.status ~blocked_by_receipt
      ~child_blocked ~at_risk
  in
  let status_reason =
    goal_health_reason ~goal_status:goal.Goal_store.status ~blocked_by_receipt
      ~child_blocked ~pending_approvals:pending_approval_count
      ~sandbox_risk:direct_sandbox_risk ~cascade_risk:direct_cascade_risk
      ~fsm_risk:direct_fsm_risk ~stalled ~linkage_warning_count
      ~stagnation_seconds ~child_at_risk
  in
  let convergence = compute_convergence goal linked_tasks children in
  {
    goal;
    children;
    tasks = linked_tasks;
    convergence;
    health;
    badges;
    last_activity_at;
    stagnation_seconds;
    linked_keeper_names;
    pending_approval_count;
    infra_risk_count;
    linkage_source;
    linkage_warning_count;
    status_reason;
  }

let build_forest ~(config : Coord.config) ~goals ~tasks =
  let goal_ids = List.map (fun (goal : Goal_store.goal) -> goal.id) goals in
  let is_root (goal : Goal_store.goal) =
    match goal.parent_goal_id with
    | None -> true
    | Some parent_id -> not (List.mem parent_id goal_ids)
  in
  let keeper_metas =
    Keeper_types.keeper_names config
    |> List.filter_map (fun keeper_name ->
           match Keeper_types.read_meta config keeper_name with
           | Ok (Some meta) -> Some meta
           | Ok None | Error _ -> None)
  in
  let pending_approvals =
    match Keeper_approval_queue.list_pending_dashboard_json () with
    | `List items -> items
    | _ -> []
  in
  let latest_receipts =
    keeper_metas
    |> List.map (fun (meta : Keeper_types.keeper_meta) -> meta.name)
    |> Keeper_execution_receipt.latest_json_by_keeper config
  in
  let context =
    {
      now_ts = Time_compat.now ();
      all_tasks = tasks;
      pending_approvals;
      keeper_metas;
      latest_receipts;
    }
  in
  goals
  |> List.filter is_root
  |> List.map (build_tree context goals)

let goal_status_color = function
  | Goal_store.Active -> "#4ade80"
  | Goal_store.Paused -> "#f59e0b"
  | Goal_store.Done -> "#60a5fa"
  | Goal_store.Dropped -> "#6b7280"

let goal_health_color = function
  | "done" -> "#60a5fa"
  | "paused" -> "#f59e0b"
  | "blocked" -> "#ef4444"
  | "at_risk" -> "#f59e0b"
  | "on_track" -> "#4ade80"
  | _ -> "#94a3b8"

let task_status_color status_label =
  match status_label with
  | "pending" -> "#6b7280"
  | "claimed" -> "#f59e0b"
  | "in_progress" -> "#3b82f6"
  | "awaiting_verification" -> "#a78bfa"
  | "completed" -> "#4ade80"
  | "cancelled" -> "#ef4444"
  | _ -> "#888888"

let task_to_tree_json ((task, linkage_source) : Types.task * string) =
  let status = task_status_label task in
  `Assoc
    [
      ("id", `String task.id);
      ("title", `String task.title);
      ("goal_id", Json_util.string_opt_to_json task.goal_id);
      ("status", `String status);
      ("status_color", `String (task_status_color status));
      ("priority", `Int task.priority);
      ("assignee",
       match task_assignee task with
       | Some assignee -> `String assignee
       | None -> `Null);
      ("goal_id",
       match task.goal_id with
       | Some goal_id -> `String goal_id
       | None -> `Null);
      ("linkage_source", `String linkage_source);
      ("is_terminal", `Bool (task_is_terminal task));
      ("created_at", `String task.created_at);
      ("updated_at", `String (task_updated_at task));
    ]

let rec tree_node_to_json node =
  let goal = node.goal in
  `Assoc
    [
      ("id", `String goal.id);
      ("title", `String goal.title);
      ("horizon", Goal_store.horizon_to_yojson goal.horizon);
      ("status", Goal_store.goal_status_to_yojson goal.status);
      ("status_color", `String (goal_status_color goal.status));
      ("health", `String node.health);
      ("health_color", `String (goal_health_color node.health));
      ("badges", `List (List.map (fun badge -> `String badge) node.badges));
      ("status_reason", `String node.status_reason);
      ("priority", `Int goal.priority);
      ("metric",
       match goal.metric with Some metric -> `String metric | None -> `Null);
      ("target_value",
       match goal.target_value with Some value -> `String value | None -> `Null);
      ("due_date",
       match goal.due_date with Some due_date -> `String due_date | None -> `Null);
      ("parent_goal_id",
       match goal.parent_goal_id with
       | Some parent_goal_id -> `String parent_goal_id
       | None -> `Null);
      ("convergence", `Float node.convergence);
      ("convergence_pct", `Int (int_of_float (node.convergence *. 100.0)));
      ("tasks", `List (List.map task_to_tree_json node.tasks));
      ("task_count", `Int (List.length node.tasks));
      ("task_done_count",
       `Int
         (List.length
            (List.filter
               (fun ((task, _) : Types.task * string) -> task_is_done task)
               node.tasks)));
      ("children", `List (List.map tree_node_to_json node.children));
      ("child_count", `Int (List.length node.children));
      ("last_activity_at", `String node.last_activity_at);
      ("stagnation_seconds", `Int node.stagnation_seconds);
      ( "linked_keeper_names",
        `List
          (List.map (fun keeper_name -> `String keeper_name) node.linked_keeper_names)
      );
      ("pending_approval_count", `Int node.pending_approval_count);
      ("infra_risk_count", `Int node.infra_risk_count);
      ("linkage_source", `String node.linkage_source);
      ("linkage_warning_count", `Int node.linkage_warning_count);
      ("created_at", `String goal.created_at);
      ("updated_at", `String goal.updated_at);
    ]

let rec flatten_tree acc = function
  | [] -> List.rev acc
  | node :: rest ->
      flatten_tree (node :: acc) (node.children @ rest)

let goal_detail_keeper_json (detail : goal_detail_keeper) =
  let meta = detail.meta in
  let latest_receipt = detail.latest_receipt in
  let latest_execution_outcome =
    match latest_receipt with
    | Some receipt -> receipt_outcome receipt
    | None -> None
  in
  `Assoc
    [
      ("name", `String meta.name);
      ("agent_name", `String meta.agent_name);
      ( "current_task_id",
        match meta.current_task_id with
        | Some task_id -> `String (Keeper_id.Task_id.to_string task_id)
        | None -> `Null );
      ( "active_goal_ids",
        `List (List.map (fun goal_id -> `String goal_id) meta.active_goal_ids) );
      ( "sandbox_profile",
        `String (Keeper_types.sandbox_profile_to_string meta.sandbox_profile) );
      ( "execution_scope",
        `String (Keeper_execution_scope.to_string meta.execution_scope) );
      ("network_mode", `String (Keeper_types.network_mode_to_string meta.network_mode));
      ("cascade_name", `String meta.cascade_name);
      ( "approval_profile",
        match latest_receipt with
        | Some receipt ->
            (match receipt_approval_profile receipt with
             | Some profile -> `String profile
             | None -> `Null)
        | None -> `Null );
      ( "sandbox_effective_kind",
        match latest_receipt with
        | Some receipt ->
            (match receipt_sandbox_effective_kind receipt with
             | Some effective_kind -> `String effective_kind
             | None -> `Null)
        | None -> `Null );
      ( "cascade_outcome",
        match latest_receipt with
        | Some receipt ->
            (match receipt_cascade_outcome receipt with
             | Some outcome -> `String outcome
             | None -> `Null)
        | None -> `Null );
      ( "latest_execution_outcome",
        match latest_execution_outcome with
        | Some outcome -> `String outcome
        | None -> `Null );
      ( "latest_execution_at",
        match latest_receipt with
        | Some receipt ->
            (match receipt_ended_at receipt with
             | Some ended_at -> `String ended_at
             | None -> `Null)
        | None -> `Null );
      ( "latest_receipt",
        match latest_receipt with
        | Some receipt -> receipt
        | None -> `Null );
    ]

let timeline_event_json ~ts ~kind ~lane ~title ~summary ~severity =
  `Assoc
    [
      ("ts", `String ts);
      ("kind", `String kind);
      ("lane", `String lane);
      ("title", `String title);
      ("summary", `String summary);
      ("severity", `String severity);
    ]

let build_goal_timeline node linked_keepers approvals =
  let task_events =
    node.tasks
    |> List.map (fun ((task, linkage_source) : Types.task * string) ->
           let status = task_status_label task in
           timeline_event_json ~ts:(task_updated_at task) ~kind:"task"
             ~lane:("task:" ^ task.id)
             ~title:task.title
             ~summary:
               (Printf.sprintf "%s · linkage=%s" status linkage_source)
             ~severity:
               (match status with
                | "cancelled" -> "bad"
                | "awaiting_verification" | "claimed" | "in_progress" ->
                    "warn"
                | _ -> "ok"))
  in
  let approval_events =
    approvals
    |> List.filter_map (fun approval ->
           match approval |> member "requested_at_iso" |> to_string_option with
           | None -> None
           | Some requested_at ->
               let approval_id =
                 approval |> member "id" |> to_string_option
                 |> Option.value ~default:"approval"
               in
               let tool_name =
                 approval |> member "tool_name" |> to_string_option
                 |> Option.value ~default:"tool"
               in
               Some
                 (timeline_event_json ~ts:requested_at ~kind:"approval"
                    ~lane:("approval:" ^ approval_id)
                    ~title:(Printf.sprintf "Approval · %s" tool_name)
                    ~summary:
                      (approval |> member "input_preview" |> to_string_option
                       |> Option.value ~default:"pending operator decision")
                    ~severity:"warn"))
  in
  let keeper_events =
    linked_keepers
    |> List.filter_map (fun (detail : goal_detail_keeper) ->
           match detail.latest_receipt with
           | None -> None
           | Some receipt -> (
               match receipt_ended_at receipt with
               | None -> None
               | Some ended_at ->
                   let outcome =
                     receipt_outcome receipt |> Option.value ~default:"unknown"
                   in
                   let severity =
                     if receipt_has_error receipt then "bad"
                     else if receipt_has_sandbox_risk receipt
                             || receipt_has_cascade_risk receipt
                     then "warn"
                     else "ok"
                   in
                   Some
                     (timeline_event_json ~ts:ended_at ~kind:"keeper_receipt"
                        ~lane:("keeper:" ^ detail.meta.name)
                        ~title:(Printf.sprintf "Keeper · %s" detail.meta.name)
                        ~summary:
                          (Printf.sprintf "%s · %s"
                             outcome
                             (receipt_cascade_name receipt
                              |> Option.value ~default:detail.meta.cascade_name))
                        ~severity)))
  in
  task_events @ approval_events @ keeper_events
  |> List.sort (fun left right ->
         let lts = left |> member "ts" |> to_string_option |> Option.value ~default:"" in
         let rts = right |> member "ts" |> to_string_option |> Option.value ~default:"" in
         String.compare rts lts)

let goal_detail_json ~(config : Coord.config) ~goal_id :
    (Yojson.Safe.t, string) result =
  let goals = Goal_store.list_goals config () in
  let tasks = Coord.get_tasks_safe config in
  let forest = build_forest ~config ~goals ~tasks in
  let all_nodes = flatten_tree [] forest in
  match List.find_opt (fun (node : tree_node) -> String.equal node.goal.id goal_id) all_nodes with
  | None -> Error (Printf.sprintf "Goal %s not found" goal_id)
  | Some node ->
      let keeper_details =
        Keeper_types.keeper_names config
        |> List.filter_map (fun keeper_name ->
               match Keeper_types.read_meta config keeper_name with
               | Ok (Some meta) when List.mem meta.name node.linked_keeper_names ->
                   Some
                     {
                       meta;
                       latest_receipt =
                         List.assoc_opt meta.name
                           (Keeper_execution_receipt.latest_json_by_keeper
                              config node.linked_keeper_names);
                     }
               | Ok None | Error _ | Ok (Some _) -> None)
      in
      let approvals =
        match Keeper_approval_queue.list_pending_dashboard_json () with
        | `List items ->
            items |> List.filter (approval_matches_goal goal_id)
        | _ -> []
      in
      let latest_receipts =
        keeper_details
        |> List.filter_map (fun detail ->
               detail.latest_receipt |> Option.map (fun receipt -> receipt))
      in
      Ok
        (`Assoc
          [
            ("generated_at", `String (Types.now_iso ()));
            ("goal", tree_node_to_json node);
            ("linked_tasks", `List (List.map task_to_tree_json node.tasks));
            ("linked_keepers", `List (List.map goal_detail_keeper_json keeper_details));
            ("approvals", `List approvals);
            ("execution_receipts", `List latest_receipts);
            ( "timeline",
              `List (build_goal_timeline node keeper_details approvals) );
          ])

let dashboard_goals_tree_json ~(config : Coord.config) : Yojson.Safe.t =
  let goals = Goal_store.list_goals config () in
  let tasks = Coord.get_tasks_safe config in
  let forest = build_forest ~config ~goals ~tasks in
  let all_nodes = flatten_tree [] forest in
  let total_goals = List.length goals in
  let total_tasks =
    List.fold_left
      (fun acc (node : tree_node) -> acc + List.length node.tasks)
      0 all_nodes
  in
  let done_tasks =
    List.fold_left
      (fun acc (node : tree_node) ->
        acc
        + List.length
            (List.filter
               (fun ((task, _) : Types.task * string) -> task_is_done task)
               node.tasks))
      0 all_nodes
  in
  let overall_convergence =
    match forest with
    | [] -> 0.0
    | roots ->
        let sum =
          List.fold_left (fun acc (node : tree_node) -> acc +. node.convergence)
            0.0 roots
        in
        sum /. float_of_int (List.length roots)
  in
  let count_health health =
    List.length
      (List.filter (fun (node : tree_node) -> String.equal node.health health) all_nodes)
  in
  let pending_approval_total =
    match Keeper_approval_queue.list_pending_dashboard_json () with
    | `List items -> List.length items
    | _ -> 0
  in
  `Assoc
    [
      ("generated_at", `String (Types.now_iso ()));
      ("tree", `List (List.map tree_node_to_json forest));
      ( "summary",
        `Assoc
          [
            ("total_goals", `Int total_goals);
            ("active_goals", `Int (count_health "on_track"));
            ("done_goals", `Int (count_health "done"));
            ("paused_goals", `Int (count_health "paused"));
            ("at_risk_goals", `Int (count_health "at_risk"));
            ("blocked_goals", `Int (count_health "blocked"));
            ("total_tasks", `Int total_tasks);
            ("done_tasks", `Int done_tasks);
            ("pending_approvals", `Int pending_approval_total);
            ( "infra_risk_count",
              `Int
                (List.fold_left
                   (fun acc (node : tree_node) -> acc + node.infra_risk_count)
                   0 forest) );
            ("overall_convergence", `Float overall_convergence);
            ( "overall_convergence_pct",
              `Int (int_of_float (overall_convergence *. 100.0)) );
          ] );
    ]
