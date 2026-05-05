(** Read model for Goal x Task x Board x Reward coordination snapshots. *)

type severity_counts =
  { info : int
  ; warn : int
  ; error : int
  }

type observed_state =
  { goals : Goal_store.goal list
  ; tasks : Masc_domain.task list
  ; posts : Board.post list
  ; transactions : Agent_economy.transaction list
  ; telemetry_events : Telemetry_eio.event_record list
  ; persist_errors : int
  ; economy_enabled : bool
  }

let unique_strings items =
  List.fold_left
    (fun acc item ->
      let item = String.trim item in
      if item = "" || List.exists (String.equal item) acc then acc else item :: acc)
    []
    items
  |> List.rev
;;

let assoc_string_opt key = function
  | `Assoc fields ->
    (match List.assoc_opt key fields with
     | Some (`String value) when String.trim value <> "" -> Some value
     | _ -> None)
  | _ -> None
;;

let assoc_string_list key = function
  | `Assoc fields ->
    (match List.assoc_opt key fields with
     | Some (`List values) ->
       List.filter_map
         (function
           | `String value when String.trim value <> "" -> Some value
           | _ -> None)
         values
     | Some (`String value) when String.trim value <> "" -> [ value ]
     | _ -> [])
  | _ -> []
;;

let meta_string key (post : Board.post) =
  match post.meta_json with
  | Some meta -> assoc_string_opt key meta
  | None -> None
;;

let meta_string_list key (post : Board.post) =
  match post.meta_json with
  | Some meta -> assoc_string_list key meta
  | None -> []
;;

let post_id_string (post : Board.post) = Board.Post_id.to_string post.id

let compare_desc_float_then_string ~float_value ~string_value left right =
  let by_time = Float.compare (float_value right) (float_value left) in
  if by_time <> 0 then by_time else String.compare (string_value left) (string_value right)
;;

let compare_goal_id (left : Goal_store.goal) (right : Goal_store.goal) =
  String.compare left.id right.id
;;

let compare_task_id (left : Masc_domain.task) (right : Masc_domain.task) =
  String.compare left.id right.id
;;

let compare_post_activity left right =
  compare_desc_float_then_string
    ~float_value:(fun (post : Board.post) -> post.updated_at)
    ~string_value:post_id_string
    left
    right
;;

let compare_transaction_activity left right =
  compare_desc_float_then_string
    ~float_value:(fun (txn : Agent_economy.transaction) -> txn.timestamp)
    ~string_value:(fun txn -> txn.id)
    left
    right
;;

let telemetry_event_sort_key = function
  | Telemetry_eio.Agent_joined { agent_id; capabilities } ->
    Printf.sprintf "agent_joined:%s:%s" agent_id (String.concat "," capabilities)
  | Telemetry_eio.Agent_left { agent_id; reason } ->
    Printf.sprintf "agent_left:%s:%s" agent_id reason
  | Telemetry_eio.Task_started { task_id; agent_id } ->
    Printf.sprintf "task_started:%s:%s" task_id agent_id
  | Telemetry_eio.Task_completed { task_id; duration_ms; success } ->
    Printf.sprintf "task_completed:%s:%d:%b" task_id duration_ms success
  | Telemetry_eio.Handoff_triggered { from_agent; to_agent; reason } ->
    Printf.sprintf "handoff:%s:%s:%s" from_agent to_agent reason
  | Telemetry_eio.Error_occurred { code; message; context } ->
    Printf.sprintf "error:%s:%s:%s" code message context
  | Telemetry_eio.Tool_called
      { tool_name; success; duration_ms; agent_id; source; _ } ->
    Printf.sprintf
      "tool_called:%s:%b:%d:%s:%s"
      tool_name
      success
      duration_ms
      (Option.value agent_id ~default:"")
      (Option.value source ~default:"")
  | Telemetry_eio.Tool_assigned { agent_id; profile; preset; tool_count; assignment_id } ->
    Printf.sprintf
      "tool_assigned:%s:%s:%s:%d:%s"
      agent_id
      profile
      (Option.value preset ~default:"")
      tool_count
      assignment_id
;;

let compare_telemetry_activity left right =
  compare_desc_float_then_string
    ~float_value:(fun (record : Telemetry_eio.event_record) -> record.timestamp)
    ~string_value:(fun record -> telemetry_event_sort_key record.event)
    left
    right
;;

let canonicalize_observed_state state =
  { state with
    goals = List.sort compare_goal_id state.goals
  ; tasks = List.sort compare_task_id state.tasks
  ; posts = List.sort compare_post_activity state.posts
  ; transactions = List.sort compare_transaction_activity state.transactions
  ; telemetry_events = List.sort compare_telemetry_activity state.telemetry_events
  }
;;

let take n values =
  let rec loop remaining acc = function
    | _ when remaining <= 0 -> List.rev acc
    | [] -> List.rev acc
    | value :: rest -> loop (remaining - 1) (value :: acc) rest
  in
  loop n [] values
;;

let truncate ?(limit = 160) value =
  let value = String.trim value in
  if String.length value <= limit then value else String.sub value 0 limit ^ "..."
;;

let single_unique = function
  | [ value ] -> Some value
  | [] | _ :: _ :: _ -> None
;;

let task_actor_name (task : Masc_domain.task) =
  match task.task_status with
  | Masc_domain.Todo -> task.created_by
  | Masc_domain.Claimed { assignee; _ }
  | Masc_domain.InProgress { assignee; _ }
  | Masc_domain.AwaitingVerification { assignee; _ }
  | Masc_domain.Done { assignee; _ } ->
    Some assignee
  | Masc_domain.Cancelled { cancelled_by; _ } -> Some cancelled_by
;;

let earning_kind = function
  | Agent_economy.Earn_task_done
  | Agent_economy.Earn_board_post
  | Agent_economy.Earn_upvote
  | Agent_economy.Earn_mention_response ->
    true
  | Agent_economy.Spend_model_call
  | Agent_economy.Spend_deliberation
  | Agent_economy.Adjustment ->
    false
;;

let spend_kind = function
  | Agent_economy.Spend_model_call | Agent_economy.Spend_deliberation -> true
  | Agent_economy.Earn_task_done
  | Agent_economy.Earn_board_post
  | Agent_economy.Earn_upvote
  | Agent_economy.Earn_mention_response
  | Agent_economy.Adjustment ->
    false
;;

let transaction_kind_to_evidence_kind = function
  | Agent_economy.Earn_task_done ->
    Coordination_product.Evidence_economy_earn_task_done
  | Agent_economy.Earn_board_post ->
    Coordination_product.Evidence_economy_earn_board_post
  | Agent_economy.Earn_upvote -> Coordination_product.Evidence_economy_earn_upvote
  | Agent_economy.Earn_mention_response ->
    Coordination_product.Evidence_economy_earn_mention_response
  | Agent_economy.Spend_model_call ->
    Coordination_product.Evidence_economy_spend_model_call
  | Agent_economy.Spend_deliberation ->
    Coordination_product.Evidence_economy_spend_deliberation
  | Agent_economy.Adjustment -> Coordination_product.Evidence_economy_adjustment
;;

let json_links_any (ids : Coordination_product.ids) json =
  let matches_one key values =
    match assoc_string_opt key json with
    | Some value -> List.mem value values
    | None -> false
  in
  let matches_many key values =
    assoc_string_list key json |> List.exists (fun value -> List.mem value values)
  in
  (match ids.goal_id with
   | Some goal_id -> matches_one Coordination_product.Ref_key.goal_id [ goal_id ]
   | None -> false)
  || matches_one Coordination_product.Ref_key.task_id ids.task_ids
  || matches_many Coordination_product.Ref_key.task_ids ids.task_ids
  || matches_one Coordination_product.Ref_key.post_id ids.post_ids
  || matches_many Coordination_product.Ref_key.post_ids ids.post_ids
;;

let transaction_links_any ids (txn : Agent_economy.transaction) =
  json_links_any ids txn.metadata
;;

let economy_transactions_for ids transactions =
  transactions
  |> List.filter (fun (txn : Agent_economy.transaction) ->
    transaction_links_any ids txn
    ||
    match ids.agent_name with
    | Some agent_name -> String.equal txn.agent_name agent_name && spend_kind txn.kind
    | None -> false)
  |> List.sort compare_transaction_activity
;;

let reward_facts ~(ids : Coordination_product.ids) transactions =
  let relevant_transactions = economy_transactions_for ids transactions in
  let has_reward_earning =
    List.exists
      (fun (txn : Agent_economy.transaction) -> earning_kind txn.kind)
      relevant_transactions
  in
  let has_penalty =
    List.exists
      (fun (txn : Agent_economy.transaction) ->
        txn.kind = Agent_economy.Adjustment && txn.amount < 0.0)
      relevant_transactions
  in
  let has_spend =
    match ids.agent_name with
    | None -> false
    | Some agent_name ->
      List.exists
        (fun (txn : Agent_economy.transaction) ->
          String.equal txn.agent_name agent_name && spend_kind txn.kind)
        transactions
  in
  has_reward_earning, has_spend, has_penalty
;;

let task_evidence (ids : Coordination_product.ids) (task : Masc_domain.task)
  : Coordination_product.evidence
  =
  { source = Coordination_product.Source_task_store
  ; kind = Coordination_product.Evidence_task_status
  ; id = Some task.id
  ; label = truncate ~limit:80 task.title
  ; detail =
      Printf.sprintf
        "status=%s; priority=%d; created_by=%s"
        (Masc_domain.task_status_to_string task.task_status)
        task.priority
        (Option.value task.created_by ~default:"-")
  ; timestamp = Masc_domain.parse_iso8601_opt task.created_at
  ; refs = { ids with task_ids = unique_strings (task.id :: ids.task_ids) }
  }
;;

let goal_evidence (ids : Coordination_product.ids) (goal : Goal_store.goal)
  : Coordination_product.evidence
  =
  { source = Coordination_product.Source_goal_store
  ; kind = Coordination_product.Evidence_goal_phase
  ; id = Some goal.id
  ; label = truncate ~limit:80 goal.title
  ; detail =
      Printf.sprintf
        "phase=%s; priority=%d; active_verification=%s"
        (Goal_phase.to_string goal.phase)
        goal.priority
        (Option.value goal.active_verification_request_id ~default:"-")
  ; timestamp = Masc_domain.parse_iso8601_opt goal.updated_at
  ; refs = { ids with goal_id = Some goal.id }
  }
;;

let board_evidence (ids : Coordination_product.ids) (post : Board.post)
  : Coordination_product.evidence
  =
  let body = if String.trim post.content <> "" then post.content else post.body in
  { source = Coordination_product.Source_board
  ; kind = Coordination_product.Evidence_board_post
  ; id = Some (post_id_string post)
  ; label = truncate ~limit:80 post.title
  ; detail =
      Printf.sprintf
        "author=%s; replies=%d; %s"
        (Board.Agent_id.to_string post.author)
        post.reply_count
        (truncate ~limit:120 body)
  ; timestamp = Some post.updated_at
  ; refs = { ids with post_ids = unique_strings (post_id_string post :: ids.post_ids) }
  }
;;

let economy_evidence (ids : Coordination_product.ids) (txn : Agent_economy.transaction)
  : Coordination_product.evidence
  =
  let kind = transaction_kind_to_evidence_kind txn.kind in
  { source = Coordination_product.Source_economy
  ; kind
  ; id = Some txn.id
  ; label =
      Printf.sprintf "%s %.2f" (Coordination_product.evidence_kind_to_string kind) txn.amount
  ; detail =
      Printf.sprintf
        "agent=%s; balance_after=%.2f; reason=%s"
        txn.agent_name
        txn.balance_after
        (truncate ~limit:120 txn.reason)
  ; timestamp = Some txn.timestamp
  ; refs = ids
  }
;;

let telemetry_evidence_for_event
      (ids : Coordination_product.ids)
      (record : Telemetry_eio.event_record)
  : Coordination_product.evidence option
  =
  match record.event with
  | Telemetry_eio.Task_started { task_id; agent_id } when List.mem task_id ids.task_ids
    ->
    Some
      { source = Coordination_product.Source_telemetry
      ; kind = Coordination_product.Evidence_telemetry_task_started
      ; id = Some task_id
      ; label = "task started"
      ; detail = Printf.sprintf "agent=%s" agent_id
      ; timestamp = Some record.timestamp
      ; refs = { ids with task_ids = unique_strings (task_id :: ids.task_ids) }
      }
  | Telemetry_eio.Task_completed { task_id; duration_ms; success }
    when List.mem task_id ids.task_ids ->
    Some
      { source = Coordination_product.Source_telemetry
      ; kind = Coordination_product.Evidence_telemetry_task_completed
      ; id = Some task_id
      ; label = "task completed"
      ; detail = Printf.sprintf "success=%b; duration_ms=%d" success duration_ms
      ; timestamp = Some record.timestamp
      ; refs = { ids with task_ids = unique_strings (task_id :: ids.task_ids) }
      }
  | Telemetry_eio.Tool_called
      { tool_name; success; duration_ms; agent_id = Some agent_id; source }
    when Option.equal String.equal ids.agent_name (Some agent_id) ->
    Some
      { source = Coordination_product.Source_telemetry
      ; kind = Coordination_product.Evidence_telemetry_tool_called
      ; id = Some tool_name
      ; label = tool_name
      ; detail =
          Printf.sprintf
            "agent=%s; success=%b; duration_ms=%d; source=%s"
            agent_id
            success
            duration_ms
            (Option.value source ~default:"-")
      ; timestamp = Some record.timestamp
      ; refs = ids
      }
  | Telemetry_eio.Agent_joined _ | Telemetry_eio.Agent_left _
  | Telemetry_eio.Task_started _ | Telemetry_eio.Task_completed _
  | Telemetry_eio.Handoff_triggered _ | Telemetry_eio.Error_occurred _
  | Telemetry_eio.Tool_called _ | Telemetry_eio.Tool_assigned _ ->
    None
;;

let evidence_for ~ids ~tasks ~linked_posts ~transactions ~telemetry_events =
  let task_rows = tasks |> List.map (task_evidence ids) |> take 5 in
  let board_rows =
    linked_posts
    |> List.sort compare_post_activity
    |> List.map (board_evidence ids)
    |> take 5
  in
  let economy_rows =
    economy_transactions_for ids transactions |> List.map (economy_evidence ids) |> take 5
  in
  let telemetry_rows =
    telemetry_events
    |> List.sort compare_telemetry_activity
    |> List.filter_map (telemetry_evidence_for_event ids)
    |> take 5
  in
  task_rows @ board_rows @ economy_rows @ telemetry_rows
;;

let post_links_ids (ids : Coordination_product.ids) (post : Board.post) =
  let post_goal =
    match ids.goal_id with
    | Some goal_id -> meta_string Coordination_product.Ref_key.goal_id post = Some goal_id
    | None -> false
  in
  let post_task =
    match meta_string Coordination_product.Ref_key.task_id post with
    | Some task_id -> List.mem task_id ids.task_ids
    | None -> false
  in
  let post_tasks =
    meta_string_list Coordination_product.Ref_key.task_ids post
    |> List.exists (fun task_id -> List.mem task_id ids.task_ids)
  in
  post_goal || post_task || post_tasks
;;

let goal_terminal = function
  | Goal_phase.Completed | Goal_phase.Dropped -> true
  | Goal_phase.Executing
  | Goal_phase.Awaiting_verification
  | Goal_phase.Awaiting_approval
  | Goal_phase.Blocked
  | Goal_phase.Paused ->
    false
;;

let board_phase_for
      ~persist_errors
      ~goal_phase
      ~(task_counts : Coordination_product.task_counts)
      ~linked_posts
  =
  if persist_errors > 0
  then Coordination_product.Degraded
  else (
    match linked_posts with
    | [] -> Coordination_product.Quiet
    | _
      when (match goal_phase with
            | Some phase -> goal_terminal phase
            | None -> false) -> Coordination_product.Signal_acknowledged
    | _ when task_counts.total > 0 && task_counts.open_count = 0 ->
      Coordination_product.Signal_acknowledged
    | _ -> Coordination_product.Signal_pending)
;;

let product_for
      ~goal_phase
      ~goal_id
      ~tasks
      ~posts
      ~transactions
      ~telemetry_events
      ~persist_errors
      ~economy_enabled
  =
  let task_statuses = List.map (fun (task : Masc_domain.task) -> task.task_status) tasks in
  let task_counts = Coordination_product.task_counts_of_statuses task_statuses in
  let task = Coordination_product.task_phase_of_counts task_statuses in
  let task_ids = List.map (fun (task : Masc_domain.task) -> task.id) tasks in
  let agent_name =
    tasks |> List.filter_map task_actor_name |> unique_strings |> single_unique
  in
  let ids : Coordination_product.ids =
    { goal_id; task_ids; post_ids = []; agent_name }
  in
  let linked_posts = List.filter (post_links_ids ids) posts in
  let ids = { ids with post_ids = List.map post_id_string linked_posts } in
  let board = board_phase_for ~persist_errors ~goal_phase ~task_counts ~linked_posts in
  let has_reward_earning, has_spend, has_penalty =
    reward_facts ~ids transactions
  in
  let reward =
    Coordination_product.reward_phase_of_facts
      ~economy_enabled
      ~task_counts
      ~board
      ~has_reward_earning
      ~has_spend
      ~has_penalty
  in
  let facts : Coordination_product.facts =
    { economy_enabled
    ; has_reward_earning
    ; has_spend
    ; has_penalty
    ; board_signal_count = List.length linked_posts
    ; board_persist_error_count = persist_errors
    ; active_goal_verification = false
    }
  in
  let evidence =
    evidence_for ~ids ~tasks ~linked_posts ~transactions ~telemetry_events
  in
  let product : Coordination_product.product =
    { ids; goal = goal_phase; task; board; reward; task_counts; facts; evidence }
  in
  product
;;

let product_for_goal
      ~all_tasks
      ~posts
      ~transactions
      ~telemetry_events
      ~persist_errors
      ~economy_enabled
    (goal : Goal_store.goal)
  =
  let tasks =
    all_tasks |> List.filter (Convergence.task_has_goal_id ~goal_id:goal.id)
  in
  let product =
    product_for
      ~goal_phase:(Some goal.phase)
      ~goal_id:(Some goal.id)
      ~tasks
      ~posts
      ~transactions
      ~telemetry_events
      ~persist_errors
      ~economy_enabled
  in
  { product with
    facts =
      { product.facts with
        active_goal_verification = Option.is_some goal.active_verification_request_id
      }
  ; evidence = goal_evidence product.ids goal :: product.evidence
  }
;;

let read_recent_telemetry config =
  try
    let since = Time_compat.now () -. (7.0 *. Masc_time_constants.day) in
    Telemetry_eio.read_events_since config ~since
  with
  | exn ->
    Log.Coord.warn
      "coordination product telemetry evidence failed: %s"
      (Printexc.to_string exn);
    []
;;

let capture (config : Coord.config) =
  { goals = Goal_store.list_goals config ()
  ; tasks = Coord_query.get_tasks_safe config
  ; posts = Board_dispatch.list_posts ~limit:Board.Limits.max_posts ()
  ; transactions = Agent_economy.list_transactions ~base_path:config.base_path
  ; telemetry_events = read_recent_telemetry config
  ; persist_errors = Board.persist_error_count ()
  ; economy_enabled = Agent_economy.enabled ()
  }
;;

let project state =
  let state = canonicalize_observed_state state in
  let all_tasks = state.tasks in
  let goal_products =
    List.map
      (product_for_goal
         ~all_tasks
         ~posts:state.posts
         ~transactions:state.transactions
         ~telemetry_events:state.telemetry_events
         ~persist_errors:state.persist_errors
         ~economy_enabled:state.economy_enabled)
      state.goals
  in
  let linked_task_ids =
    goal_products
    |> List.concat_map (fun (product : Coordination_product.product) ->
      product.ids.task_ids)
    |> unique_strings
  in
  let unlinked_task_products =
    all_tasks
    |> List.filter (fun (task : Masc_domain.task) -> not (List.mem task.id linked_task_ids))
    |> List.map (fun task ->
      product_for
        ~goal_phase:None
        ~goal_id:None
        ~tasks:[ task ]
        ~posts:state.posts
        ~transactions:state.transactions
        ~telemetry_events:state.telemetry_events
        ~persist_errors:state.persist_errors
        ~economy_enabled:state.economy_enabled)
  in
  let snapshot = Coordination_product.snapshot (goal_products @ unlinked_task_products) in
  { snapshot with
    violations =
      snapshot.violations @ Coordination_product.observation_driven_violations all_tasks
  }
;;

let build config = config |> capture |> project

let severity_counts (snapshot : Coordination_product.snapshot) =
  let count severity =
    snapshot.violations
    |> List.filter (fun (violation : Coordination_product.violation) ->
      violation.severity = severity)
    |> List.length
  in
  { info = count Coordination_product.Info
  ; warn = count Coordination_product.Warn
  ; error = count Coordination_product.Error
  }
;;

let to_yojson snapshot = Coordination_product.snapshot_to_yojson snapshot
let build_yojson config = build config |> to_yojson

let safe_build_yojson config =
  try build_yojson config with
  | exn ->
    let message = Printexc.to_string exn in
    Log.Coord.warn "coordination product snapshot failed: %s" message;
    Coordination_product.snapshot_to_yojson
      ~projection_error:message
      (Coordination_product.snapshot [])
;;
