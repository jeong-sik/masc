type waiting_source =
  | Event_queue_pending
  | Event_queue_inflight
  | Chat_queue_pending
  | Hitl_pending
  | External_attention
  | Fusion_running
  | Background_task
  | Schedule_waiting
  | Turn_admission_waiting
  | Operator_pending_confirm
  | Read_error

type keeper_state =
  | Idle
  | Busy
  | Waiting
  | Deferred

type wake_producer =
  | Board_dispatch
  | Keeper_chat_queue_store
  | Keeper_supervisor
  | Keeper_no_progress_recovery
  | Fusion_sink
  | Bg_task_completion
  | Connector_attention_hook
  | Hitl_resolution_hook
  | External_attention_store
  | Schedule_store
  | Schedule_runner
  | Keeper_turn_admission
  | Operator_pending_confirm_store
  | Goal_verification_store
  | Read_model_reader

type waiting_row =
  { keeper_name : string option
  ; source : waiting_source
  ; waiting_on : string
  ; wake_producer : wake_producer
  ; since : float option
  ; due_at : float option
  ; next_action : string
  ; detail : Yojson.Safe.t
  }

let external_attention_dashboard_row_limit = 64

let source_to_string = function
  | Event_queue_pending -> "event_queue_pending"
  | Event_queue_inflight -> "event_queue_inflight"
  | Chat_queue_pending -> "chat_queue_pending"
  | Hitl_pending -> "hitl_pending"
  | External_attention -> "external_attention"
  | Fusion_running -> "fusion_running"
  | Background_task -> "background_task"
  | Schedule_waiting -> "schedule_waiting"
  | Turn_admission_waiting -> "turn_admission_waiting"
  | Operator_pending_confirm -> "operator_pending_confirm"
  | Read_error -> "read_error"
;;

let all_waiting_sources =
  [ Event_queue_pending
  ; Event_queue_inflight
  ; Chat_queue_pending
  ; Hitl_pending
  ; External_attention
  ; Fusion_running
  ; Background_task
  ; Schedule_waiting
  ; Turn_admission_waiting
  ; Operator_pending_confirm
  ; Read_error
  ]
;;

let keeper_state_to_string = function
  | Idle -> "idle"
  | Busy -> "busy"
  | Waiting -> "waiting"
  | Deferred -> "deferred"
;;

let all_keeper_states = [ Idle; Busy; Waiting; Deferred ]

let wake_producer_to_string = function
  | Board_dispatch -> "board_dispatch"
  | Keeper_chat_queue_store -> "keeper_chat_queue_store"
  | Keeper_supervisor -> "keeper_supervisor"
  | Keeper_no_progress_recovery -> "keeper_no_progress_recovery"
  | Fusion_sink -> "fusion_sink"
  | Bg_task_completion -> "bg_task_completion"
  | Connector_attention_hook -> "connector_attention_hook"
  | Hitl_resolution_hook -> "hitl_resolution_hook"
  | External_attention_store -> "external_attention_store"
  | Schedule_store -> "schedule_store"
  | Schedule_runner -> "schedule_runner"
  | Keeper_turn_admission -> "keeper_turn_admission"
  | Operator_pending_confirm_store -> "operator_pending_confirm_store"
  | Goal_verification_store -> "goal_verification_store"
  | Read_model_reader -> "read_model_reader"
;;

let wake_producer_of_payload : Keeper_event_queue.stimulus_payload -> wake_producer =
  function
  | Board_signal _ -> Board_dispatch
  | Bootstrap -> Keeper_supervisor
  | No_progress_recovery -> Keeper_no_progress_recovery
  | Fusion_completed _ -> Fusion_sink
  | Bg_completed _ -> Bg_task_completion
  | Schedule_due _ -> Schedule_runner
  | Connector_attention _ -> Connector_attention_hook
  | Hitl_resolved _ -> Hitl_resolution_hook
  | Goal_verification_failed _ -> Goal_verification_store
;;

let unix_iso_json = function
  | None -> `Null
  | Some ts -> `String (Masc_domain.iso8601_of_unix_seconds ts)
;;

let float_json = function
  | None -> `Null
  | Some value -> `Float value
;;

let waiting_row_json (row : waiting_row) =
  `Assoc
    [ "keeper_name", Json_util.string_opt_to_json row.keeper_name
    ; "source", `String (source_to_string row.source)
    ; "waiting_on", `String row.waiting_on
    ; "wake_producer", `String (wake_producer_to_string row.wake_producer)
    ; "since", float_json row.since
    ; "since_iso", unix_iso_json row.since
    ; "due_at", float_json row.due_at
    ; "due_at_iso", unix_iso_json row.due_at
    ; "next_action", `String row.next_action
    ; "detail", row.detail
    ]
;;

let take_with_truncation limit rows =
  let limit = max 0 limit in
  let rec loop remaining acc = function
    | rest when remaining <= 0 -> List.rev acc, rest <> []
    | [] -> List.rev acc, false
    | row :: rest -> loop (remaining - 1) (row :: acc) rest
  in
  loop limit [] rows
;;

let rows_for_queue_snapshot ~keeper_name ~source ~next_action queue =
  Keeper_event_queue.to_list queue
  |> List.map (fun (stimulus : Keeper_event_queue.stimulus) ->
    { keeper_name = Some keeper_name
    ; source
    ; waiting_on = Keeper_event_queue.payload_kind_label stimulus.payload
    ; wake_producer = wake_producer_of_payload stimulus.payload
    ; since = Some stimulus.arrived_at
    ; due_at = None
    ; next_action
    ; detail = Keeper_event_queue.stimulus_to_yojson stimulus
    })
;;

let read_queue_rows ~base_path ~keeper_name load ~source ~next_action =
  match load ~base_path ~keeper_name with
  | Ok queue -> rows_for_queue_snapshot ~keeper_name ~source ~next_action queue
  | Error err ->
    [ { keeper_name = Some keeper_name
      ; source = Read_error
      ; waiting_on = source_to_string source
      ; wake_producer = Read_model_reader
      ; since = None
      ; due_at = None
      ; next_action = "inspect_queue_snapshot"
      ; detail = `Assoc [ "error", `String err ]
      }
    ]
;;

let read_error_row ?keeper_name ~waiting_on ~next_action detail =
  { keeper_name
  ; source = Read_error
  ; waiting_on
  ; wake_producer = Read_model_reader
  ; since = None
  ; due_at = None
  ; next_action
  ; detail
  }
;;

let schedule_read_error_detail = function
  | Schedule_store.Corrupt_read_ledger { primary_err; recovery_err } ->
    `Assoc
      [ "primary_err", `String primary_err
      ; "recovery_err", Json_util.string_opt_to_json recovery_err
      ]
;;

let chat_queue_source_label = function
  | Keeper_chat_queue.Dashboard -> "dashboard"
  | Keeper_chat_queue.Discord _ -> "discord"
  | Keeper_chat_queue.Slack _ -> "slack"
;;

let chat_queue_source_json = function
  | Keeper_chat_queue.Dashboard -> `Assoc [ "kind", `String "dashboard" ]
  | Keeper_chat_queue.Discord { channel_id; user_id } ->
    `Assoc
      [ "kind", `String "discord"
      ; "channel_id", `String channel_id
      ; "user_id", `String user_id
      ]
  | Keeper_chat_queue.Slack { channel; user_id } ->
    `Assoc
      [ "kind", `String "slack"
      ; "channel", `String channel
      ; "user_id", `String user_id
      ]
;;

let chat_queue_rows keeper_name =
  Keeper_chat_queue.snapshot ~keeper_name
  |> List.mapi (fun queue_index (msg : Keeper_chat_queue.queued_message) ->
    let source_label = chat_queue_source_label msg.source in
    { keeper_name = Some keeper_name
    ; source = Chat_queue_pending
    ; waiting_on = source_label
    ; wake_producer = Keeper_chat_queue_store
    ; since = Some msg.timestamp
    ; due_at = None
    ; next_action = "keeper_chat_consumer_drain"
    ; detail =
        `Assoc
          [ "queue_index", `Int queue_index
          ; "message_source", chat_queue_source_json msg.source
          ; "content_length", `Int (String.length msg.content)
          ; "user_block_count", `Int (List.length msg.user_blocks)
          ; "attachment_count", `Int (List.length msg.attachments)
          ]
    })
;;

let turn_admission_rows ~base_path keeper_name =
  if not (Keeper_turn_admission.chat_waiting ~base_path ~keeper_name)
  then []
  else
    let in_flight = Keeper_turn_admission.in_flight ~base_path ~keeper_name in
    let waiting_since =
      Keeper_turn_admission.chat_waiting_since ~base_path ~keeper_name
    in
    let in_flight_detail =
      match in_flight with
      | None -> `Null
      | Some (info : Keeper_turn_admission.in_flight_info) ->
        `Assoc
          [ "lane", `String (Keeper_turn_admission.lane_to_string info.lane)
          ; "started_at", `Float info.started_at
          ; "started_at_iso", unix_iso_json (Some info.started_at)
          ]
    in
    [ { keeper_name = Some keeper_name
      ; source = Turn_admission_waiting
      ; waiting_on = "chat"
      ; wake_producer = Keeper_turn_admission
      ; since = waiting_since
      ; due_at = None
      ; next_action = "turn_slot_release"
      ; detail =
          `Assoc
            [ "waiting_lane", `String "chat"
            ; "waiting_since", float_json waiting_since
            ; "waiting_since_iso", unix_iso_json waiting_since
            ; "in_flight", in_flight_detail
            ]
      }
    ]
;;

let hitl_rows keeper_name pending =
  pending
  |> List.filter (fun (entry : Keeper_approval_queue.pending_approval) ->
    String.equal entry.keeper_name keeper_name)
  |> List.map (fun (entry : Keeper_approval_queue.pending_approval) ->
    { keeper_name = Some keeper_name
    ; source = Hitl_pending
    ; waiting_on = entry.tool_name
    ; wake_producer = Hitl_resolution_hook
    ; since = Some entry.requested_at
    ; due_at = None
    ; next_action = "operator_resolve_hitl"
    ; detail =
        `Assoc
          [ "approval_id", `String entry.id
          ; "tool_name", `String entry.tool_name
          ; "risk_level", `String (Keeper_approval_queue.risk_level_to_string entry.risk_level)
          ; "phase", `String (Keeper_approval_queue.pending_phase_to_string entry.phase)
          ; "turn_id", Json_util.int_opt_to_json entry.turn_id
          ; "task_id", Json_util.string_opt_to_json entry.task_id
          ; "goal_id", Json_util.string_opt_to_json entry.goal_id
          ; "goal_ids", `List (List.map (fun id -> `String id) entry.goal_ids)
          ]
    })
;;

let external_attention_rows ~base_path ~keeper_name =
  match
    Keeper_external_attention.pending_for_keeper_result ~base_path ~keeper_name
      ~limit:(external_attention_dashboard_row_limit + 1) ()
  with
  | Error err ->
    ( [ read_error_row
          ~keeper_name:(Some keeper_name)
          ~waiting_on:"external_attention_store"
          ~next_action:"repair_external_attention_store"
          (`Assoc [ "error", `String err ])
      ]
    , false )
  | Ok pending ->
    let pending, truncated =
      take_with_truncation external_attention_dashboard_row_limit pending
    in
    ( pending
      |> List.map (fun (item : Keeper_external_attention.item) ->
        { keeper_name = Some keeper_name
        ; source = External_attention
        ; waiting_on = item.source_label
        ; wake_producer = External_attention_store
        ; since = Some item.received_at
        ; due_at = None
        ; next_action = "keeper_process_external_attention"
        ; detail =
            `Assoc
              [ "event_id", `String item.event_id
              ; "urgency", `String (Keeper_external_attention.urgency_to_string item.urgency)
              ; "conversation_id", `String item.conversation.conversation_id
              ; "content_preview", `String item.content_preview
              ; "surface", Keeper_external_attention.surface_ref_to_json item.conversation.surface
              ]
        })
    , truncated )
;;

let fusion_rows keeper_name runs =
  runs
  |> List.filter_map (fun (run : Fusion_run_registry.run) ->
    if not (String.equal run.keeper keeper_name)
    then None
    else
      match run.status with
      | Fusion_run_registry.Running ->
        Some
          { keeper_name = Some keeper_name
          ; source = Fusion_running
          ; waiting_on = run.run_id
          ; wake_producer = Fusion_sink
          ; since = Some run.started_at
          ; due_at = None
          ; next_action = "await_fusion_completion"
          ; detail =
              `Assoc
                [ "run_id", `String run.run_id
                ; "preset", `String run.preset
                ; "status", `String (Fusion_run_registry.status_label run.status)
                ]
          }
      | Completed _ -> None)
;;

let background_task_rows keeper_name =
  Bg_task.list_with_started_at ~keeper:keeper_name
  |> List.map (fun (task_id, started_at) ->
    let task_id = Bg_task.task_id_to_string task_id in
    { keeper_name = Some keeper_name
    ; source = Background_task
    ; waiting_on = task_id
    ; wake_producer = Bg_task_completion
    ; since = Some started_at
    ; due_at = None
    ; next_action = "poll_background_task"
    ; detail = `Assoc [ "task_id", `String task_id ]
    })
;;

let pending_confirm_rows keeper_names pending_confirms =
  pending_confirms
  |> List.filter_map (fun (entry : Operator_pending_confirm.pending_confirm) ->
    match entry.target_id with
    | Some keeper_name when List.exists (String.equal keeper_name) keeper_names ->
      Some
        { keeper_name = Some keeper_name
        ; source = Operator_pending_confirm
        ; waiting_on = entry.action_type
        ; wake_producer = Operator_pending_confirm_store
        ; since = None
        ; due_at = None
        ; next_action = "operator_confirm_action"
        ; detail =
            `Assoc
              [ "token", `String entry.token
              ; "trace_id", `String entry.trace_id
              ; "actor", `String entry.actor
              ; "target_type", `String entry.target_type
              ; "target_id", Json_util.string_opt_to_json entry.target_id
              ; "delegated_tool", `String entry.delegated_tool
              ; "created_at", `String entry.created_at
              ; "expires_at", Json_util.string_opt_to_json entry.expires_at
              ]
        }
    | None | Some _ -> None)
;;

let schedule_active (request : Schedule_domain.schedule_request) =
  not (Schedule_domain.is_terminal request.status)
;;

let schedule_next_action (request : Schedule_domain.schedule_request) =
  match request.status with
  | Pending_approval -> "operator_grant_schedule"
  | Scheduled -> "wait_until_due"
  | Due -> "schedule_runner_dispatch"
  | Running -> "await_schedule_completion"
  | Succeeded | Failed | Rejected | Cancelled | Expired -> "none"
;;

let schedule_waiting_on (request : Schedule_domain.schedule_request) =
  match Schedule_payload_projection.kind request with
  | Some kind -> kind
  | None -> request.schedule_id
;;

let schedule_keeper_owner keeper_names (request : Schedule_domain.schedule_request) =
  match request.scheduled_by.kind with
  | Human_operator -> None
  | Automated_actor ->
    let keeper_name = request.scheduled_by.id in
    if List.exists (String.equal keeper_name) keeper_names then Some keeper_name else None
;;

let schedule_rows ~keeper_names state =
  state.Schedule_store.schedules
  |> List.filter schedule_active
  |> List.map (fun (request : Schedule_domain.schedule_request) ->
    { keeper_name = schedule_keeper_owner keeper_names request
    ; source = Schedule_waiting
    ; waiting_on = schedule_waiting_on request
    ; wake_producer =
        (match request.status with
         | Scheduled | Due | Running -> Schedule_runner
         | Pending_approval -> Schedule_store
         | Succeeded | Failed | Rejected | Cancelled | Expired -> Schedule_store)
    ; since = Some request.requested_at
    ; due_at = Some request.due_at
    ; next_action = schedule_next_action request
    ; detail =
        `Assoc
          [ "schedule_id", `String request.schedule_id
          ; "status", `String (Schedule_domain.schedule_status_to_string request.status)
          ; "risk_class", `String (Schedule_domain.risk_class_to_string request.risk_class)
          ; "payload_digest", `String (Schedule_domain.payload_digest request.payload)
          ; ( "payload_kind"
            , match Schedule_payload_projection.kind request with
              | None -> `Null
              | Some kind -> `String kind )
          ]
    })
;;

let schedule_rows_or_error config ~keeper_names =
  match Schedule_store.read_state_result config with
  | Ok state -> schedule_rows ~keeper_names state
  | Error err ->
    [ read_error_row
        ~waiting_on:"schedule_store"
        ~next_action:"repair_schedule_ledger"
        (schedule_read_error_detail err)
    ]
;;

let pending_confirms_or_error_rows config =
  match Operator_pending_confirm.read_pending_confirms_result config with
  | Ok pending_confirms -> pending_confirms, []
  | Error err ->
    ( []
    , [ read_error_row
          ~waiting_on:"operator_pending_confirm_store"
          ~next_action:"repair_operator_pending_confirms"
          (`Assoc [ "error", `String err ])
      ] )
;;

let keeper_names_or_error_rows config =
  match Keeper_meta_store.keeper_names_result config with
  | Ok keeper_names -> keeper_names, []
  | Error err ->
    ( []
    , [ read_error_row
          ~waiting_on:"keeper_meta_store"
          ~next_action:"repair_keeper_meta_store"
          (`Assoc [ "error", `String err ])
      ] )
;;

let row_state rows =
  if List.exists (fun row -> row.source = Fusion_running || row.source = Background_task) rows
  then Deferred
  else if rows <> []
  then Waiting
  else Idle
;;

let keeper_state ~busy rows =
  if busy then Busy else row_state rows
;;

let source_counts rows =
  let bump source counts =
    let key = source_to_string source in
    let rec loop acc = function
      | [] -> List.rev ((key, 1) :: acc)
      | (existing, count) :: rest when String.equal existing key ->
        List.rev_append acc ((existing, count + 1) :: rest)
      | item :: rest -> loop (item :: acc) rest
    in
    loop [] counts
  in
  rows
  |> List.fold_left (fun counts row -> bump row.source counts) []
  |> List.sort (fun (left, _) (right, _) -> String.compare left right)
  |> List.map (fun (source, count) -> source, `Int count)
;;

let global_pending_confirm_count keeper_names pending_confirms =
  pending_confirms
  |> List.fold_left
       (fun count (entry : Operator_pending_confirm.pending_confirm) ->
          match entry.target_id with
          | Some keeper_name when List.exists (String.equal keeper_name) keeper_names -> count
          | None | Some _ -> count + 1)
       0
;;

let busy_keeper_names ~base_path =
  Keeper_registry.all ~base_path ()
  |> List.filter_map (fun (entry : Keeper_registry.registry_entry) ->
    match entry.current_turn_observation with
    | Some _ -> Some entry.name
    | None -> None)
;;

let keeper_is_busy busy_names keeper_name =
  List.exists (String.equal keeper_name) busy_names
;;

let count_rows_for_source source rows =
  rows
  |> List.fold_left
       (fun count row -> if row.source = source then count + 1 else count)
       0
;;

let oldest_age_seconds_for_source ~now source rows =
  rows
  |> List.fold_left
       (fun oldest row ->
          if row.source <> source
          then oldest
          else
            match row.since with
            | None -> oldest
            | Some since -> max oldest (max 0.0 (now -. since)))
       0.0
;;

let metric_scope_labels ~scope source =
  [ "scope", scope; "source", source_to_string source ]
;;

let record_scope_metrics ~now ~scope rows =
  List.iter
    (fun source ->
       Otel_metric_store.set_gauge
         Otel_metric_store.metric_keeper_waiting_count
         ~labels:(metric_scope_labels ~scope source)
         (Float.of_int (count_rows_for_source source rows));
       Otel_metric_store.set_gauge
         Otel_metric_store.metric_keeper_waiting_age_seconds
         ~labels:(metric_scope_labels ~scope source)
         (oldest_age_seconds_for_source ~now source rows))
    all_waiting_sources
;;

let record_keeper_state_metrics per_keeper =
  List.iter
    (fun state ->
       let count =
         per_keeper
         |> List.fold_left
              (fun total (_keeper_name, busy, rows, _external_attention_truncated) ->
                 if keeper_state ~busy rows = state then total + 1 else total)
              0
       in
       Otel_metric_store.set_gauge
         Otel_metric_store.metric_keeper_waiting_keeper_count
         ~labels:[ "state", keeper_state_to_string state ]
         (Float.of_int count))
    all_keeper_states
;;

let record_metrics ~now ~per_keeper ~global_rows =
  let all_keeper_rows =
    List.flatten
      (List.map
         (fun (_keeper_name, _busy, rows, _external_attention_truncated) -> rows)
         per_keeper)
  in
  record_scope_metrics ~now ~scope:"keeper" all_keeper_rows;
  record_scope_metrics ~now ~scope:"global" global_rows;
  record_keeper_state_metrics per_keeper
;;

let keeper_json keeper_name ~busy ~external_attention_truncated rows =
  let state = keeper_state ~busy rows in
  let since =
    rows
    |> List.filter_map (fun row -> row.since)
    |> List.fold_left (fun acc ts -> match acc with None -> Some ts | Some cur -> Some (min cur ts)) None
  in
  let due_at =
    rows
    |> List.filter_map (fun row -> row.due_at)
    |> List.fold_left (fun acc ts -> match acc with None -> Some ts | Some cur -> Some (min cur ts)) None
  in
  `Assoc
    [ "keeper_name", `String keeper_name
    ; "state", `String (keeper_state_to_string state)
    ; "waiting_on", `List (List.map waiting_row_json rows)
    ; "waiting_count", `Int (List.length rows)
    ; "waiting_count_truncated", `Bool external_attention_truncated
    ; ( "truncated_sources"
      , `Assoc
          (if external_attention_truncated
           then [ "external_attention", `Bool true ]
           else []) )
    ; "sources", `Assoc (source_counts rows)
    ; "since", float_json since
    ; "since_iso", unix_iso_json since
    ; "due_at", float_json due_at
    ; "due_at_iso", unix_iso_json due_at
    ; ( "next_action"
      , match rows with
        | [] -> `Null
        | row :: _ -> `String row.next_action )
    ]
;;

let keeper_rows ~base_path ~pending_approvals ~fusion_runs ~pending_confirms keeper_names =
  keeper_names
  |> List.map (fun keeper_name ->
    let external_attention_rows, external_attention_truncated =
      external_attention_rows ~base_path ~keeper_name
    in
    let rows =
      read_queue_rows ~base_path ~keeper_name Keeper_event_queue_persistence.load_pending
        ~source:Event_queue_pending ~next_action:"keeper_drain_event_queue"
      @ read_queue_rows ~base_path ~keeper_name Keeper_event_queue_persistence.load_inflight
          ~source:Event_queue_inflight ~next_action:"recover_inflight_turn"
      @ chat_queue_rows keeper_name
      @ turn_admission_rows ~base_path keeper_name
      @ hitl_rows keeper_name pending_approvals
      @ external_attention_rows
      @ fusion_rows keeper_name fusion_runs
      @ background_task_rows keeper_name
      @ pending_confirm_rows [ keeper_name ] pending_confirms
    in
    keeper_name, rows, external_attention_truncated)
;;

let rows_for_keeper keeper_name rows =
  rows
  |> List.filter (fun row ->
    match row.keeper_name with
    | Some owner -> String.equal owner keeper_name
    | None -> false)
;;

let global_rows_from rows =
  rows
  |> List.filter (fun row ->
    match row.keeper_name with
    | None -> true
    | Some _ -> false)
;;

let dashboard_json config =
  let now = Time_compat.now () in
  let keeper_names, keeper_name_read_error_rows =
    keeper_names_or_error_rows config
  in
  let pending_approvals = Keeper_approval_queue.list_pending_entries () in
  let fusion_runs = Fusion_run_registry.list_runs (Fusion_run_registry.global ()) in
  let pending_confirms, pending_confirm_read_error_rows =
    pending_confirms_or_error_rows config
  in
  let schedule_rows = schedule_rows_or_error config ~keeper_names in
  let busy_names = busy_keeper_names ~base_path:config.Workspace.base_path in
  let per_keeper =
    keeper_rows ~base_path:config.Workspace.base_path ~pending_approvals ~fusion_runs
      ~pending_confirms keeper_names
    |> List.map (fun (keeper_name, rows, external_attention_truncated) ->
      let rows = rows @ rows_for_keeper keeper_name schedule_rows in
      keeper_name, keeper_is_busy busy_names keeper_name, rows, external_attention_truncated)
  in
  let global_rows =
    global_rows_from schedule_rows
    @ keeper_name_read_error_rows
    @ pending_confirm_read_error_rows
  in
  let keeper_json_rows =
    per_keeper
    |> List.map (fun (keeper_name, busy, rows, external_attention_truncated) ->
      keeper_json keeper_name ~busy ~external_attention_truncated rows)
  in
  let all_keeper_rows =
    List.flatten
      (List.map
         (fun (_keeper_name, _busy, rows, _external_attention_truncated) -> rows)
         per_keeper)
  in
  let external_attention_truncated_keeper_count =
    per_keeper
    |> List.fold_left
         (fun count (_keeper_name, _busy, _rows, external_attention_truncated) ->
            if external_attention_truncated then count + 1 else count)
         0
  in
  let waiting_keeper_count =
    per_keeper
    |> List.fold_left
         (fun count (_keeper_name, busy, rows, _external_attention_truncated) ->
            match keeper_state ~busy rows with
            | Idle -> count
            | Busy | Waiting | Deferred -> count + 1)
         0
  in
  record_metrics ~now ~per_keeper ~global_rows;
  `Assoc
    [ "schema", `String "masc.dashboard.keeper_waiting_inventory.v1"
    ; "source", `String "server_keeper_waiting_inventory"
    ; "generated_at", `String (Masc_domain.now_iso ())
    ; "supported_states", `List (List.map (fun value -> `String value) [ "idle"; "busy"; "waiting"; "deferred" ])
    ; "keeper_count_known", `Bool (List.length keeper_name_read_error_rows = 0)
    ; "keeper_count", `Int (List.length keeper_names)
    ; "waiting_keeper_count", `Int waiting_keeper_count
    ; "row_count", `Int (List.length all_keeper_rows)
    ; "row_count_truncated", `Bool (external_attention_truncated_keeper_count > 0)
    ; "external_attention_row_limit", `Int external_attention_dashboard_row_limit
    ; ( "external_attention_truncated_keeper_count"
      , `Int external_attention_truncated_keeper_count )
    ; "global_row_count", `Int (List.length global_rows)
    ; ( "global_pending_confirm_count_known"
      , `Bool (List.length pending_confirm_read_error_rows = 0) )
    ; "global_pending_confirm_count", `Int (global_pending_confirm_count keeper_names pending_confirms)
    ; "source_counts", `Assoc (source_counts (all_keeper_rows @ global_rows))
    ; "keepers", `List keeper_json_rows
    ; "global_waiting_on", `List (List.map waiting_row_json global_rows)
    ]
;;
