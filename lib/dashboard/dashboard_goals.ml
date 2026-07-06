(** Dashboard Goals — goal tree with explicit task linkage, health badges,
    and goal-first detail evidence. *)




(* Types + task helpers moved to Dashboard_goals_types. *)
include Dashboard_goals_types

(* receipt_* / trust_* / iso_max / stagnation_threshold helpers moved to Dashboard_goals_types. *)



let observe_goal_attainment_metrics (goal : Goal_store.goal) attainment =
  let labels = [ ("goal_id", goal.id) ] in
  let measured, pct =
    match Json_util.get_int attainment "attainment_pct" with
    | Some pct -> (1.0, float_of_int pct)
    | None -> (0.0, 0.0)
  in
  Otel_metric_store.register_gauge ~name:Otel_metric_store.metric_goal_attainment_pct
    ~help:goal_attainment_pct_help ~labels ();
  Otel_metric_store.set_gauge Otel_metric_store.metric_goal_attainment_pct ~labels pct;
  Otel_metric_store.register_gauge ~name:Otel_metric_store.metric_goal_attainment_measured
    ~help:goal_attainment_measured_help ~labels ();
  Otel_metric_store.set_gauge Otel_metric_store.metric_goal_attainment_measured ~labels
    measured

let keeper_runtime_trust_snapshot_json ~config ~(meta : Keeper_meta_contract.keeper_meta) =
  try Keeper_runtime_trust_snapshot.snapshot_json ~config ~meta with
  | exn ->
      let error = Printexc.to_string exn in
      `Assoc
        [
          ("disposition", `String "Blocked");
          ("disposition_reason", `String "runtime_trust_snapshot_unavailable");
          ("needs_attention", `Bool true);
          ("attention_reason", `String "runtime_trust_snapshot_unavailable");
          ("next_human_action", `String "inspect_keeper_runtime_trust");
          ("snapshot_error", `String error);
          ("latest_causal_event", `Null);
          ("causal_timeline", `List []);
        ]

type keeper_meta_scan =
  { keeper_metas : Keeper_meta_contract.keeper_meta list
  ; keeper_names_known : bool
  ; read_errors : Yojson.Safe.t list
  }

let keeper_meta_scan_read_error_json ?keeper ~source message =
  `Assoc
    ([
       ("source", `String source);
       ("message", `String message);
     ]
     @
     match keeper with
     | Some keeper_name -> [ ("keeper", `String keeper_name) ]
     | None -> [])

let read_keeper_metas_scan config =
  match Keeper_meta_store.keeper_names_result config with
  | Error err ->
      {
        keeper_metas = [];
        keeper_names_known = false;
        read_errors =
          [ keeper_meta_scan_read_error_json ~source:"keeper_names_result" err ];
      }
  | Ok keeper_names ->
      let keeper_metas, read_errors =
        List.fold_left
          (fun (metas, errors) keeper_name ->
            match Keeper_meta_store.read_meta config keeper_name with
            | Ok (Some meta) -> meta :: metas, errors
            | Ok None ->
                ( metas,
                  keeper_meta_scan_read_error_json
                    ~keeper:keeper_name
                    ~source:"read_meta"
                    "keeper meta missing after keeper name discovery"
                  :: errors )
            | Error err ->
                ( metas,
                  keeper_meta_scan_read_error_json
                    ~keeper:keeper_name
                    ~source:"read_meta"
                    err
                  :: errors ))
          ([], [])
          keeper_names
      in
      {
        keeper_metas = List.rev keeper_metas;
        keeper_names_known = true;
        read_errors = List.rev read_errors;
      }





let build_forest_with_goal_task_index
    ~(keeper_meta_scan : keeper_meta_scan)
    ~(config : Workspace.config)
    ~goals
    ~tasks
    ~goal_task_index =
  let goal_ids = List.map (fun (goal : Goal_store.goal) -> goal.id) goals in
  let is_root (goal : Goal_store.goal) =
    match goal.parent_goal_id with
    | None -> true
    | Some parent_id -> not (List.mem parent_id goal_ids)
  in
  let keeper_metas = keeper_meta_scan.keeper_metas in
  let pending_approvals =
    match Keeper_approval_queue.list_pending_dashboard_json () with
    | `List items -> items
    | _ -> []
  in
  let latest_receipts =
    keeper_metas
    |> List.map (fun (meta : Keeper_meta_contract.keeper_meta) -> meta.name)
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
        |> List.map (fun (meta : Keeper_meta_contract.keeper_meta) ->
               ( meta.name,
                 keeper_runtime_trust_snapshot_json ~config ~meta ));
      goal_task_index;
    }
  in
  goals
  |> List.filter is_root
  |> List.map (build_tree context goals)

let build_forest_result ~(config : Workspace.config) ~goals ~tasks =
  match Workspace_goal_index.build_task_goal_index_for_config_result config with
  | Ok goal_task_index ->
      let keeper_meta_scan = read_keeper_metas_scan config in
      Ok
        (build_forest_with_goal_task_index
           ~keeper_meta_scan
           ~config
           ~goals
           ~tasks
           ~goal_task_index)
  | Error msg -> Error (Workspace_goal_index.goal_task_links_read_failed_message msg)
;;

let build_forest_result_with_keeper_meta_scan ~(config : Workspace.config) ~goals ~tasks =
  match Workspace_goal_index.build_task_goal_index_for_config_result config with
  | Ok goal_task_index ->
      let keeper_meta_scan = read_keeper_metas_scan config in
      Ok
        ( build_forest_with_goal_task_index
            ~keeper_meta_scan
            ~config
            ~goals
            ~tasks
            ~goal_task_index,
          keeper_meta_scan )
  | Error msg -> Error (Workspace_goal_index.goal_task_links_read_failed_message msg)
;;

let build_forest ~(config : Workspace.config) ~goals ~tasks =
  match build_forest_result ~config ~goals ~tasks with
  | Ok forest -> forest
  | Error msg ->
      Log.Dashboard.warn
        "[dashboard_goals] goal-task link registry read failed: %s"
        msg;
      []
;;



let build_goal_verification_projection ~(config : Workspace.config) goals =
  let requests =
    match Goal_verification.read_state_result config with
    | Ok (state : Goal_verification.state) -> state.requests
    | Error msg ->
      Log.Dashboard.warn
        "[dashboard_goals] goal verification state read failed: %s"
        msg;
      []
  in
  let effective_policy_table = Hashtbl.create (max 16 (List.length goals)) in
  let request_table = Hashtbl.create (max 16 (List.length requests)) in
  let latest_request_table :
      (string, Goal_verification.goal_verification_request) Hashtbl.t =
    Hashtbl.create (max 16 (List.length requests))
  in
  let goal_events =
    let path = Goal_verification.events_path config in
    if Workspace.path_exists config path then
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
      match Json_util.get_string json "goal_id" with
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

let emit_all_goal_attainment_metrics ~(config : Workspace.config) =
  match Goal_store.list_goals_result config () with
  | Error msg ->
    Log.Dashboard.warn "[dashboard_goals] goal metrics skipped: %s" msg
  | Ok goals ->
    let tasks = Workspace.get_tasks_safe config in
    let ( _effective_policy_for_goal,
          _open_request_for_goal,
          _latest_request_for_goal,
          _events_for_goal ) =
      build_goal_verification_projection ~config goals
    in
    match build_forest_result ~config ~goals ~tasks with
    | Error msg ->
      Log.Dashboard.warn
        "[dashboard_goals] goal attainment metrics skipped: %s"
        msg
    | Ok forest ->
      let all_nodes = flatten_tree [] forest in
      List.iter
        (fun (node : tree_node) ->
          let goal = node.goal in
          let attainment = goal_attainment_to_json goal node in
          observe_goal_attainment_metrics goal attainment)
        all_nodes

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
  let attainment = goal_attainment_to_json goal node in
  let task_summary = task_summary_to_json node.tasks in
  let completion_summary =
    goal_completion_to_json ~effective_policy ~open_request goal node
      ~attainment
  in
  observe_goal_attainment_metrics goal attainment;
  `Assoc
    [
      ("id", `String goal.id);
      ("title", `String goal.title);
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
      ("metric", Json_util.string_opt_to_json goal.metric);
      ("target_value", Json_util.string_opt_to_json goal.target_value);
      ( "require_completion_approval",
        `Bool goal.Goal_store.require_completion_approval );
      ("due_date", Json_util.string_opt_to_json goal.due_date);
      ("parent_goal_id", Json_util.string_opt_to_json goal.parent_goal_id);
      ("convergence", `Float node.convergence);
      ("convergence_pct", `Int (int_of_float (node.convergence *. 100.0)));
      ("attainment", attainment);
      ("tasks", `List (List.map task_to_tree_json node.tasks));
      ("task_count", `Int (List.length node.tasks));
      ("task_done_count",
       `Int
         (List.length
            (List.filter
               (fun ((task, _) : Masc_domain.task * string) -> task_is_done task)
               node.tasks)));
      ("task_summary", task_summary);
      ("completion_summary", completion_summary);
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



let goal_detail_json ~(config : Workspace.config) ~goal_id :
    (Yojson.Safe.t, string) result =
  match Goal_store.list_goals_result config () with
  | Error msg -> Error msg
  | Ok goals ->
    let tasks = Workspace.get_tasks_safe config in
    let ( effective_policy_for_goal,
          open_request_for_goal,
          latest_request_for_goal,
          events_for_goal ) =
      build_goal_verification_projection ~config goals
    in
    match build_forest_result_with_keeper_meta_scan ~config ~goals ~tasks with
    | Error msg -> Error msg
    | Ok (forest, keeper_meta_scan) ->
      let all_nodes = flatten_tree [] forest in
      match List.find_opt (fun (node : tree_node) -> String.equal node.goal.id goal_id) all_nodes with
      | None -> Error (Printf.sprintf "Goal %s not found" goal_id)
      | Some node ->
      let keeper_details =
        keeper_meta_scan.keeper_metas
        |> List.filter_map (fun (meta : Keeper_meta_contract.keeper_meta) ->
               if List.mem meta.name node.linked_keeper_names then
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
               else
                 None)
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
            ("keeper_meta_known", `Bool keeper_meta_scan.keeper_names_known);
            ("keeper_meta_read_errors", `List keeper_meta_scan.read_errors);
            ("approvals", `List approvals);
            ("execution_receipts", `List latest_receipts);
            ( "timeline",
              `List
                (build_goal_timeline node keeper_details approvals goal_events) );
          ])

let unknown_dashboard_goals_tree_json
    ?(goal_store_known = true)
    ?goal_store_read_error
    ~goals
    ~pending_approval_total
    ~read_error
  =
  let active_goal_count =
    goals
    |> List.filter (fun (goal : Goal_store.goal) -> goal.status = Goal_store.Active)
    |> List.length
  in
  `Assoc
    [
      ("generated_at", `String (Masc_domain.now_iso ()));
      ("status", `String "unknown");
      ("goal_store_known", `Bool goal_store_known);
      ("goal_store_read_error", Json_util.string_opt_to_json goal_store_read_error);
      ("goal_task_links_known", `Bool false);
      ("goal_task_links_read_error", Json_util.string_opt_to_json read_error);
      ("tree", `List []);
      ( "summary",
        `Assoc
          [
            ("total_goals", `Int (List.length goals));
            ("active_goals", `Int active_goal_count);
            ("on_track_goals", `Null);
            ("done_goals", `Null);
            ("paused_goals", `Null);
            ("at_risk_goals", `Null);
            ("blocked_goals", `Null);
            ("total_tasks", `Null);
            ("done_tasks", `Null);
            ("pending_approvals", `Int pending_approval_total);
            ("infra_risk_count", `Null);
            ("overall_convergence", `Null);
            ("overall_convergence_pct", `Null);
          ] );
    ]
;;

let dashboard_goals_tree_json ~(config : Workspace.config) : Yojson.Safe.t =
  let pending_approval_total =
    match Keeper_approval_queue.list_pending_dashboard_json () with
    | `List items -> List.length items
    | _ -> 0
  in
  match Goal_store.list_goals_result config () with
  | Error goal_store_read_error ->
    unknown_dashboard_goals_tree_json
      ~goal_store_known:false
      ~goal_store_read_error
      ~goals:[]
      ~pending_approval_total
      ~read_error:None
  | Ok goals ->
    let tasks = Workspace.get_tasks_safe config in
    let ( effective_policy_for_goal,
          open_request_for_goal,
          latest_request_for_goal,
          events_for_goal ) =
      build_goal_verification_projection ~config goals
    in
    match build_forest_result_with_keeper_meta_scan ~config ~goals ~tasks with
    | Error read_error ->
      unknown_dashboard_goals_tree_json
        ~goals
        ~pending_approval_total
        ~read_error:(Some read_error)
    | Ok (forest, keeper_meta_scan) ->
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
      `Assoc
        [
          ("generated_at", `String (Masc_domain.now_iso ()));
          ("status", `String "ok");
          ("goal_store_known", `Bool true);
          ("goal_store_read_error", `Null);
          ("goal_task_links_known", `Bool true);
          ("goal_task_links_read_error", `Null);
          ("keeper_meta_known", `Bool keeper_meta_scan.keeper_names_known);
          ("keeper_meta_read_errors", `List keeper_meta_scan.read_errors);
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
