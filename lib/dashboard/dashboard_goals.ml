(** Dashboard Goals — goal tree with explicit task linkage and direct
    goal-first observations. *)




(* Types + task helpers moved to Dashboard_goals_types. *)
include Dashboard_goals_types

(* receipt_* / trust_* / iso_max helpers moved to Dashboard_goals_types. *)



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





let build_forest ~(config : Workspace.config) ~goals ~tasks
    ~(pending_approvals : Yojson.Safe.t list) =
  let keeper_metas =
    Keeper_meta_store.keeper_names config
    |> List.filter_map (fun keeper_name ->
           match Keeper_meta_store.read_meta config keeper_name with
           | Ok (Some meta) -> Some meta
           | Ok None | Error _ -> None)
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
  goals |> List.map (build_tree context goals)



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

let rec tree_node_to_json ?(events_for_goal = fun _ -> []) node =
  let goal = node.goal in
  let task_summary = task_summary_to_json node.tasks in
  `Assoc
    [
      ("id", `String goal.id);
      ("title", `String goal.title);
      ("phase", Goal_phase.to_yojson goal.phase);
      ("phase_color", `String (goal_phase_color goal.phase));
      ("goal_fsm", goal_fsm_to_json goal node);
      ("priority", `Int goal.priority);
      ("metric", Json_util.string_opt_to_json goal.metric);
      ("target_value", Json_util.string_opt_to_json goal.target_value);
      ("due_date", Json_util.string_opt_to_json goal.due_date);
      ("tasks", `List (List.map task_to_tree_json node.tasks));
      ("task_count", `Int (List.length node.tasks));
      ("task_done_count",
       `Int
         (List.length
            (List.filter
               (fun (task : Masc_domain.task) -> task_is_done task)
               node.tasks)));
      ("task_summary", task_summary);
      (* The normalizer, not the raw ledger row. [build_goal_events_projection]
         hands back whatever [goal_events.jsonl] holds — {event_type, payload} —
         and every consumer of this field reads the normalized shape
         {kind, lane, title, summary, severity}. The detail view has always
         mapped through [goal_event_timeline_json] (see [build_goal_timeline]);
         the tree emitted the raw rows, so the dashboard's strict decoder
         dropped all of them and every goal read as having no history (#29299). *)
      ( "timeline_events",
        `List (List.map goal_event_timeline_json (events_for_goal goal.id)) );
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
      ("latest_keeper_ref", Json_util.string_opt_to_json node.latest_keeper_ref);
      ("latest_turn_ref", Json_util.int_opt_to_json node.latest_turn_ref);
      ("created_at", `String goal.created_at);
      ("updated_at", `String goal.updated_at);
    ]



let goal_detail_json_ready ~(config : Workspace.config)
    ~(pending_approvals : Yojson.Safe.t list) ~goal_id :
    (Yojson.Safe.t, string) result =
  let goals = Goal_store.list_goals config () in
  let tasks = Workspace.get_tasks_safe config in
  let events_for_goal = build_goal_events_projection ~config goals in
  let forest = build_forest ~config ~goals ~tasks ~pending_approvals in
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
        pending_approvals |> List.filter (approval_matches_goal goal_id)
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
            ( "approval_queue_state",
              Keeper_approval_queue.approval_queue_ready_state_json );
            ("goal", tree_node_to_json ~events_for_goal node);
            ("linked_tasks", `List (List.map task_to_tree_json node.tasks));
            ("linked_keepers", `List (List.map goal_detail_keeper_json keeper_details));
            ("approvals", `List approvals);
            ("execution_receipts", `List latest_receipts);
            ( "timeline",
              `List
                (build_goal_timeline node keeper_details approvals goal_events) );
          ])

let goal_detail_json_with_pending_reader
    ~(read_pending :
       base_path:string ->
       (Yojson.Safe.t list, Keeper_approval_queue.storage_error) result)
    ~(config : Workspace.config) ~goal_id =
  match read_pending ~base_path:config.base_path with
  | Ok pending_approvals ->
      goal_detail_json_ready ~config ~pending_approvals ~goal_id
  | Error error ->
      Ok
        (`Assoc
          [
            ("generated_at", `String (Masc_domain.now_iso ()));
            ( "approval_queue_state",
              Keeper_approval_queue.approval_queue_unavailable_state_json
                error );
            ("goal", `Null);
            ("linked_tasks", `Null);
            ("linked_keepers", `Null);
            ("approvals", `Null);
            ("execution_receipts", `Null);
            ("timeline", `Null);
          ])

let goal_detail_json ~(config : Workspace.config) ~goal_id =
  goal_detail_json_with_pending_reader
    ~read_pending:
      Keeper_approval_queue.list_pending_dashboard_json_for_workspace
    ~config ~goal_id

let dashboard_goals_tree_json_ready ~(config : Workspace.config)
    ~(pending_approvals : Yojson.Safe.t list) : Yojson.Safe.t =
  let goals = Goal_store.list_goals config () in
  let tasks = Workspace.get_tasks_safe config in
  let events_for_goal = build_goal_events_projection ~config goals in
  let forest = build_forest ~config ~goals ~tasks ~pending_approvals in
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
               (fun (task : Masc_domain.task) -> task_is_done task)
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
    |> List.filter (fun (goal : Goal_store.goal) ->
           goal.phase = Goal_phase.Executing)
    |> List.length
  in
  let pending_approval_total = List.length pending_approvals in
  `Assoc
    [
      ("generated_at", `String (Masc_domain.now_iso ()));
      ( "approval_queue_state",
        Keeper_approval_queue.approval_queue_ready_state_json );
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
                  ("verifying", `Int (count_phase Goal_phase.Verifying));
                  ("completed", `Int (count_phase Goal_phase.Completed));
                  ("dropped", `Int (count_phase Goal_phase.Dropped));
                ] );
            ("total_tasks", `Int total_tasks);
            ("done_tasks", `Int done_tasks);
            ("pending_approvals", `Int pending_approval_total);
          ] );
    ]

let dashboard_goals_tree_json_with_pending_reader
    ~(read_pending :
       base_path:string ->
       (Yojson.Safe.t list, Keeper_approval_queue.storage_error) result)
    ~(config : Workspace.config) =
  match read_pending ~base_path:config.base_path with
  | Ok pending_approvals ->
      dashboard_goals_tree_json_ready ~config ~pending_approvals
  | Error error ->
      `Assoc
        [
          ("generated_at", `String (Masc_domain.now_iso ()));
          ( "approval_queue_state",
            Keeper_approval_queue.approval_queue_unavailable_state_json error );
          ("tree", `Null);
          ("summary", `Null);
        ]

let dashboard_goals_tree_json ~(config : Workspace.config) =
  dashboard_goals_tree_json_with_pending_reader
    ~read_pending:
      Keeper_approval_queue.list_pending_dashboard_json_for_workspace
    ~config