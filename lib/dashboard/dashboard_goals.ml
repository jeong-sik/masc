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
  match Workspace_goal_index.read_goal_task_links_authoritative_r config with
  | Error detail -> Error detail
  | Ok goal_task_links ->
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
  let goal_task_index = Workspace_goal_index.build_task_goal_index ~goal_task_links () in
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
  Ok (goals |> List.map (build_tree context goals))



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

(* One goal as the event log remembers it. Local to this reader: the JSON is the
   contract, and putting the record in the interface would invite a second
   reader of the same rows. *)
type goal_history_entry = {
  gh_opened_at : string option;
  gh_title : string option;
  gh_last_phase : string option;
  gh_last_phase_at : string option;
}

let empty_goal_history_entry =
  { gh_opened_at = None; gh_title = None;
    gh_last_phase = None; gh_last_phase_at = None }

(* Goals the event log remembers and goals.json no longer lists. goals.json
   holds only the current set, so a goal that reached a terminal phase and left
   it had no record anywhere that it had existed -- which is why "how many goals
   were opened" and "what were they" had no answer (#35359).

   This reads the log without asking the current list what to look for, which is
   the part [build_goal_events_projection] cannot do: its table holds every row,
   but its callers walk the current forest and so never ask about a goal that
   left.

   [opened_at] and [title] come from the [goal_created] row, so a goal opened
   before that row existed reports null rather than a guessed time. [closed_at]
   is filled only when the last phase reached is terminal -- a goal that left the
   list without one is a gap, and dating it would invent an outcome. A negative
   [lifetime_hours] is reported as measured rather than clamped: out-of-order
   rows are a fact about the log, not a number to tidy. Rows this reader does
   not recognise are counted and named under [coverage] instead of dropped. *)
let unlisted_goal_history_of_rows ~listed ~rows ~malformed_lines =
  let table = Hashtbl.create 16 in
  let rows_without_goal_id = ref 0 in
  let unrecognised = ref [] in
  let note_unrecognised name =
    if not (List.mem name !unrecognised) then unrecognised := name :: !unrecognised
  in
  List.iter
    (fun json ->
      match Json_util.get_string json "goal_id" with
      | None -> incr rows_without_goal_id
      | Some goal_id when List.mem goal_id listed -> ()
      | Some goal_id ->
        let ts = Json_util.get_string json "ts" in
        let payload = Yojson.Safe.Util.member "payload" json in
        let current =
          match Hashtbl.find_opt table goal_id with
          | Some entry -> entry
          | None -> empty_goal_history_entry
        in
        let updated =
          match Json_util.get_string json "event_type" with
          | Some "goal_created" ->
            { current with
              gh_opened_at = ts;
              gh_title = Json_util.get_string payload "title" }
          | Some "goal_phase" ->
            { current with
              gh_last_phase = Json_util.get_string payload "phase";
              gh_last_phase_at = ts }
          | Some other ->
            note_unrecognised other;
            current
          | None ->
            note_unrecognised "(no event_type)";
            current
        in
        Hashtbl.replace table goal_id updated)
    rows;
  let lifetime_hours opened closed =
    match opened, closed with
    | Some opened, Some closed -> (
      match
        Masc_domain.parse_iso8601_opt opened, Masc_domain.parse_iso8601_opt closed
      with
      | Some opened, Some closed when Float.is_finite (closed -. opened) ->
        Some ((closed -. opened) /. 3600.)
      | (Some _, _) | (None, _) -> None)
    | (None, _) | (_, None) -> None
  in
  let entry_json (goal_id, entry) =
    (* Every phase is named rather than folded into a catch-all, so a phase
       added later stops the compiler here instead of silently reading as
       "still open". *)
    let reached_terminal =
      match Option.bind entry.gh_last_phase Goal_phase.of_string with
      | Some Goal_phase.Completed | Some Goal_phase.Dropped -> true
      | Some Goal_phase.Executing
      | Some Goal_phase.Verifying
      | Some Goal_phase.Awaiting_confirmation
      | None -> false
    in
    let closed_at = if reached_terminal then entry.gh_last_phase_at else None in
    `Assoc
      [ "goal_id", `String goal_id
      ; "title", Json_util.string_opt_to_json entry.gh_title
      ; "opened_at", Json_util.string_opt_to_json entry.gh_opened_at
      ; "closed_at", Json_util.string_opt_to_json closed_at
      ; "final_phase", Json_util.string_opt_to_json entry.gh_last_phase
      ; ( "lifetime_hours"
        , match lifetime_hours entry.gh_opened_at closed_at with
          | Some hours -> `Float hours
          | None -> `Null )
      ]
  in
  (* Folded out of the table and sorted by id rather than tracked in a second
     list of insertion order: a hash table's own traversal order is not stable,
     and sorting is what makes two reads of one log agree. *)
  let ordered =
    Hashtbl.fold (fun goal_id entry acc -> (goal_id, entry) :: acc) table []
    |> List.sort (fun (left, _) (right, _) -> String.compare left right)
  in
  `Assoc
    [ "unlisted", `List (List.map entry_json ordered)
    ; ( "coverage"
      , `Assoc
          [ "malformed_event_lines", `Int malformed_lines
          ; "rows_without_goal_id", `Int !rows_without_goal_id
          ; ( "unrecognised_event_types"
            , `List (List.rev_map (fun name -> `String name) !unrecognised) )
          ] )
    ]

(* The file read kept apart from the counting above, so the counting is testable
   without a workspace on disk. *)
let unlisted_goal_history_json ~(config : Workspace.config) ~goals =
  let path =
    Filename.concat (Workspace_utils.masc_dir config) "goal_events.jsonl"
  in
  let rows, malformed_lines =
    if Workspace.path_exists config path
    then Fs_compat.load_jsonl_diagnostics path
    else ([], 0)
  in
  unlisted_goal_history_of_rows
    ~listed:(List.map (fun (goal : Goal_store.goal) -> goal.id) goals)
    ~rows
    ~malformed_lines

let verification_projection ~config =
  let records = Goal_verification.load_records_authoritative config in
  fun (goal : Goal_store.goal) ->
    match records with
    | Error detail -> Goal_verification.ledger_error_to_yojson detail
    | Ok records ->
        let record =
          match List.find_opt
            (fun (record : Goal_verification.record) -> String.equal record.goal_id goal.id) records with
          | Some record -> record
          | None ->
              (* The primary ledger decoded successfully and contains no row
                 for this Goal. Only this known absence projects idle; read
                 failures were returned above. *)
              Goal_verification.default_record ~goal_id:goal.id
        in
        Goal_verification.record_to_yojson_for_goal ~goal record

let rec tree_node_to_json ?(events_for_goal = fun _ -> [])
    ?(verification_for_goal = fun _ -> Goal_verification.ledger_error_to_yojson "proof source not loaded") node =
  let goal = node.goal in
  let task_summary = task_summary_to_json node.tasks in
  `Assoc
    [
      ("id", `String goal.id);
      ("title", `String goal.title);
      ("verification", verification_for_goal goal);
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
             (tree_node_to_json ~events_for_goal ~verification_for_goal)
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



let goal_store_unavailable_json detail =
  `Assoc
    [ "ok", `Bool false
    ; "error_code", `String "goal_store_unavailable"
    ; "error", `String detail
    ]

let goal_task_links_unavailable_json detail =
  `Assoc
    [ "ok", `Bool false
    ; "error_code", `String "goal_task_links_unavailable"
    ; "error", `String detail
    ]

let goal_detail_json_ready ~(config : Workspace.config)
    ~(pending_approvals : Yojson.Safe.t list) ~goal_id :
    (Yojson.Safe.t, string) result =
  match Goal_store.list_goals_result config () with
  | Error detail -> Ok (goal_store_unavailable_json detail)
  | Ok goals ->
  let tasks = Workspace.get_tasks_safe config in
  let events_for_goal = build_goal_events_projection ~config goals in
  let verification_for_goal = verification_projection ~config in
  match build_forest ~config ~goals ~tasks ~pending_approvals with
  | Error detail -> Ok (goal_task_links_unavailable_json detail)
  | Ok forest ->
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
            ("goal", tree_node_to_json ~events_for_goal ~verification_for_goal node);
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
  match Goal_store.list_goals_result config () with
  | Error detail -> goal_store_unavailable_json detail
  | Ok goals ->
  let tasks = Workspace.get_tasks_safe config in
  let events_for_goal = build_goal_events_projection ~config goals in
  let verification_for_goal = verification_projection ~config in
  match build_forest ~config ~goals ~tasks ~pending_approvals with
  | Error detail -> goal_task_links_unavailable_json detail
  | Ok forest ->
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
             (tree_node_to_json ~events_for_goal ~verification_for_goal)
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
                  ("awaiting_confirmation", `Int (count_phase Goal_phase.Awaiting_confirmation));
                  ("completed", `Int (count_phase Goal_phase.Completed));
                  ("dropped", `Int (count_phase Goal_phase.Dropped));
                ] );
            ("total_tasks", `Int total_tasks);
            ("done_tasks", `Int done_tasks);
            ("pending_approvals", `Int pending_approval_total);
          ] );
      ("goal_history", unlisted_goal_history_json ~config ~goals);
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