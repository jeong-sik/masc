(** Dashboard Goals — goal tree with explicit task linkage, health badges,
    and goal-first detail evidence. *)

open Yojson.Safe.Util



(* Types + task helpers moved to Dashboard_goals_types. *)
include Dashboard_goals_types

(* receipt_* / trust_* / iso_max / stagnation_threshold helpers moved to Dashboard_goals_types. *)



let observe_goal_attainment_metrics (goal : Goal_store.goal) attainment =
  let labels = [ ("goal_id", goal.id) ] in
  let measured, pct =
    match attainment |> member "attainment_pct" |> to_int_option with
    | Some pct -> (1.0, float_of_int pct)
    | None -> (0.0, 0.0)
  in
  Prometheus.register_gauge ~name:Prometheus.metric_goal_attainment_pct
    ~help:goal_attainment_pct_help ~labels ();
  Prometheus.set_gauge Prometheus.metric_goal_attainment_pct ~labels pct;
  Prometheus.register_gauge ~name:Prometheus.metric_goal_attainment_measured
    ~help:goal_attainment_measured_help ~labels ();
  Prometheus.set_gauge Prometheus.metric_goal_attainment_measured ~labels
    measured





type build_context = {
  now_ts : float;
  all_tasks : Masc_domain.task list;
  pending_approvals : Yojson.Safe.t list;
  keeper_metas : Keeper_types.keeper_meta list;
  latest_receipts : (string * Yojson.Safe.t) list;
  latest_runtime_trusts : (string * Yojson.Safe.t) list;
}

let keeper_runtime_trust_snapshot_json ~config ~(meta : Keeper_types.keeper_meta) =
  try Keeper_runtime_trust_snapshot.snapshot_json ~config ~meta with
  | exn ->
      let error = Printexc.to_string exn in
      `Assoc
        [
          ("disposition", `String "Pause");
          ("disposition_reason", `String "runtime_trust_snapshot_unavailable");
          ("needs_attention", `Bool true);
          ("attention_reason", `String "runtime_trust_snapshot_unavailable");
          ("next_human_action", `String "inspect_keeper_runtime_trust");
          ("snapshot_error", `String error);
          ("latest_causal_event", `Null);
          ("causal_timeline", `List []);
        ]




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
  let direct_pending_approvals =
    context.pending_approvals
    |> List.filter (approval_matches_goal goal.Goal_store.id)
  in
  let direct_task_keeper_names =
    linked_tasks
    |> List.filter_map (fun ((task, _) : Masc_domain.task * string) ->
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
  let direct_receipt_refs =
    direct_linked_keeper_names
    |> List.filter_map (fun keeper_name ->
           List.assoc_opt keeper_name context.latest_receipts
           |> Option.map (fun receipt -> (keeper_name, receipt)))
  in
  let direct_receipts =
    direct_receipt_refs |> List.map snd
  in
  let direct_runtime_trusts =
    direct_linked_keeper_names
    |> List.filter_map (fun keeper_name ->
           List.assoc_opt keeper_name context.latest_runtime_trusts
           |> Option.map (fun trust -> (keeper_name, trust)))
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
  let task_activity_values =
    linked_tasks
    |> List.map (fun ((task, _) : Masc_domain.task * string) -> task_updated_at task)
  in
  let approval_activity_values =
    direct_pending_approvals
    |> List.filter_map (fun json ->
           json |> member "requested_at_iso" |> to_string_option)
  in
  let receipt_activity_values =
    direct_receipts |> List.filter_map receipt_ended_at
  in
  let runtime_activity_values =
    direct_runtime_trusts
    |> List.filter_map (fun (_, trust) -> trust_latest_event_ts trust)
  in
  let direct_observed_activity_values =
    task_activity_values @ approval_activity_values @ receipt_activity_values
    @ runtime_activity_values
  in
  let direct_last_activity_values =
    goal.Goal_store.updated_at :: direct_observed_activity_values
  in
  let child_observed_activity_values =
    children
    |> List.filter_map (fun child ->
           if String.equal child.activity_observation "goal_metadata" then None
           else Some child.last_activity_at)
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
          -. Masc_domain.parse_iso8601 ~default_time:context.now_ts last_activity_at))
  in
  let direct_sandbox_risk =
    List.exists receipt_has_sandbox_risk direct_receipts
    || List.exists (fun (_, trust) -> trust_sandbox_risk trust) direct_runtime_trusts
  in
  let direct_cascade_risk =
    List.exists receipt_has_cascade_risk direct_receipts
    || List.exists (fun (_, trust) -> trust_cascade_risk trust) direct_runtime_trusts
  in
  let blocked_by_receipt =
    List.exists receipt_has_error direct_receipts
  in
  let direct_runtime_blocking_reason =
    direct_runtime_trusts
    |> List.find_map (fun (_keeper_name, trust) ->
           if trust_snapshot_unavailable trust && direct_receipts <> [] then
             None
           else
             match trust_disposition trust with
             | Some "Alert" ->
                 (match trust_attention_reason trust with
                  | Some _ as reason -> reason
                  | None -> trust_disposition_reason trust)
             | Some "Pause" when trust_needs_attention trust ->
                 (match trust_attention_reason trust with
                  | Some _ as reason -> reason
                  | None -> trust_disposition_reason trust)
             | _ -> None)
  in
  let direct_fsm_risk =
    List.exists
      (fun ((task, _) : Masc_domain.task * string) ->
        match task.task_status with
        | Masc_domain.AwaitingVerification _ -> true
        | Masc_domain.Todo | Masc_domain.Claimed _ | Masc_domain.InProgress _ | Masc_domain.Done _
        | Masc_domain.Cancelled _ ->
            false)
      linked_tasks
  in
  let open_linked_task_count =
    linked_tasks
    |> List.filter (fun ((task, _) : Masc_domain.task * string) ->
           not (task_is_terminal task))
    |> List.length
  in
  let done_linked_task_count =
    linked_tasks
    |> List.filter (fun ((task, _) : Masc_domain.task * string) -> task_is_done task)
    |> List.length
  in
  let linkage_warning_reason =
    match goal.Goal_store.phase with
    | Goal_phase.Executing
    | Goal_phase.Awaiting_verification
    | Goal_phase.Awaiting_approval ->
        if linked_tasks = [] && children = [] && direct_linked_keeper_names = [] then
          Some "no_linked_tasks"
        else if linked_tasks <> [] && open_linked_task_count = 0
                && done_linked_task_count = 0 then
          Some "no_open_work"
        else if open_linked_task_count > 0 && direct_linked_keeper_names = [] then
          Some "unstaffed"
        else
          None
    | Goal_phase.Completed | Goal_phase.Blocked | Goal_phase.Paused
    | Goal_phase.Dropped ->
        None
  in
  let activity_observation =
    if runtime_activity_values <> [] || receipt_activity_values <> [] then
      "runtime"
    else if approval_activity_values <> [] then
      "approval"
    else if task_activity_values <> [] then
      "task"
    else if child_observed_activity_values <> [] then
      "child"
    else
      "goal_metadata"
  in
  let stale_by_threshold =
    stagnation_seconds >= stagnation_threshold_seconds goal.Goal_store.horizon
  in
  let observed_for_stagnation =
    not (String.equal activity_observation "goal_metadata")
  in
  let stalled = stale_by_threshold && observed_for_stagnation in
  let stagnation_status =
    if stalled then "stalled"
    else if stale_by_threshold then "unobserved"
    else "recent"
  in
  let direct_badges =
    tree_badges ~pending_approvals:(List.length direct_pending_approvals)
      ~sandbox_risk:direct_sandbox_risk ~cascade_risk:direct_cascade_risk
      ~fsm_risk:direct_fsm_risk ~stalled
      ~activity_unobserved:(String.equal stagnation_status "unobserved")
  in
  let direct_badges =
    match linkage_warning_reason with
    | Some reason -> reason :: direct_badges
    | None -> direct_badges
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
    + List.length
        (List.filter
           (fun (_, trust) ->
             if trust_snapshot_unavailable trust && direct_receipts <> [] then
               false
             else
               match trust_disposition trust with
               | Some "Alert" -> true
               | Some "Pause" -> trust_needs_attention trust
               | _ -> false)
           direct_runtime_trusts)
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
  let linkage_warning_count =
    (if Option.is_some linkage_warning_reason then 1 else 0)
    + List.fold_left
        (fun acc (child : tree_node) -> acc + child.linkage_warning_count)
        0 children
  in
  let at_risk =
    pending_approval_count > 0
    || infra_risk_count > 0
    || Option.is_some direct_runtime_blocking_reason
    || direct_fsm_risk
    || Option.is_some linkage_warning_reason
    || stalled
    || child_at_risk
  in
  let health =
    tree_health ~goal_phase:goal.Goal_store.phase ~blocked_by_receipt
      ~child_blocked ~at_risk
  in
  let status_reason =
    goal_health_reason ~goal_phase:goal.Goal_store.phase ~blocked_by_receipt
      ~child_blocked ~pending_approvals:pending_approval_count
      ~sandbox_risk:direct_sandbox_risk ~cascade_risk:direct_cascade_risk
      ~fsm_risk:direct_fsm_risk ~stalled
      ~stagnation_seconds ~child_at_risk ~linkage_warning_reason
      ~activity_observation ~stagnation_status
  in
  let blocking_source, blocking_reason =
    match goal.Goal_store.phase with
    | Goal_phase.Blocked | Goal_phase.Dropped ->
        ("goal_phase", status_reason)
    | Goal_phase.Completed | Goal_phase.Paused | Goal_phase.Executing
    | Goal_phase.Awaiting_verification | Goal_phase.Awaiting_approval ->
        if child_blocked then
          ("child_goal", "A linked sub-goal is blocked.")
        else if pending_approval_count > 0 then
          ("approval", status_reason)
        else if Option.is_some direct_runtime_blocking_reason then
          ( "keeper_runtime",
            Option.value direct_runtime_blocking_reason ~default:status_reason )
        else if direct_fsm_risk then
          ("task_fsm", status_reason)
        else if Option.is_some linkage_warning_reason then
          ("goal_linkage", status_reason)
        else if stalled then
          ("stalled", status_reason)
        else
          ("none", status_reason)
  in
  let latest_receipt_ref =
    direct_receipt_refs
    |> List.sort (fun (_, left) (_, right) ->
           String.compare
             (Option.value ~default:"" (receipt_ended_at right))
             (Option.value ~default:"" (receipt_ended_at left)))
    |> function
    | (keeper_name, receipt) :: _ -> (Some keeper_name, receipt_turn_count receipt)
    | [] -> (None, None)
  in
  let latest_runtime_ref =
    direct_runtime_trusts
    |> List.filter (fun (_, trust) ->
           Option.is_some (trust_latest_event_ts_unix trust))
    |> List.sort (fun (_, left) (_, right) ->
           Float.compare
             (Option.value ~default:0.0 (trust_latest_event_ts_unix right))
             (Option.value ~default:0.0 (trust_latest_event_ts_unix left)))
    |> function
    | (keeper_name, trust) :: _ -> Some (Some keeper_name, trust_turn_id trust)
    | [] -> None
  in
  let latest_linked_keeper_ref =
    match direct_linked_keeper_names with
    | keeper_name :: _ -> (Some keeper_name, None)
    | [] -> (None, None)
  in
  let latest_keeper_ref, latest_turn_ref =
    match latest_runtime_ref with
    | Some latest -> latest
    | None -> (
        match latest_receipt_ref with
        | Some _, _ -> latest_receipt_ref
        | None, _ -> latest_linked_keeper_ref)
  in
  let stalled_since =
    if stalled then Some last_activity_at else None
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
    blocking_source;
    blocking_reason;
    latest_keeper_ref;
    latest_turn_ref;
    stalled_since;
    activity_observation;
    stagnation_status;
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
      latest_runtime_trusts =
        keeper_metas
        |> List.map (fun (meta : Keeper_types.keeper_meta) ->
               ( meta.name,
                 keeper_runtime_trust_snapshot_json ~config ~meta ));
    }
  in
  goals
  |> List.filter is_root
  |> List.map (build_tree context goals)



let build_goal_verification_projection ~(config : Coord.config) goals =
  let requests =
    Goal_verification.read_state config |> fun (state : Goal_verification.state) ->
    state.requests
  in
  let effective_policy_table = Hashtbl.create (max 16 (List.length goals)) in
  let request_table = Hashtbl.create (max 16 (List.length requests)) in
  let latest_request_table :
      (string, Goal_verification.goal_verification_request) Hashtbl.t =
    Hashtbl.create (max 16 (List.length requests))
  in
  let goal_events =
    let path = Goal_verification.events_path config in
    if Coord.path_exists config path then
      Fs_compat.load_jsonl path
    else
      []
  in
  let events_table = Hashtbl.create (max 16 (List.length goals)) in
  let policy_nodes = goal_policy_nodes goals in
  List.iter
    (fun (goal : Goal_store.goal) ->
      match
        Goal_verification.effective_policy_for_nodes ~goals:policy_nodes
          ~goal_id:goal.id
      with
      | Ok policy -> Hashtbl.replace effective_policy_table goal.id policy
      | Error _ -> Hashtbl.replace effective_policy_table goal.id None)
    goals;
  List.iter
    (fun (request : Goal_verification.goal_verification_request) ->
      let should_replace_latest =
        match Hashtbl.find_opt latest_request_table request.goal_id with
        | None -> true
        | Some existing -> String.compare request.created_at existing.created_at >= 0
      in
      if should_replace_latest then
        Hashtbl.replace latest_request_table request.goal_id request;
      if request.status = Goal_verification.Open then
        Hashtbl.replace request_table request.goal_id request)
    requests;
  List.iter
    (fun json ->
      match json |> member "goal_id" |> to_string_option with
      | Some goal_id ->
          let existing =
            Option.value (Hashtbl.find_opt events_table goal_id) ~default:[]
          in
          Hashtbl.replace events_table goal_id (existing @ [ json ])
      | None -> ())
    goal_events;
  ( (fun goal_id ->
      Option.value (Hashtbl.find_opt effective_policy_table goal_id)
        ~default:None),
    (fun goal_id -> Hashtbl.find_opt request_table goal_id),
    (fun goal_id -> Hashtbl.find_opt latest_request_table goal_id),
    (fun goal_id ->
      Option.value (Hashtbl.find_opt events_table goal_id) ~default:[]) )

let rec tree_node_to_json ?(effective_policy_for_goal = fun _ -> None)
    ?(open_request_for_goal = fun _ -> None)
    ?(latest_request_for_goal = fun _ -> None) ?(events_for_goal = fun _ -> [])
    node =
  let goal = node.goal in
  let effective_policy = effective_policy_for_goal goal.id in
  let open_request = open_request_for_goal goal.id in
  let latest_request = latest_request_for_goal goal.id in
  let summary_request =
    match open_request with
    | Some request -> Some request
    | None -> latest_request
  in
  let approve_count, reject_count, remaining_possible =
    match summary_request with
    | None -> (0, 0, 0)
    | Some request ->
        ( Goal_verification.count_votes ~decision:Goal_verification.Approve request,
          Goal_verification.count_votes ~decision:Goal_verification.Reject request,
          Goal_verification.remaining_possible_votes request )
  in
  `Assoc
    [
      ("id", `String goal.id);
      ("title", `String goal.title);
      ("horizon", Goal_store.horizon_to_yojson goal.horizon);
      ("status", Goal_store.goal_status_to_yojson goal.status);
      ("status_color", `String (goal_status_color goal.status));
      ("phase", Goal_phase.to_yojson goal.phase);
      ("phase_color", `String (goal_phase_color goal.phase));
      ("goal_fsm", goal_fsm_to_json ~effective_policy goal node);
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
      ( "attainment",
        let attainment = goal_attainment_to_json goal node in
        observe_goal_attainment_metrics goal attainment;
        attainment );
      ("tasks", `List (List.map task_to_tree_json node.tasks));
      ("task_count", `Int (List.length node.tasks));
      ("task_done_count",
       `Int
         (List.length
            (List.filter
               (fun ((task, _) : Masc_domain.task * string) -> task_is_done task)
               node.tasks)));
      ( "verification_summary",
        `Assoc
          [
            ( "effective_policy",
              match effective_policy with
              | Some policy -> Goal_verification.policy_snapshot_to_yojson policy
              | None -> `Null );
            ( "open_request",
              match open_request with
              | Some request ->
                  Goal_verification.goal_verification_request_to_yojson request
              | None -> `Null );
            ( "latest_request",
              match latest_request with
              | Some request ->
                  Goal_verification.goal_verification_request_to_yojson request
              | None -> `Null );
            ("approve_count", `Int approve_count);
            ("reject_count", `Int reject_count);
            ("remaining_possible", `Int remaining_possible);
          ] );
      ( "effective_verifier_policy",
        match effective_policy with
        | Some policy -> Goal_verification.policy_snapshot_to_yojson policy
        | None -> `Null );
      ( "active_verification_request",
        match open_request with
        | Some request -> Goal_verification.goal_verification_request_to_yojson request
        | None -> `Null );
      ("pending_verification_count", `Int (if open_request = None then 0 else 1));
      ("timeline_events", `List (events_for_goal goal.id));
      ( "children",
        `List
          (List.map
             (tree_node_to_json ~effective_policy_for_goal ~open_request_for_goal
                ~latest_request_for_goal ~events_for_goal)
             node.children) );
      ("child_count", `Int (List.length node.children));
      ("last_activity_at", `String node.last_activity_at);
      ("stagnation_seconds", `Int node.stagnation_seconds);
      ("activity_observation", `String node.activity_observation);
      ("stagnation_status", `String node.stagnation_status);
      ( "linked_keeper_names",
        `List
          (List.map (fun keeper_name -> `String keeper_name) node.linked_keeper_names)
      );
      ("pending_approval_count", `Int node.pending_approval_count);
      ("infra_risk_count", `Int node.infra_risk_count);
      ("linkage_source", `String node.linkage_source);
      ("linkage_warning_count", `Int node.linkage_warning_count);
      ("blocking_source", `String node.blocking_source);
      ("blocking_reason", `String node.blocking_reason);
      ("latest_keeper_ref", Json_util.string_opt_to_json node.latest_keeper_ref);
      ("latest_turn_ref", Json_util.int_opt_to_json node.latest_turn_ref);
      ("stalled_since", Json_util.string_opt_to_json node.stalled_since);
      ("created_at", `String goal.created_at);
      ("updated_at", `String goal.updated_at);
    ]



let goal_detail_json ~(config : Coord.config) ~goal_id :
    (Yojson.Safe.t, string) result =
  let goals = Goal_store.list_goals config () in
  let tasks = Coord.get_tasks_safe config in
  let ( effective_policy_for_goal,
        open_request_for_goal,
        latest_request_for_goal,
        events_for_goal ) =
    build_goal_verification_projection ~config goals
  in
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
                   let latest_receipt =
                     List.assoc_opt meta.name
                       (Keeper_execution_receipt.latest_json_by_keeper
                          config node.linked_keeper_names)
                   in
                   let runtime_trust =
                     let snapshot =
                       keeper_runtime_trust_snapshot_json ~config ~meta
                     in
                     if trust_snapshot_unavailable snapshot then
                       match latest_receipt with
                       | Some receipt ->
                           runtime_trust_from_receipt_fallback ~config ~meta receipt
                       | None -> snapshot
                     else
                       snapshot
                   in
                   Some
                     {
                       meta;
                       latest_receipt;
                       runtime_trust;
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
      let goal_events = events_for_goal goal_id in
      Ok
        (`Assoc
          [
            ("generated_at", `String (Masc_domain.now_iso ()));
            ( "goal",
              tree_node_to_json ~effective_policy_for_goal ~open_request_for_goal
                ~latest_request_for_goal ~events_for_goal node );
            ("linked_tasks", `List (List.map task_to_tree_json node.tasks));
            ("linked_keepers", `List (List.map goal_detail_keeper_json keeper_details));
            ("approvals", `List approvals);
            ("execution_receipts", `List latest_receipts);
            ( "timeline",
              `List
                (build_goal_timeline node keeper_details approvals goal_events) );
          ])

let dashboard_goals_tree_json ~(config : Coord.config) : Yojson.Safe.t =
  let goals = Goal_store.list_goals config () in
  let tasks = Coord.get_tasks_safe config in
  let ( effective_policy_for_goal,
        open_request_for_goal,
        latest_request_for_goal,
        events_for_goal ) =
    build_goal_verification_projection ~config goals
  in
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
               (fun ((task, _) : Masc_domain.task * string) -> task_is_done task)
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
  let active_goal_count =
    goals
    |> List.filter (fun (goal : Goal_store.goal) -> goal.status = Goal_store.Active)
    |> List.length
  in
  let pending_approval_total =
    match Keeper_approval_queue.list_pending_dashboard_json () with
    | `List items -> List.length items
    | _ -> 0
  in
  `Assoc
    [
      ("generated_at", `String (Masc_domain.now_iso ()));
      ( "tree",
        `List
          (List.map
             (tree_node_to_json ~effective_policy_for_goal ~open_request_for_goal
                ~latest_request_for_goal ~events_for_goal)
             forest) );
      ( "summary",
        `Assoc
          [
            ("total_goals", `Int total_goals);
            ("active_goals", `Int active_goal_count);
            ("on_track_goals", `Int (count_health "on_track"));
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
