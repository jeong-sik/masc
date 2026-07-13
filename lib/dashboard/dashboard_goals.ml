(** Dashboard Goals — goal tree with explicit task linkage and direct
    goal-first observations. *)




(* Types + task helpers moved to Dashboard_goals_types. *)
include Dashboard_goals_types

(* receipt_* / trust_* / iso_max helpers moved to Dashboard_goals_types. *)



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
          ("snapshot_status", `String "unavailable");
          ("snapshot_error", `String error);
          ("latest_causal_event", `Null);
          ("causal_timeline", `List []);
        ]





let build_forest ~(config : Workspace.config) ~goals ~tasks =
  let goal_ids = List.map (fun (goal : Goal_store.goal) -> goal.id) goals in
  let is_root (goal : Goal_store.goal) =
    match goal.parent_goal_id with
    | None -> true
    | Some parent_id -> not (List.mem parent_id goal_ids)
  in
  let keeper_metas =
    Keeper_meta_store.keeper_names config
    |> List.filter_map (fun keeper_name ->
           match Keeper_meta_store.read_meta config keeper_name with
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
    |> List.map (fun (meta : Keeper_meta_contract.keeper_meta) -> meta.name)
    |> Keeper_execution_receipt.latest_json_by_keeper config
  in
  let goal_task_index = Workspace_goal_index.build_task_goal_index_for_config config in
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



let build_goal_events_projection ~(config : Workspace.config) goals =
  let goal_events =
    let path =
      Filename.concat (Workspace_utils.masc_dir config) "goal_events.jsonl"
    in
    if Workspace.path_exists config path then
      Fs_compat.load_jsonl path
    else
      []
  in
  let events_table = Hashtbl.create (max 16 (List.length goals)) in
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
  fun goal_id ->
    Option.value (Hashtbl.find_opt events_table goal_id) ~default:[]

let emit_all_goal_attainment_metrics ~(config : Workspace.config) =
  let goals = Goal_store.list_goals config () in
  let tasks = Workspace.get_tasks_safe config in
  let forest = build_forest ~config ~goals ~tasks in
  let all_nodes = flatten_tree [] forest in
  List.iter
    (fun (node : tree_node) ->
      let goal = node.goal in
      let attainment = goal_attainment_to_json goal node in
      observe_goal_attainment_metrics goal attainment)
    all_nodes

let rec tree_node_to_json ?(events_for_goal = fun _ -> []) node =
  let goal = node.goal in
  let attainment = goal_attainment_to_json goal node in
  let task_summary = task_summary_to_json node.tasks in
  let completion_summary = goal_completion_to_json goal node ~attainment in
  observe_goal_attainment_metrics goal attainment;
  `Assoc
    [
      ("id", `String goal.id);
      ("title", `String goal.title);
      ("status", Goal_store.goal_status_to_yojson goal.status);
      ("status_color", `String (goal_status_color goal.status));
      ("phase", Goal_phase.to_yojson goal.phase);
      ("phase_color", `String (goal_phase_color goal.phase));
      ("goal_fsm", goal_fsm_to_json goal node);
      ("priority", `Int goal.priority);
      ("metric", Json_util.string_opt_to_json goal.metric);
      ("target_value", Json_util.string_opt_to_json goal.target_value);
      ("due_date", Json_util.string_opt_to_json goal.due_date);
      ("parent_goal_id", Json_util.string_opt_to_json goal.parent_goal_id);
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
      ("timeline_events", `List (events_for_goal goal.id));
      ( "children",
        `List
          (List.map
             (tree_node_to_json ~events_for_goal)
             node.children) );
      ("child_count", `Int (List.length node.children));
      ("last_activity_at", `String node.last_activity_at);
      ("stagnation_seconds", Json_util.int_opt_to_json node.stagnation_seconds);
      ("activity_observation", `String node.activity_observation);
      ( "linked_keeper_names",
        `List
          (List.map (fun keeper_name -> `String keeper_name) node.linked_keeper_names)
      );
      ("pending_approval_count", `Int node.pending_approval_count);
      ("linkage_source", `String node.linkage_source);
      ("latest_keeper_ref", Json_util.string_opt_to_json node.latest_keeper_ref);
      ("latest_turn_ref", Json_util.int_opt_to_json node.latest_turn_ref);
      ("created_at", `String goal.created_at);
      ("updated_at", `String goal.updated_at);
    ]



let goal_detail_json ~(config : Workspace.config) ~goal_id :
    (Yojson.Safe.t, string) result =
  let goals = Goal_store.list_goals config () in
  let tasks = Workspace.get_tasks_safe config in
  let events_for_goal = build_goal_events_projection ~config goals in
  let forest = build_forest ~config ~goals ~tasks in
  let all_nodes = flatten_tree [] forest in
  match List.find_opt (fun (node : tree_node) -> String.equal node.goal.id goal_id) all_nodes with
  | None -> Error (Printf.sprintf "Goal %s not found" goal_id)
  | Some node ->
      let keeper_details =
        Keeper_meta_store.keeper_names config
        |> List.filter_map (fun keeper_name ->
               match Keeper_meta_store.read_meta config keeper_name with
               | Ok (Some meta) when List.mem meta.name node.linked_keeper_names ->
                   let latest_receipt =
                     List.assoc_opt meta.name
                       (Keeper_execution_receipt.latest_json_by_keeper
                          config node.linked_keeper_names)
                   in
                   let runtime_trust =
                     keeper_runtime_trust_snapshot_json ~config ~meta
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
            ("goal", tree_node_to_json ~events_for_goal node);
            ("linked_tasks", `List (List.map task_to_tree_json node.tasks));
            ("linked_keepers", `List (List.map goal_detail_keeper_json keeper_details));
            ("approvals", `List approvals);
            ("execution_receipts", `List latest_receipts);
            ( "timeline",
              `List
                (build_goal_timeline node keeper_details approvals goal_events) );
          ])

let dashboard_goals_tree_json ~(config : Workspace.config) : Yojson.Safe.t =
  let goals = Goal_store.list_goals config () in
  let tasks = Workspace.get_tasks_safe config in
  let events_for_goal = build_goal_events_projection ~config goals in
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
  let count_phase phase =
    goals
    |> List.filter (fun (goal : Goal_store.goal) -> goal.phase = phase)
    |> List.length
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
             (tree_node_to_json ~events_for_goal)
             forest) );
      ( "summary",
        `Assoc
          [
            ("total_goals", `Int total_goals);
            ("active_goals", `Int active_goal_count);
            ( "phase_counts",
              `Assoc
                [
                  ("executing", `Int (count_phase Goal_phase.Executing));
                  ("blocked", `Int (count_phase Goal_phase.Blocked));
                  ("paused", `Int (count_phase Goal_phase.Paused));
                  ("completed", `Int (count_phase Goal_phase.Completed));
                  ("dropped", `Int (count_phase Goal_phase.Dropped));
                ] );
            ("total_tasks", `Int total_tasks);
            ("done_tasks", `Int done_tasks);
            ("pending_approvals", `Int pending_approval_total);
          ] );
    ]
