type waiting_source =
  | Event_queue_pending
  | Chat_operation_queued
  | Chat_operation_running
  | Hitl_pending
  | Fusion_running
  | Schedule_waiting
  | Owner_shutdown
  | Operator_pending_confirm
  | Read_error

type keeper_state =
  | Idle
  | Busy
  | Waiting
  | Deferred

type wake_producer =
  | Board_dispatch
  | Board_attention_judge
  | Keeper_owner_actor
  | Keeper_supervisor
  | Fusion_sink
  | Connector_attention_hook
  | Hitl_resolution_hook
  | Keeper_ask_answer
  | Schedule_store
  | Schedule_runner
  | Operator_pending_confirm_store
  | Completion_authority
  | Keeper_task_cancellation
  | Keeper_workspace_message
  | Keeper_delegate
  | Keeper_composition
  | Read_model_reader

type waiting_row =
  { keeper_name : string option
  ; source : waiting_source
  ; waiting_on : string
  ; what : string
      (** Operator sentence for the row, derived from the row's typed fields.
          The raw vocabulary ([waiting_on], [wake_producer], [next_action],
          [detail]) stays for the technical disclosure; this is what the
          queue reads as by default. *)
  ; wake_producer : wake_producer
  ; since : float option
  ; due_at : float option
  ; next_action : string
  ; detail : Yojson.Safe.t
  }


let source_to_string = function
  | Event_queue_pending -> "event_queue_pending"
  | Chat_operation_queued -> "chat_operation_queued"
  | Chat_operation_running -> "chat_operation_running"
  | Hitl_pending -> "hitl_pending"
  | Fusion_running -> "fusion_running"
  | Schedule_waiting -> "schedule_waiting"
  | Owner_shutdown -> "owner_shutdown"
  | Operator_pending_confirm -> "operator_pending_confirm"
  | Read_error -> "read_error"
;;

let all_waiting_sources =
  [ Event_queue_pending
  ; Chat_operation_queued
  ; Chat_operation_running
  ; Hitl_pending
  ; Fusion_running
  ; Schedule_waiting
  ; Owner_shutdown
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
  | Board_attention_judge -> "board_attention_judge"
  | Keeper_owner_actor -> "keeper_owner_actor"
  | Keeper_supervisor -> "keeper_supervisor"
  | Fusion_sink -> "fusion_sink"
  | Connector_attention_hook -> "connector_attention_hook"
  | Hitl_resolution_hook -> "hitl_resolution_hook"
  | Keeper_ask_answer -> "keeper_ask_answer"
  | Schedule_store -> "schedule_store"
  | Schedule_runner -> "schedule_runner"
  | Operator_pending_confirm_store -> "operator_pending_confirm_store"
  | Keeper_task_cancellation -> "keeper_task_cancellation"
  | Completion_authority -> "completion_authority"
  | Keeper_composition -> "keeper_composition"
  | Keeper_workspace_message -> "keeper_workspace_message"
  | Keeper_delegate -> "keeper_delegate"
  | Read_model_reader -> "read_model_reader"
;;

let wake_producer_of_payload : Keeper_event_queue.stimulus_payload -> wake_producer =
  function
  | Board_signal _ -> Board_dispatch
  | Board_attention _ -> Board_attention_judge
  | Bootstrap -> Keeper_supervisor
  | Fusion_completed _ -> Fusion_sink
  | Schedule_due _ -> Schedule_runner
  | Connector_attention _ -> Connector_attention_hook
  | Hitl_resolved _ -> Hitl_resolution_hook
  | Ask_answered _ -> Keeper_ask_answer
  | Completion_authority_rejected _ -> Completion_authority
  | Task_cancelled _ -> Keeper_task_cancellation
  | Workspace_message _ -> Keeper_workspace_message
  | Delegate_completed _ -> Keeper_delegate
  | Composition_completed _ -> Keeper_composition
;;

let unix_iso_json = function
  | None -> `Null
  | Some ts -> `String (Masc_domain.iso8601_of_unix_seconds ts)
;;


let waiting_row_json (row : waiting_row) =
  `Assoc
    [ "keeper_name", Json_util.string_opt_to_json row.keeper_name
    ; "source", `String (source_to_string row.source)
    ; "waiting_on", `String row.waiting_on
    ; "what", `String row.what
    ; "wake_producer", `String (wake_producer_to_string row.wake_producer)
    ; "since", Json_util.float_opt_to_json row.since
    ; "since_iso", unix_iso_json row.since
    ; "due_at", Json_util.float_opt_to_json row.due_at
    ; "due_at_iso", unix_iso_json row.due_at
    ; "next_action", `String row.next_action
    ; "detail", row.detail
    ]
;;

(* [payload_kind] collapses every payload to a constant label, so the fields
   that say why a keeper is blocked travel separately: the rejection's reason,
   the cancellation's author and reason, the workspace message's sender and
   request id. The whole payload is never serialized here (a board stimulus
   carries post text). Every kind is enumerated so a new payload has to decide
   its own visibility. *)
let queue_payload_detail_fields : Keeper_event_queue.stimulus_payload -> (string * Yojson.Safe.t) list =
  function
  | Completion_authority_rejected rejection ->
    [ "rejection_reason", `String rejection.car_reason
    ; "rejection_task_id", `String rejection.car_task_id
    ]
  | Ask_answered answered -> [ "answered_ask_id", `String answered.ask_id ]
  | Task_cancelled cancellation ->
    (* The reason is emitted only when the canceller gave one, so an operator
       can tell an unexplained cancellation from one whose reason was empty. *)
    [ "cancelled_task_id", `String cancellation.tc_task_id
    ; "cancelled_by", `String cancellation.tc_cancelled_by
    ]
    @ (match cancellation.tc_reason with
       | None -> []
       | Some reason -> [ "cancelled_reason", `String reason ])
  | Workspace_message message ->
    [ "message_request_id", `String message.wmsg_request_id
    ; "message_from", `String message.wmsg_from
    ]
  | Board_signal _
  | Board_attention _
  | Bootstrap
  | Fusion_completed _
  | Schedule_due _
  | Connector_attention _
  | Hitl_resolved _ -> []
  | Delegate_completed dc ->
    [ "delegate_operation_id", `String dc.dc_operation_id
    ]
  | Composition_completed cc ->
    [ "composition_request_id", `String cc.cc_request_id
    ; "composition_tool", `String cc.cc_tool
    ]
;;

let board_signal_what (signal : Keeper_event_queue.board_stimulus) =
  match signal.kind with
  | Post_created -> Printf.sprintf "%s의 새 글" signal.author
  | Comment_added -> Printf.sprintf "%s의 댓글" signal.author
  | Reaction_changed change ->
    Printf.sprintf
      "%s의 반응 %s"
      change.user_id
      (if change.reacted then "추가" else "제거")
  | Vote_cast change ->
    Printf.sprintf
      "%s의 %s 투표"
      change.voter
      (match change.direction with
       | Vote_up -> "찬성"
       | Vote_down -> "반대")
;;

(* One operator sentence per payload kind, from the payload's own typed
   fields. Every kind is enumerated: a new stimulus has to say what an
   operator should read it as before it can reach the queue view. *)
let queue_payload_what : Keeper_event_queue.stimulus_payload -> string = function
  | Board_signal signal -> board_signal_what signal
  | Board_attention attention ->
    Printf.sprintf "%s (관련성 판정 통과)" (board_signal_what attention.signal)
  | Bootstrap -> "기동 직후 첫 턴"
  | Fusion_completed completion ->
    (match completion.terminal with
     | Fusion_succeeded _ -> Printf.sprintf "Fusion 결과 도착 · %s" completion.run_id
     | Fusion_failed _ -> Printf.sprintf "Fusion 실패 · %s" completion.run_id
     | Fusion_cancelled -> Printf.sprintf "Fusion 취소됨 · %s" completion.run_id)
  | Schedule_due wake ->
    Printf.sprintf
      "예약 실행 시각 도래 · %s"
      (match wake.title with
       | Some title -> title
       | None -> wake.schedule_id)
  | Connector_attention _ -> "외부 메시지 도착"
  | Hitl_resolved resolution ->
    (match resolution.decision with
     | Hitl_approved -> Printf.sprintf "운영자 승인됨 · %s" resolution.approval_id
     | Hitl_rejected _ -> Printf.sprintf "운영자 거절됨 · %s" resolution.approval_id)
  | Ask_answered _ -> "질문에 답이 왔음"
  | Completion_authority_rejected rejection ->
    Printf.sprintf "작업 %s 완료 증거 거절됨" rejection.car_task_id
  | Task_cancelled cancellation ->
    Printf.sprintf
      "%s가 작업 %s 취소"
      cancellation.tc_cancelled_by
      cancellation.tc_task_id
  | Workspace_message message -> Printf.sprintf "%s가 보낸 메시지" message.wmsg_from
  | Delegate_completed dc ->
    (match dc.dc_terminal with
     | Delegate_replied _ ->
       Printf.sprintf "%s의 답 도착 · %s" dc.dc_keeper dc.dc_operation_id
     | Delegate_no_reply ->
       Printf.sprintf "%s가 답 없이 끝냄 · %s" dc.dc_keeper dc.dc_operation_id
     | Delegate_failed _ ->
       Printf.sprintf "%s가 끝내지 못함 · %s" dc.dc_keeper dc.dc_operation_id)
  | Composition_completed cc ->
    (match cc.cc_terminal with
     | Composition_succeeded ->
       Printf.sprintf "%s 끝남 · %s" cc.cc_tool cc.cc_request_id
     | Composition_failed _ ->
       Printf.sprintf "%s 실패 · %s" cc.cc_tool cc.cc_request_id
     | Composition_cancelled _ ->
       Printf.sprintf "%s 취소됨 · %s" cc.cc_tool cc.cc_request_id)
;;

let urgency_what_suffix : Keeper_event_queue.urgency -> string = function
  | Immediate -> " (즉시)"
  | Normal -> ""
  | Low -> " (낮은 우선순위)"
;;

let stimulus_what (stimulus : Keeper_event_queue.stimulus) =
  queue_payload_what stimulus.payload ^ urgency_what_suffix stimulus.urgency
;;

(* Pending Connector_attention stimuli repeat one row per accepted message
   (the intake invariant keeps every event durable), so a Keeper that cannot
   consume right now — a blocked lane, a stalled cycle — turns the inventory
   into a wall of identical rows under the display cap. RFC-0377 already
   drains a same-conversation backlog in one turn, so per-event rows carry no
   operator decision the aggregate loses: this projection collapses every
   pending Connector_attention stimulus into one row per urgency with a count
   and the oldest arrival. The oldest member keeps its [source_ref] /
   [source_incarnation] so the operator boundary still resolves the row, and
   every member event id rides in [detail]. A single pending Connector event
   renders exactly the ungrouped row. Every non-Connector stimulus keeps its
   own row. *)
let rows_for_queue_snapshot ~keeper_name ~source ~next_action selections =
  let connector_selections =
    List.filter_map
      (fun (selection : Keeper_event_queue_state.pending_selection) ->
         match selection.source.payload with
         | Keeper_event_queue.Connector_attention _ -> Some selection
         | _ -> None)
      selections
  in
  let connector_count = List.length connector_selections in
  let oldest_arrived_at =
    List.fold_left
      (fun oldest (selection : Keeper_event_queue_state.pending_selection) ->
         Float.min oldest selection.source.arrived_at)
      Float.max_float connector_selections
  in
  let connector_event_ids =
    List.filter_map
      (fun (selection : Keeper_event_queue_state.pending_selection) ->
         match selection.source.payload with
         | Keeper_event_queue.Connector_attention { event_id; _ } -> Some event_id
         | _ -> None)
      connector_selections
    |> List.sort String.compare
  in
  let connectors_emitted = ref false in
  let rec go queue_index acc = function
    | [] -> List.rev acc
    | (selection : Keeper_event_queue_state.pending_selection) :: rest ->
      let stimulus : Keeper_event_queue.stimulus = selection.source in
      (* [source_ref] + [source_incarnation] are the exact-entry address the
         operator boundary
         ([Server_dashboard_http_keeper_event_queue_operator]) resolves
         through [Keeper_event_queue_state.resolve_pending_selection], so a
         row read here can be cancelled, transferred, or reprioritized
         without a second queue projection. Both are wire strings: the ref
         is a SHA-256 hex and the incarnation a decimal int64. *)
      let base_detail =
        [ "queue_index", `Int queue_index
        ; "post_id", `String stimulus.post_id
        ; ( "source_ref"
          , `String (Keeper_event_queue_state.source_snapshot_ref stimulus) )
        ; ( "source_incarnation"
          , `String (Int64.to_string selection.admitted_revision) )
        ; "urgency", `String (Keeper_event_queue.urgency_to_string stimulus.urgency)
        ; "arrived_at_unix", `Float stimulus.arrived_at
        ; "payload_kind",
          `String (Keeper_event_queue.payload_kind_label stimulus.payload)
        ]
        @ queue_payload_detail_fields stimulus.payload
      in
      let row ~what ~since ~detail =
        { keeper_name = Some keeper_name
        ; source
        ; waiting_on = Keeper_event_queue.payload_kind_label stimulus.payload
        ; what
        ; wake_producer = wake_producer_of_payload stimulus.payload
        ; since
        ; due_at = None
        ; next_action
        ; detail
        }
      in
      (match stimulus.payload with
       | Keeper_event_queue.Connector_attention _
         when connector_count > 1 && not !connectors_emitted ->
         connectors_emitted := true;
         let bounded, bounded_truncated =
           let rec take count acc = function
             | [] -> (List.rev acc, false)
             | _ :: _ when count <= 0 -> (List.rev acc, true)
             | id :: rest -> take (count - 1) (id :: acc) rest
           in
           take 10 [] connector_event_ids
         in
         go
           (queue_index + 1)
           (row
              ~what:
                (Printf.sprintf
                   "외부 메시지 도착 ×%d" connector_count
                   ^ urgency_what_suffix stimulus.urgency)
              ~since:(Some oldest_arrived_at)
              ~detail:
                (`Assoc
                   (base_detail
                    @ [ ("group_count", `Int connector_count)
                      ; ( "group_event_ids"
                        , `List (List.map (fun id -> `String id) bounded) )
                      ; ("group_event_ids_truncated", `Bool bounded_truncated)
                      ]))
              :: acc)
           rest
       | Keeper_event_queue.Connector_attention _ when connector_count > 1 ->
         (* Already represented by the aggregate row above. *)
         go (queue_index + 1) acc rest
       | _ ->
         go
           (queue_index + 1)
           (row
              ~what:(stimulus_what stimulus)
              ~since:(Some stimulus.arrived_at)
              ~detail:(`Assoc base_detail)
              :: acc)
           rest)
  in
  go 0 [] selections
;;

let read_error_row ?keeper_name ~waiting_on ~next_action detail =
  { keeper_name
  ; source = Read_error
  ; waiting_on
  ; what = Printf.sprintf "대기 기록 읽기 실패 · %s" waiting_on
  ; wake_producer = Read_model_reader
  ; since = None
  ; due_at = None
  ; next_action
  ; detail
  }
;;

let queue_read_error_detail (error : Keeper_event_queue_persistence.snapshot_read_error) =
  `Assoc
    [ ( "kind"
      , `String
          (Keeper_event_queue_persistence.snapshot_read_error_kind_to_string
             error.kind) )
    ; "path", Json_util.string_opt_to_json error.path
    ; "message", `String error.message
    ]
;;

let queue_read_error_rows ~keeper_name errors =
  List.map
    (fun error ->
       read_error_row
         ~keeper_name
         ~waiting_on:"event_queue_snapshot"
         ~next_action:"inspect_queue_snapshot"
         (queue_read_error_detail error))
    errors
;;

let event_queue_rows ~base_path ~keeper_name =
  let snapshot =
    Keeper_event_queue_persistence.load_selections_with_errors ~base_path ~keeper_name
  in
  rows_for_queue_snapshot
    ~keeper_name
    ~source:Event_queue_pending
    ~next_action:"keeper_drain_event_queue"
    snapshot.pending
  @ queue_read_error_rows ~keeper_name snapshot.read_errors
;;

let schedule_read_error_detail = function
  | Schedule_store.Corrupt_read_ledger { primary_err; recovery_err } ->
    `Assoc
      [ "primary_err", `String primary_err
      ; "recovery_err", Json_util.string_opt_to_json recovery_err
      ]
;;

let chat_operation_rows ~base_path keeper_name =
  match Keeper_owner_registry.operation_projection ~base_path ~keeper_name with
  | Error error ->
    [ read_error_row
        ~keeper_name
        ~waiting_on:"keeper_owner_operation_projection"
        ~next_action:"inspect_keeper_owner"
        (`Assoc
           [ "message",
             `String (Keeper_owner_registry.lookup_error_to_string error)
           ])
    ]
  | Ok projection ->
    let queued =
      if projection.queued_count = 0
      then []
      else
        [ { keeper_name = Some keeper_name
          ; source = Chat_operation_queued
          ; waiting_on = "owner_fifo"
          ; what = Printf.sprintf "운영자 채팅 %d건 대기" projection.queued_count
          ; wake_producer = Keeper_owner_actor
          ; since = None
          ; due_at = None
          ; next_action = "keeper_owner_start_fifo_head"
          ; detail = `Assoc [ "queued_count", `Int projection.queued_count ]
          }
        ]
    in
    let running =
      match projection.running_operation_id with
      | None -> []
      | Some operation_id ->
        [ { keeper_name = Some keeper_name
          ; source = Chat_operation_running
          ; waiting_on = "keeper_turn"
          ; what = "운영자와 진행 중인 대화"
          ; wake_producer = Keeper_owner_actor
          ; since = None
          ; due_at = None
          ; next_action = "keeper_owner_settle_operation"
          ; detail =
              `Assoc
                [ "operation_id",
                  `String
                    (Keeper_chat_operation.Operation_id.to_string operation_id)
                ]
          }
        ]
    in
    running @ queued
;;

let owner_shutdown_rows ~base_path keeper_name =
  match Keeper_owner_registry.get ~base_path ~keeper_name with
  | Error error ->
    [ { keeper_name = Some keeper_name
      ; source = Read_error
      ; waiting_on = "keeper_owner"
      ; what = "대기 기록 읽기 실패 · keeper_owner"
      ; wake_producer = Read_model_reader
      ; since = None
      ; due_at = None
      ; next_action = "restart_keeper_owner"
      ; detail =
          `Assoc
            [ "error", `String (Keeper_owner_registry.lookup_error_to_string error) ]
      }
    ]
  | Ok owner ->
  let in_flight = Keeper_owner.turn_in_flight owner in
  let in_flight_detail =
    match in_flight with
    | None -> `Null
    | Some (info : Keeper_owner.turn_in_flight) ->
      let lane =
        match info.lane with
        | Keeper_owner.Autonomous -> "autonomous"
        | Keeper_owner.Chat_operation -> "chat_operation"
        | Keeper_owner.Maintenance -> "maintenance"
      in
      `Assoc
        [ "lane", `String lane
        ; "started_at", `Float info.started_at
        ; "started_at_iso", unix_iso_json (Some info.started_at)
        ]
  in
  let shutdown_rows =
    match Keeper_owner.shutdown_operation_id owner with
    | None -> []
    | Some operation_id ->
      [ { keeper_name = Some keeper_name
        ; source = Owner_shutdown
        ; waiting_on = "shutdown"
        ; what = "종료 정리 중"
        ; wake_producer = Keeper_owner_actor
        ; since = None
        ; due_at = None
        ; next_action = "keeper_shutdown_finalize"
        ; detail =
            `Assoc
              [ ( "shutdown_operation_id"
                , `String
                    (Keeper_shutdown_types.Operation_id.to_string operation_id) )
              ; "admission_fenced", `Bool true
              ; "in_flight", in_flight_detail
              ]
        }
      ]
  in
  shutdown_rows
;;

let hitl_rows keeper_name pending =
  pending
  |> List.filter (fun (entry : Keeper_approval_queue_rules_types.pending_approval) ->
    String.equal entry.keeper_name keeper_name)
  |> List.map (fun (entry : Keeper_approval_queue_rules_types.pending_approval) ->
    { keeper_name = Some keeper_name
    ; source = Hitl_pending
    ; waiting_on = entry.tool_name
    ; what = Printf.sprintf "운영자 승인 대기 · %s" entry.tool_name
    ; wake_producer = Hitl_resolution_hook
    ; since = Some entry.requested_at
    ; due_at = None
    ; next_action = "operator_resolve_hitl"
    ; detail =
        `Assoc
          [ "approval_id", `String entry.id
          ; "tool_name", `String entry.tool_name
          ; "summary_status", Keeper_approval_queue_rules_types.summary_status_to_yojson entry.summary_status
          ; "exact_attempt", Keeper_approval_queue_rules_types.exact_attempt_state_to_yojson entry.exact_attempt
          ; ( "summary_attempt_disposition"
            , Keeper_approval_queue_rules_types.summary_attempt_disposition_to_yojson
                entry.summary_attempt_disposition )
          ; "turn_id", Json_util.int_opt_to_json entry.turn_id
          ; "task_id", Json_util.string_opt_to_json entry.task_id
          ; "goal_id", Json_util.string_opt_to_json entry.goal_id
          ]
    })
;;

(* The pending rows this used to build carried the same events the queue rows
   carry, and the queue rows carry them better -- collapsed per urgency, with
   the [source_ref] an operator can cancel or transfer through. What was never
   duplicated is a store this build cannot read: that is the Keeper's own
   evidence log failing, and no other row reports it. *)
let external_attention_store_error_rows ~base_path ~keeper_name =
  match
    Keeper_external_attention.pending_for_keeper_result ~base_path ~keeper_name
      ~limit:0 ()
  with
  | Ok _ -> []
  | Error err ->
    [ read_error_row
        ~keeper_name
        ~waiting_on:"external_attention_store"
        ~next_action:"repair_external_attention_store"
        (`Assoc [ "error", `String err ])
    ]
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
          ; what = Printf.sprintf "Fusion 실행 중 · %s" run.preset
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


let pending_confirm_row ?keeper_name
      (entry : Workspace_hooks.operator_pending_confirm_request)
  =
  { keeper_name
  ; source = Operator_pending_confirm
  ; waiting_on = entry.action_type
  ; what = Printf.sprintf "운영자 확인 대기 · %s" entry.action_type
  ; wake_producer = Operator_pending_confirm_store
  ; since = None
  ; due_at = None
  ; next_action = "operator_confirm_action"
  ; detail =
      `Assoc
        [ "confirm_token", `String entry.confirm_token
        ; "trace_id", `String entry.trace_id
        ; "actor", `String entry.actor
        ; "target_type", `String entry.target_type
        ; "target_id", Json_util.string_opt_to_json entry.target_id
        ; "delegated_tool", `String entry.delegated_tool
        ; "created_at", `String entry.created_at
        ; "expires_at", Json_util.string_opt_to_json entry.expires_at
        ]
  }
;;

let pending_confirm_keeper_target keeper_names
      (entry : Workspace_hooks.operator_pending_confirm_request)
  =
  match entry.target_type, entry.target_id with
  | "keeper", Some keeper_name when List.exists (String.equal keeper_name) keeper_names ->
    Some keeper_name
  | _, (None | Some _) -> None
;;

let pending_confirm_rows keeper_names pending_confirms =
  pending_confirms
  |> List.filter_map (fun (entry : Workspace_hooks.operator_pending_confirm_request) ->
    match pending_confirm_keeper_target keeper_names entry with
    | Some keeper_name -> Some (pending_confirm_row ~keeper_name entry)
    | None -> None)
;;

let global_pending_confirm_rows keeper_names pending_confirms =
  pending_confirms
  |> List.filter_map (fun entry ->
    if Option.is_some (pending_confirm_keeper_target keeper_names entry)
    then None
    else Some (pending_confirm_row entry))
;;

let schedule_active (request : Schedule_domain.schedule_request) =
  not (Schedule_domain.is_terminal request.status)
;;

let schedule_next_action (request : Schedule_domain.schedule_request) =
  match request.status with
  | Scheduled -> "wait_until_due"
  | Due -> "schedule_runner_dispatch"
  | Running -> "await_schedule_completion"
  | Succeeded | Failed | Cancelled | Expired -> "none"
;;

let schedule_waiting_on (request : Schedule_domain.schedule_request) =
  match Schedule_payload_projection.kind request with
  | Some kind -> kind
  | None -> request.schedule_id
;;

let schedule_keeper_owner keeper_names (request : Schedule_domain.schedule_request) =
  match request.scheduled_by.kind with
  | Human_operator | System -> None
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
    ; what = Printf.sprintf "예약 실행 · %s" request.schedule_id
    ; wake_producer =
        (match request.status with
         | Scheduled | Due | Running -> Schedule_runner
         | Succeeded | Failed | Cancelled | Expired -> Schedule_store)
    ; since = Some request.requested_at
    ; due_at = Some request.due_at
    ; next_action = schedule_next_action request
    ; detail =
        `Assoc
          [ "schedule_instance_id", `String request.schedule_instance_id
          ; "schedule_id", `String request.schedule_id
          ; "status", `String (Schedule_domain.schedule_status_to_string request.status)
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
  match (Atomic.get Workspace_hooks.operator_pending_confirm_read_result_fn) config with
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
  if
    List.exists
      (fun row ->
         row.source = Fusion_running
         || row.source = Owner_shutdown)
      rows
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
       (fun count (entry : Workspace_hooks.operator_pending_confirm_request) ->
          if Option.is_some (pending_confirm_keeper_target keeper_names entry)
          then count
          else count + 1)
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
              (fun total (_keeper_name, busy, rows) ->
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
         (fun (_keeper_name, _busy, rows) -> rows)
         per_keeper)
  in
  record_scope_metrics ~now ~scope:"keeper" all_keeper_rows;
  record_scope_metrics ~now ~scope:"global" global_rows;
  record_keeper_state_metrics per_keeper
;;

let current_execution_json ~base_path keeper_name =
  match Keeper_registry.get ~base_path keeper_name with
  | Some ({ current_turn_observation = Some _; _ } as entry) ->
    let latest_tool =
      Keeper_registry.StringMap.bindings entry.tool_usage
      |> List.fold_left
           (fun latest (tool_name, usage) ->
              match latest with
              | None -> Some (tool_name, usage.Keeper_types.last_used_at)
              | Some (_, latest_at) when usage.last_used_at > latest_at ->
                Some (tool_name, usage.last_used_at)
              | Some _ -> latest)
           None
    in
    (match
       Keeper_composite_observer.observe entry
       |> Keeper_composite_observer.snapshot_to_json
     with
     | `Assoc fields ->
       `Assoc
         (("latest_tool",
           match latest_tool with
           | None -> `Null
           | Some (tool_name, used_at) ->
             `Assoc
               [ "name", `String tool_name
               ; "used_at", `Float used_at
               ; "used_at_iso", `String (Masc_domain.iso8601_of_unix_seconds used_at)
               ])
          :: fields)
     | value -> value)
  | None | Some { current_turn_observation = None; _ } -> `Null
;;

let source_next_actions rows =
  rows
  |> List.fold_left
       (fun actions row ->
          let source = source_to_string row.source in
          let current =
            match List.assoc_opt source actions with
            | None -> []
            | Some values -> values
          in
          if List.mem row.next_action current
          then actions
          else (source, current @ [ row.next_action ]) :: List.remove_assoc source actions)
       []
  |> List.sort (fun (left, _) (right, _) -> String.compare left right)
  |> List.map (fun (source, actions) ->
    source, `List (List.map (fun action -> `String action) actions))
;;

let keeper_json ~base_path keeper_name ~busy rows =
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
    ; "sources", `Assoc (source_counts rows)
    ; "since", Json_util.float_opt_to_json since
    ; "since_iso", unix_iso_json since
    ; "due_at", Json_util.float_opt_to_json due_at
    ; "due_at_iso", unix_iso_json due_at
    ; "source_next_actions", `Assoc (source_next_actions rows)
    ; "current_execution", current_execution_json ~base_path keeper_name
    ]
;;

let keeper_rows ~base_path ~pending_approvals ~fusion_runs ~pending_confirms keeper_names =
  keeper_names
  |> List.map (fun keeper_name ->
    let rows =
      event_queue_rows ~base_path ~keeper_name
      @ chat_operation_rows ~base_path keeper_name
      @ owner_shutdown_rows ~base_path keeper_name
      @ hitl_rows keeper_name pending_approvals
      @ external_attention_store_error_rows ~base_path ~keeper_name
      @ fusion_rows keeper_name fusion_runs
      @ pending_confirm_rows [ keeper_name ] pending_confirms
    in
    keeper_name, rows)
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

let pending_approval_read_error error =
  { keeper_name = None
  ; source = Read_error
  ; waiting_on = "keeper_gate_pending_store"
  ; what = "대기 기록 읽기 실패 · keeper_gate_pending_store"
  ; wake_producer = Read_model_reader
  ; since = None
  ; due_at = None
  ; next_action = "reset_runtime_state"
  ; detail =
      Keeper_approval_queue.approval_queue_unavailable_state_json error
  }
;;

let dashboard_json_with_pending_reader_scoped ?keeper_name ~read_pending config =
  let now = Time_compat.now () in
  let keeper_names, keeper_name_read_error_rows =
    match keeper_name with
    | Some name -> [ name ], []
    | None -> keeper_names_or_error_rows config
  in
  let pending_approvals, pending_approval_state, pending_approval_read_error_rows =
    match read_pending ~base_path:config.Workspace.base_path with
    | Ok (entries, pending_approval_store_read_errors) ->
      ( entries
      , (match pending_approval_store_read_errors with
         | [] -> Keeper_approval_queue.approval_queue_ready_state_json
         | first :: _ ->
           Keeper_approval_queue.approval_queue_unavailable_state_json first)
      , List.map pending_approval_read_error pending_approval_store_read_errors )
    | Error error ->
      ( []
      , Keeper_approval_queue.approval_queue_unavailable_state_json error
      , [ pending_approval_read_error error ] )
  in
  let fusion_runs = Fusion_run_registry.list_runs (Fusion_run_registry.global ()) in
  let pending_confirms, pending_confirm_read_error_rows =
    pending_confirms_or_error_rows config
  in
  let schedule_rows = schedule_rows_or_error config ~keeper_names in
  let busy_names = busy_keeper_names ~base_path:config.Workspace.base_path in
  let per_keeper =
    keeper_rows ~base_path:config.Workspace.base_path ~pending_approvals ~fusion_runs
      ~pending_confirms keeper_names
    |> List.map (fun (keeper_name, rows) ->
      let rows = rows @ rows_for_keeper keeper_name schedule_rows in
      keeper_name, keeper_is_busy busy_names keeper_name, rows)
  in
  let global_rows =
    global_rows_from schedule_rows
    @ global_pending_confirm_rows keeper_names pending_confirms
    @ keeper_name_read_error_rows
    @ pending_confirm_read_error_rows
    @ pending_approval_read_error_rows
  in
  let keeper_json_rows =
    per_keeper
    |> List.map (fun (keeper_name, busy, rows) ->
      keeper_json ~base_path:config.Workspace.base_path keeper_name ~busy rows)
  in
  let all_keeper_rows =
    List.flatten
      (List.map
         (fun (_keeper_name, _busy, rows) -> rows)
         per_keeper)
  in
  let waiting_keeper_count =
    per_keeper
    |> List.fold_left
         (fun count (_keeper_name, busy, rows) ->
            match keeper_state ~busy rows with
            | Idle -> count
            | Busy | Waiting | Deferred -> count + 1)
         0
  in
  (match keeper_name with
   | None -> record_metrics ~now ~per_keeper ~global_rows
   | Some _ -> ());
  `Assoc
    [ "schema", `String "masc.dashboard.keeper_waiting_inventory.v3"
    ; "source", `String "server_keeper_waiting_inventory"
    ; "generated_at", `String (Masc_domain.now_iso ())
    ; "supported_states", `List (List.map (fun value -> `String value) [ "idle"; "busy"; "waiting"; "deferred" ])
    ; "keeper_count_known", `Bool (List.length keeper_name_read_error_rows = 0)
    ; "keeper_count", `Int (List.length keeper_names)
    ; "waiting_keeper_count", `Int waiting_keeper_count
    ; "row_count", `Int (List.length all_keeper_rows)
    ; "global_row_count", `Int (List.length global_rows)
    ; ( "global_pending_confirm_count_known"
      , `Bool (List.length pending_confirm_read_error_rows = 0) )
    ; "global_pending_confirm_count", `Int (global_pending_confirm_count keeper_names pending_confirms)
    ; "pending_approval_state", pending_approval_state
    ; "source_counts", `Assoc (source_counts (all_keeper_rows @ global_rows))
    ; "keepers", `List keeper_json_rows
    ; "global_waiting_on", `List (List.map waiting_row_json global_rows)
    ]
;;

let dashboard_json_with_pending_reader ~read_pending config =
  dashboard_json_with_pending_reader_scoped
    ~read_pending:(fun ~base_path ->
      read_pending ~base_path |> Result.map (fun entries -> entries, []))
    config
;;

let dashboard_json config =
  dashboard_json_with_pending_reader_scoped
    ~read_pending:
      Keeper_approval_queue.list_pending_entries_with_read_errors_for_workspace
    config
;;

let dashboard_json_for_keeper config ~keeper_name =
  dashboard_json_with_pending_reader_scoped
    ~keeper_name
    ~read_pending:
      Keeper_approval_queue.list_pending_entries_with_read_errors_for_workspace
    config
;;

module For_testing = struct
  let dashboard_json_with_pending_reader = dashboard_json_with_pending_reader


  let rows_for_queue_snapshot = rows_for_queue_snapshot
end
