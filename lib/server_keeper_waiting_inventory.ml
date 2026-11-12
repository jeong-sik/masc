module String_map = Map.Make (String)
module String_set = Set.Make (String)

type waiting_source =
  | Event_queue_pending
  | Chat_operation_queued
  | Chat_operation_running
  | Hitl_pending
  | Fusion_running
  | Schedule_waiting
  | Owner_shutdown
  | Operator_pending_confirm
  | Runtime_quota_spent
  | Read_error
  | Observation_unavailable
[@@deriving enumerate]

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
  | Keeper_job
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
  | Runtime_quota_spent -> "runtime_quota_spent"
  | Read_error -> "read_error"
  | Observation_unavailable -> "observation_unavailable"
;;

let source_of_string value =
  match List.find_opt (fun v -> String.equal (source_to_string v) value) all_of_waiting_source with
  | Some v -> Ok v
  | None -> Error (Printf.sprintf "Unknown Keeper inventory source: %S" value)
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
  ; Runtime_quota_spent
  ; Read_error
  ; Observation_unavailable
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
  | Keeper_job -> "keeper_job"
  | Keeper_workspace_message -> "keeper_workspace_message"
  | Keeper_delegate -> "keeper_delegate"
  | Read_model_reader -> "read_model_reader"
;;

let wake_producer_of_payload : Keeper_event_queue.stimulus_payload -> wake_producer =
  function
  | Board_routing_pending _ | Board_signal _ -> Board_dispatch
  | Board_attention _ -> Board_attention_judge
  | Bootstrap -> Keeper_supervisor
  | Fusion_completed _ -> Fusion_sink
  | Schedule_due _ -> Schedule_runner
  | Connector_attention _ -> Connector_attention_hook
  | Hitl_resolved _ -> Hitl_resolution_hook
  | Ask_answered _ -> Keeper_ask_answer
  | Completion_authority_rejected _ -> Completion_authority
  | Task_outcome _ -> Completion_authority
  | Task_cancelled _ -> Keeper_task_cancellation
  | Workspace_message _ -> Keeper_workspace_message
  | Delegate_completed _ -> Keeper_delegate
  | Composition_completed _ -> Keeper_composition
  | Tool_result_ready _ -> Keeper_owner_actor
  | Owned_job_completed _ -> Keeper_job
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
  | Task_outcome outcome ->
    [ "outcome_task_id", `String outcome.to_task_id
    ; "outcome_verification_id", `String outcome.to_verification_id
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
  | Board_routing_pending _ | Board_signal _
  | Board_attention _
  | Bootstrap
  | Fusion_completed _
  | Schedule_due _
  | Connector_attention _
  | Hitl_resolved _ -> []
  | Delegate_completed dc ->
    [ "delegate_operation_id", `String dc.dc_operation_id
    ]
  | Tool_result_ready receipt_id -> [ "tool_result_receipt_id", `String receipt_id ]
  | Owned_job_completed completion ->
    [ "job_id", `String (Keeper_owned_job_identity.Job_id.to_string completion.oj_job_id)
    ; "source", Keeper_owned_job_identity.source_to_json completion.oj_source
    ; "channel", Keeper_continuation_channel.to_yojson completion.oj_channel ]
  | Composition_completed cc ->
    [ "composition_request_id", `String cc.cc_request_id
    ; "composition_tool", `String cc.cc_tool
    ]
;;

(* One operator sentence per payload kind, from the payload's own typed
   fields. Every kind is enumerated: a new stimulus has to say what an
   operator should read it as before it can reach the queue view. *)
let queue_payload_what : Keeper_event_queue.stimulus_payload -> string = function
  | Board_routing_pending _ | Board_signal _ | Board_attention _ -> "Board 알림 대기"
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
  | Task_outcome outcome ->
    Printf.sprintf "작업 %s 증거 승인됨 (%s)" outcome.to_task_id outcome.to_verification_id
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
  | Tool_result_ready _ -> "이전 실행 결과 회수"
  | Owned_job_completed completion ->
    "실행 결과 도착 · " ^ Keeper_owned_job_identity.Job_id.to_string completion.oj_job_id
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
   own row.

   Pending Schedule_due stimuli of one schedule repeat the same way: a
   recurring schedule advances as soon as its wake is durably enqueued
   ([Schedule_store.accept_running]), so a Keeper whose autonomous lane has
   not run for hours holds one occurrence per period -- 31 rows of "예약
   실행 시각 도래 · 삼국지 2 캠페인 플레이 이어가기" on 2026-09-14. The turn
   consumes them as one batch, so per-occurrence rows carry no decision the
   aggregate loses. They collapse into one row per schedule with the count,
   the oldest arrival, the first and last due instant, and every member's
   exact address in [detail]. A single pending occurrence renders exactly
   the ungrouped row. *)
let rows_for_queue_snapshot ~keeper_name ~source ~next_action selections =
  let connector_selections =
    List.filter_map
      (fun (selection : Keeper_event_queue_state.pending_selection) ->
         match selection.source.payload with
         | Keeper_event_queue.Connector_attention _ -> Some selection
         | Keeper_event_queue.Bootstrap | Keeper_event_queue.Board_routing_pending _ | Keeper_event_queue.Board_signal _
         | Keeper_event_queue.Board_attention _ | Keeper_event_queue.Fusion_completed _
         | Keeper_event_queue.Schedule_due _ | Keeper_event_queue.Hitl_resolved _
         | Keeper_event_queue.Ask_answered _ | Keeper_event_queue.Completion_authority_rejected _
         | Keeper_event_queue.Task_cancelled _ | Keeper_event_queue.Workspace_message _
         | Keeper_event_queue.Delegate_completed _ | Keeper_event_queue.Composition_completed _ | Keeper_event_queue.Tool_result_ready _ | Keeper_event_queue.Owned_job_completed _
         | Keeper_event_queue.Task_outcome _ -> None)
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
         | Keeper_event_queue.Bootstrap | Keeper_event_queue.Board_routing_pending _ | Keeper_event_queue.Board_signal _
         | Keeper_event_queue.Board_attention _ | Keeper_event_queue.Fusion_completed _
         | Keeper_event_queue.Schedule_due _ | Keeper_event_queue.Hitl_resolved _
         | Keeper_event_queue.Ask_answered _ | Keeper_event_queue.Completion_authority_rejected _
         | Keeper_event_queue.Task_cancelled _ | Keeper_event_queue.Workspace_message _
         | Keeper_event_queue.Delegate_completed _ | Keeper_event_queue.Composition_completed _ | Keeper_event_queue.Tool_result_ready _ | Keeper_event_queue.Owned_job_completed _
         | Keeper_event_queue.Task_outcome _ -> None)
      connector_selections
    |> List.sort String.compare
  in
  let connectors_emitted = ref false in
  (* One entry per schedule_id with two or more pending occurrences. Members
     keep queue order; the aggregate row takes the position of the first. *)
  let schedule_members =
    List.fold_left
      (fun acc (selection : Keeper_event_queue_state.pending_selection) ->
         match selection.source.payload with
         | Keeper_event_queue.Schedule_due wake ->
           let existing =
             Option.value (String_map.find_opt wake.schedule_id acc) ~default:[]
           in
           String_map.add wake.schedule_id ((wake, selection) :: existing) acc
         | Board_routing_pending _ | Board_signal _ | Board_attention _ | Bootstrap | Fusion_completed _
         | Connector_attention _ | Hitl_resolved _ | Ask_answered _
         | Completion_authority_rejected _ | Task_outcome _ | Task_cancelled _
         | Workspace_message _ | Delegate_completed _ | Composition_completed _ | Tool_result_ready _ | Owned_job_completed _ -> acc)
      String_map.empty selections
  in
  let schedule_group wake_schedule_id =
    match String_map.find_opt wake_schedule_id schedule_members with
    | Some (_ :: _ :: _ as members) -> Some (List.rev members)
    | Some ([] | [ _ ]) | None -> None
  in
  let schedules_emitted = ref String_set.empty in
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
        match stimulus.payload with
        (* This inventory is public-read and has no authenticated Board
           reader. Even actors and post IDs disclose a private event. Exact
           source controls carry only opaque addresses; their effects remain
           on the authorized operator boundary. *)
        | Keeper_event_queue.Board_routing_pending _ | Board_signal _ | Board_attention _ ->
          [ "source_ref", `String (Keeper_event_queue_state.source_snapshot_ref stimulus)
          ; "source_incarnation", `String (Int64.to_string selection.admitted_revision) ]
        | Bootstrap | Fusion_completed _ | Schedule_due _ | Connector_attention _
        | Hitl_resolved _ | Ask_answered _ | Completion_authority_rejected _
        | Task_outcome _ | Task_cancelled _ | Workspace_message _ | Delegate_completed _
        | Composition_completed _ | Tool_result_ready _ | Owned_job_completed _ ->
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
      let grouped_schedule =
        match stimulus.payload with
        | Keeper_event_queue.Schedule_due wake ->
          Option.map (fun members -> wake, members) (schedule_group wake.schedule_id)
        | Keeper_event_queue.Bootstrap | Keeper_event_queue.Board_routing_pending _ | Keeper_event_queue.Board_signal _
        | Keeper_event_queue.Board_attention _ | Keeper_event_queue.Fusion_completed _
        | Keeper_event_queue.Connector_attention _ | Keeper_event_queue.Hitl_resolved _
        | Keeper_event_queue.Ask_answered _ | Keeper_event_queue.Completion_authority_rejected _
        | Keeper_event_queue.Task_cancelled _ | Keeper_event_queue.Workspace_message _
        | Keeper_event_queue.Delegate_completed _ | Keeper_event_queue.Composition_completed _ | Keeper_event_queue.Tool_result_ready _ | Keeper_event_queue.Owned_job_completed _
        | Keeper_event_queue.Task_outcome _ -> None
      in
      (match grouped_schedule with
       | Some (wake, _) when String_set.mem wake.schedule_id !schedules_emitted ->
         (* Already represented by the schedule's aggregate row. *)
         go (queue_index + 1) acc rest
       | Some (wake, members) ->
         schedules_emitted := String_set.add wake.schedule_id !schedules_emitted;
         let count = List.length members in
         let oldest_arrived_at, first_due, last_due =
           List.fold_left
             (fun (oldest, first, last)
                  ((member_wake : Keeper_event_queue.scheduled_wake), (member : Keeper_event_queue_state.pending_selection)) ->
                ( Float.min oldest member.source.arrived_at
                , Float.min first member_wake.due_at
                , Float.max last member_wake.due_at ))
             (stimulus.arrived_at, wake.due_at, wake.due_at)
             members
         in
         (* Every member's exact address, in due order, so the operator
            boundary can cancel or reprioritize any one of them from this row. *)
         let member_addresses =
           members
           |> List.sort (fun ((a : Keeper_event_queue.scheduled_wake), _) ((b : Keeper_event_queue.scheduled_wake), _) ->
                Float.compare a.due_at b.due_at)
           |> List.map (fun ((member_wake : Keeper_event_queue.scheduled_wake), (member : Keeper_event_queue_state.pending_selection)) ->
                `Assoc
                  [ ( "source_ref"
                    , `String (Keeper_event_queue_state.source_snapshot_ref member.source) )
                  ; ( "source_incarnation"
                    , `String (Int64.to_string member.admitted_revision) )
                  ; "due_at_unix", `Float member_wake.due_at
                  ])
         in
         go
           (queue_index + 1)
           (row
              ~what:
                (Printf.sprintf
                   "%s ×%d%s"
                   (queue_payload_what stimulus.payload)
                   count
                   (urgency_what_suffix stimulus.urgency))
              ~since:(Some oldest_arrived_at)
              ~detail:
                (`Assoc
                   (base_detail
                    @ [ ("group_count", `Int count)
                      ; ("group_first_due_unix", `Float first_due)
                      ; ("group_last_due_unix", `Float last_due)
                      ; ("group_members", `List member_addresses)
                      ]))
              :: acc)
           rest
       | None ->
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
       | Keeper_event_queue.Bootstrap | Keeper_event_queue.Board_routing_pending _ | Keeper_event_queue.Board_signal _
       | Keeper_event_queue.Board_attention _ | Keeper_event_queue.Fusion_completed _
       | Keeper_event_queue.Schedule_due _ | Keeper_event_queue.Hitl_resolved _
       | Keeper_event_queue.Ask_answered _ | Keeper_event_queue.Completion_authority_rejected _
       | Keeper_event_queue.Task_cancelled _ | Keeper_event_queue.Workspace_message _
       | Keeper_event_queue.Delegate_completed _ | Keeper_event_queue.Composition_completed _ | Keeper_event_queue.Tool_result_ready _ | Keeper_event_queue.Owned_job_completed _
       | Keeper_event_queue.Task_outcome _ | Connector_attention _ -> go
           (queue_index + 1)
           (row
              ~what:(stimulus_what stimulus)
              ~since:(Some stimulus.arrived_at)
              ~detail:(`Assoc base_detail)
              :: acc)
           rest))
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

(* One read of the Keeper's durable queue yields both the rows and how long the
   oldest entry has been queued. A row's [since] is the source's own arrival
   time (for an answered ask, the answer time), so it cannot say how long the
   entry has waited in the queue; the residence comes from the durable first
   admission time instead. *)
let event_queue_observation ~now ~base_path ~keeper_name =
  let snapshot =
    Keeper_event_queue_persistence.load_selections_with_errors ~base_path ~keeper_name
  in
  let rows =
    rows_for_queue_snapshot
      ~keeper_name
      ~source:Event_queue_pending
      ~next_action:"keeper_drain_event_queue"
      snapshot.pending
    @ queue_read_error_rows ~keeper_name snapshot.read_errors
  in
  let queue_residence =
    Keeper_event_queue_persistence.queue_residence_of_selections
      ~now
      ~complete:(snapshot.read_errors = [])
      snapshot.pending
  in
  rows, queue_residence
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
          ; what = Printf.sprintf "대화 요청 %d건 대기" projection.queued_count
          ; wake_producer = Keeper_owner_actor
          ; since = projection.oldest_queued_created_at
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
          ; what = "진행 중인 대화 요청"
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

let shutdown_waiting_guidance (operation : Keeper_shutdown_types.t) =
  let open Keeper_shutdown_types in
  match operation.phase with
  | Prepared | Joining_lanes | Joined_idle | Finalizing_tasks _ | Cleanup_ready _ ->
    "종료 정리 진행 대기", "wait_for_keeper_shutdown"
  | Reconciliation_required _ ->
    "종료 전 실행 결과 확인 필요", "inspect_keeper_shutdown_reconciliation"
  | Blocked _ ->
    "종료 정리 막힘 · 수동 확인 필요", "inspect_blocked_keeper_shutdown"
  | Finalized { completion = (Completion_pending _ | Completion_delivery_failed _); _ } ->
    (match operation.cleanup_intent.reason with
     | Dashboard_keeper_purge _ ->
       "종료 후 정리 결과 전달 재시도 필요", "retry_keeper_shutdown_completion"
     | Operator_stop_retain_meta | Operator_stop_remove_meta | Supervisor_cleanup ->
       "종료 후 정리 결과 확인 필요", "inspect_keeper_shutdown_completion")
  | Finalized { completion = (Completion_not_requested | Completion_delivered _); _ }
  | Owner_absent _ | Operator_absence_acknowledged _ | Superseded _ ->
    "종료 기록과 진입 차단 상태 확인 필요", "inspect_keeper_shutdown_fence"
;;

let owner_shutdown_rows ~config keeper_name =
  let base_path = config.Workspace.base_path in
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
      let operation_reading =
        Keeper_shutdown_store.load ~config ~keeper_name operation_id
      in
      (* The fence alone grants no finalization capability. In particular a
         blocked or effect-unknown operation cannot be replayed as cleanup.
         This is an observation; an eventual action must recheck its guards. *)
      let what, next_action, operation_detail, errors =
        match operation_reading with
        | Ok operation ->
          let what, next_action = shutdown_waiting_guidance operation in
          let failure_detail =
            match operation.phase with
            | Keeper_shutdown_types.Blocked failure ->
              [ "failure_stage", `String (Keeper_shutdown_types.failure_stage_to_string failure.stage)
              ; "failure_detail", `String failure.detail ]
            | Prepared | Joining_lanes | Joined_idle | Finalizing_tasks _
            | Cleanup_ready _ | Reconciliation_required _ | Finalized _
            | Owner_absent _ | Operator_absence_acknowledged _ | Superseded _ -> []
          in
          what, next_action,
          [ "shutdown_phase", `String (Keeper_shutdown_types.phase_to_string operation.phase)
          ; "shutdown_revision", `Int operation.revision ] @ failure_detail,
          []
        | Error error ->
          "종료 기록 확인 필요", "inspect_keeper_shutdown_record",
          [ "shutdown_phase", `Null; "shutdown_revision", `Null ],
          [ read_error_row ~keeper_name ~waiting_on:"keeper_shutdown_operation"
              ~next_action:"inspect_keeper_shutdown_record"
              (`Assoc
                [ "shutdown_operation_id", `String (Keeper_shutdown_types.Operation_id.to_string operation_id)
                ; "error", `String (Keeper_shutdown_store.error_to_string error) ]) ]
      in
      [ { keeper_name = Some keeper_name
        ; source = Owner_shutdown
        ; waiting_on = "shutdown"
        ; what
        ; wake_producer = Keeper_owner_actor
        ; since = None
        ; due_at = None
        ; next_action
        ; detail =
            `Assoc
              ([ ( "shutdown_operation_id"
                , `String
                    (Keeper_shutdown_types.Operation_id.to_string operation_id) )
              ; "admission_fenced", `Bool true
              ; "in_flight", in_flight_detail
              ] @ operation_detail)
        }
      ] @ errors
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
          ; ( "phase"
            , Keeper_approval_queue_rules_types.approval_queue_phase_to_yojson
                (Keeper_approval_queue_rules_types.phase_of_disposition_and_summary
                   ~disposition:entry.summary_attempt_disposition
                   ~summary_status:entry.summary_status) )
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
  match Keeper_external_attention.store_read_error ~base_path ~keeper_name with
  | None -> []
  | Some err ->
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

let pending_confirm_keeper_target
      (entry : Workspace_hooks.operator_pending_confirm_request)
  =
  match Operator_action_constants.target_type_of_string entry.target_type, entry.target_id with
  | Some Keeper, Some keeper_name ->
    Some keeper_name
  | (Some Workspace | Some Goal | None), _ | Some Keeper, None -> None
;;

let scope_includes_actor ~keeper_name actor_id =
  match keeper_name, actor_id with
  | None, _ | Some _, None -> true
  | Some requested, Some owner -> String.equal requested owner
;;

let pending_confirm_rows keeper_names pending_confirms =
  let keeper_set = Set_util.StringSet.of_list keeper_names in
  pending_confirms
  |> List.filter_map (fun (entry : Workspace_hooks.operator_pending_confirm_request) ->
    match pending_confirm_keeper_target entry with
    | Some keeper_name when Set_util.StringSet.mem keeper_name keeper_set ->
      Some (pending_confirm_row ~keeper_name entry)
    | Some _ | None -> None)
;;

let global_pending_confirm_rows ?keeper_name keeper_names pending_confirms =
  let keeper_set = Set_util.StringSet.of_list keeper_names in
  pending_confirms
  |> List.filter (fun entry ->
    scope_includes_actor ~keeper_name (pending_confirm_keeper_target entry))
  |> List.filter_map (fun entry ->
    match pending_confirm_keeper_target entry with
    | Some target when Set_util.StringSet.mem target keeper_set -> None
    | Some _ | None -> Some (pending_confirm_row entry))
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

let schedule_keeper_owner keeper_set request =
  (* A fleet inventory counts each reservation once, preferring its creator.
     A scoped inventory contains only its selected Keeper, so a wake target
     receives the same reservation locally even when another Keeper made it. *)
  Schedule_payload_projection.keeper_participants request
  |> List.find_opt (fun name -> Set_util.StringSet.mem name keeper_set)
;;

let schedule_rows ?keeper_name ~keeper_names state =
  let keeper_set = Set_util.StringSet.of_list keeper_names in
  state.Schedule_store.schedules
  |> List.filter (fun request ->
    schedule_active request
    && Schedule_payload_projection.visible_to_keeper keeper_name request)
  |> List.map (fun (request : Schedule_domain.schedule_request) ->
    { keeper_name = schedule_keeper_owner keeper_set request
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
          ; "keeper_participants",
            `List (List.map (fun name -> `String name)
              (Schedule_payload_projection.keeper_participants request))
          ; "status", `String (Schedule_domain.schedule_status_to_string request.status)
          ; "payload_digest", `String (Schedule_domain.payload_digest request.payload)
          ; ( "payload_kind"
            , match Schedule_payload_projection.kind request with
              | None -> `Null
              | Some kind -> `String kind )
          ]
    })
;;

let schedule_rows_of_observation ?keeper_name ~keeper_names observation =
  match observation with
  | Ok (state, _source) -> schedule_rows ?keeper_name ~keeper_names state
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

let pending_confirm_observation_rows ~before ~after =
  let status = Pending_confirm_observation.status after in
  let detail =
    match status with
    | Pending_confirm_observation.Not_managed | Pending_confirm_observation.Observed
      when Pending_confirm_observation.same_revision before after -> None
    | Pending_confirm_observation.Not_managed | Pending_confirm_observation.Observed ->
        Some ("changed_during_read", "운영자 확인을 읽는 중 변경됨", "wait_for_observation_recovery", false)
    | Pending_confirm_observation.Initializing ->
        Some ("initializing", "운영자 확인 관측 준비 중", "wait_for_observation_recovery", false)
    | Pending_confirm_observation.Source_unavailable ->
        Some ("source_unavailable", "운영자 확인 기록 관측 불가", "wait_for_observation_recovery", false)
    | Pending_confirm_observation.Deadline_unavailable ->
        Some ("deadline_unavailable", "운영자 확인 기한 관측 불가", "wait_for_observation_recovery", false)
    | Pending_confirm_observation.Workspace_unobserved ->
        Some ("workspace_unobserved", "이 workspace의 운영자 확인을 관측하지 않음", "switch_to_workspace", true)
    | Pending_confirm_observation.Scope_unavailable ->
        Some ("scope_unavailable", "운영자 확인의 workspace 경로를 확인할 수 없음", "repair_workspace_path", true)
  in
  match detail with
  | None -> [], false
  | Some (kind, what, next_action, action_required) ->
      ( [ { keeper_name = None
        ; source = Observation_unavailable
        ; waiting_on = "operator_pending_confirm_observer"
        ; what
        ; wake_producer = Read_model_reader
        ; since = None
        ; due_at = None
        ; next_action
        ; detail = `Assoc [ "kind", `String kind ]
        } ]
      , action_required )
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

(* A row from one of these sources means the Keeper's own work is put off
   until that source finishes; any other row is something it waits on. *)
let defers (row : waiting_row) =
  match row.source with
  | Fusion_running | Owner_shutdown -> true
  | Event_queue_pending | Chat_operation_queued | Chat_operation_running
  | Hitl_pending | Schedule_waiting | Operator_pending_confirm
  | Runtime_quota_spent | Read_error | Observation_unavailable -> false
;;

let row_state rows =
  if List.exists defers rows
  then Deferred
  else if rows <> []
  then Waiting
  else Idle
;;

(* The sources that put a Keeper in its state, each once, in row order: the
   deferring sources of a deferred Keeper, every source of a waiting one, and
   none for an idle or busy one. A reader shows the state with these beside
   it and does not pick them out of the rows itself. *)
let state_sources state rows =
  let distinct rows =
    List.fold_left
      (fun sources (row : waiting_row) ->
         if List.mem row.source sources then sources else sources @ [ row.source ])
      []
      rows
  in
  match state with
  | Idle | Busy -> []
  | Waiting -> distinct rows
  | Deferred -> distinct (List.filter defers rows)
;;

let keeper_state ~busy rows =
  if busy then Busy else row_state rows
;;

let source_counts rows =
  rows
  |> List.fold_left
       (fun counts row ->
          let key = source_to_string row.source in
          let prev =
            Option.value
              ~default:0
              (Keeper_registry.StringMap.find_opt key counts)
          in
          Keeper_registry.StringMap.add key (prev + 1) counts)
       Keeper_registry.StringMap.empty
  |> Keeper_registry.StringMap.bindings
  |> List.map (fun (source, count) -> source, `Int count)
;;

let busy_keeper_names ~base_path =
  Keeper_registry.all ~base_path ()
  |> List.fold_left
       (fun acc (entry : Keeper_registry.registry_entry) ->
          match Keeper_composite_observer.live_turn_observation entry with
          | Some _ -> Set_util.StringSet.add entry.name acc
          | None -> acc)
       Set_util.StringSet.empty
;;

let keeper_is_busy busy_names keeper_name =
  Set_util.StringSet.mem keeper_name busy_names
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
              (fun total (_keeper_name, busy, _queue_residence, rows) ->
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
         (fun (_keeper_name, _busy, _queue_residence, rows) -> rows)
         per_keeper)
  in
  record_scope_metrics ~now ~scope:"keeper" all_keeper_rows;
  record_scope_metrics ~now ~scope:"global" global_rows;
  record_keeper_state_metrics per_keeper
;;

let current_execution_json ~base_path keeper_name =
  match Keeper_registry.get ~base_path keeper_name with
  | Some entry when Option.is_some (Keeper_composite_observer.live_turn_observation entry) ->
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
  | None | Some _ -> `Null
;;

let source_next_actions rows =
  rows
  |> List.fold_left
       (fun actions row ->
          let source = source_to_string row.source in
          let rev_current =
            match Keeper_registry.StringMap.find_opt source actions with
            | None -> []
            | Some values -> values
          in
          if List.mem row.next_action rev_current
          then actions
          else
            Keeper_registry.StringMap.add
              source
              (row.next_action :: rev_current)
              actions)
       Keeper_registry.StringMap.empty
  |> Keeper_registry.StringMap.bindings
  |> List.map (fun (source, rev_actions) ->
    source, `List (List.map (fun action -> `String action) (List.rev rev_actions)))
;;

let keeper_json ~base_path keeper_name ~busy ~queue_residence rows =
  let paused =
    match Keeper_owner_registry.get ~base_path ~keeper_name with
    | Error _ -> None
    | Ok owner -> Option.map (fun meta -> meta.Keeper_meta_contract.paused)
        (Keeper_owner.projection owner).meta
  in
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
    ; "paused", Option.fold ~none:`Null ~some:(fun value -> `Bool value) paused
    ; "state", `String (keeper_state_to_string state)
    ; ( "state_sources"
      , `List
          (List.map
             (fun source -> `String (source_to_string source))
             (state_sources state rows)) )
    ; "waiting_on", `List (List.map waiting_row_json rows)
    ; "waiting_count", `Int (List.length rows)
    ; "sources", `Assoc (source_counts rows)
    ; "since", Json_util.float_opt_to_json since
    ; "since_iso", unix_iso_json since
    ; "due_at", Json_util.float_opt_to_json due_at
    ; "due_at_iso", unix_iso_json due_at
    ; "source_next_actions", `Assoc (source_next_actions rows)
    ; ( "queue_residence"
      , Keeper_event_queue_persistence.queue_residence_to_yojson queue_residence )
    ; "current_execution", current_execution_json ~base_path keeper_name
    ]
;;

(* One candidate of a Keeper's route whose quota window is spent, with the
   reset the provider stated, if it stated one. *)
type spent_candidate =
  { runtime_id : string
  ; resets_at : float option
  }

(* The route's candidates when every one of them has spent its quota window
   (RFC-0484 §3.1), else [None]. Only the quota window counts: a 429 rest
   and a failed-attempt mark end by themselves, so a route resting on them is
   not one the operator has to change. A candidate the runtime table does not
   resolve says nothing about a quota, so it keeps the route out. *)
let spent_route_candidates ~now route =
  match Runtime.resolve_assignment route with
  | `Unavailable _ | `Missing -> None
  | `Lane lane ->
    let rec all_spent acc = function
      | [] -> Some (List.rev acc)
      | runtime_id :: rest ->
        (match Runtime.get_runtime_by_id runtime_id with
         | None -> None
         | Some runtime ->
           let scope = Runtime_instance.quota_scope_of_runtime runtime in
           if Runtime_quota_window.is_exhausted ~scope ~now
           then
             all_spent
               ({ runtime_id; resets_at = Runtime_quota_window.active_until ~scope ~now } :: acc)
               rest
           else None)
    in
    (match Runtime_lane.ordered_candidates lane with
     | [] -> None
     | candidates -> all_spent [] candidates)
;;

(* The first stated reset: the Keeper can dispatch again then. A candidate
   whose provider stated no reset adds no time: its rest ends at MASC's own
   cap, and the provider may still refuse it then. *)
let earliest_stated_reset spent =
  List.fold_left
    (fun earliest candidate ->
       match earliest, candidate.resets_at with
       | None, stated -> stated
       | Some at, None -> Some at
       | Some at, Some stated -> Some (Float.min at stated))
    None
    spent
;;

(* A running Keeper whose every candidate has spent its quota cannot dispatch
   until a window resets. The row names the earliest stated reset. The walk
   can release later than that, and the roster row's [runtime_path_rest]
   shows when ([Keeper_turn_driver.assignment_walk_rest]). The operator can
   move the Keeper to a route with quota left, which is why this row exists.
   A Keeper the server is not running does not dispatch and is not counted. *)
let runtime_quota_spent_rows ~now ~base_path keeper_name =
  if not (Keeper_registry.is_running ~base_path keeper_name)
  then []
  else
    match Keeper_meta_contract.runtime_route_of_keeper_name keeper_name with
    | None -> []
    | Some route ->
      (match spent_route_candidates ~now route with
       | None -> []
       | Some spent ->
         [ { keeper_name = Some keeper_name
           ; source = Runtime_quota_spent
           ; waiting_on = route
           ; what = Printf.sprintf "모든 후보 한도 소진 · %s" route
           ; wake_producer = Keeper_supervisor
           ; since = None
           ; due_at = earliest_stated_reset spent
           ; next_action = "assign_a_route_with_open_quota"
           ; detail =
               `Assoc
                 [ "route", `String route
                 ; ( "candidates"
                   , `List
                       (List.map
                          (fun candidate ->
                             `Assoc
                               [ "runtime_id", `String candidate.runtime_id
                               ; "resets_at", unix_iso_json candidate.resets_at
                               ])
                          spent) )
                 ]
           }
         ])
;;

let keeper_rows ~now ~config ~pending_approvals ~fusion_runs ~pending_confirms keeper_names =
  let base_path = config.Workspace.base_path in
  keeper_names
  |> List.map (fun keeper_name ->
    let queue_rows, queue_residence =
      event_queue_observation ~now ~base_path ~keeper_name
    in
    let rows =
      queue_rows
      @ chat_operation_rows ~base_path keeper_name
      @ owner_shutdown_rows ~config keeper_name
      @ hitl_rows keeper_name pending_approvals
      @ external_attention_store_error_rows ~base_path ~keeper_name
      @ fusion_rows keeper_name fusion_runs
      @ pending_confirm_rows [ keeper_name ] pending_confirms
      @ runtime_quota_spent_rows ~now ~base_path keeper_name
    in
    keeper_name, queue_residence, rows)
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
      Keeper_approval_queue_result.approval_queue_unavailable_state_json error
  }
;;

type inventory_snapshot =
  { base_path : string
  ; now : float
  ; keeper_names : string list
  ; keeper_count_known : bool
  ; pending_approval_state : Yojson.Safe.t
  ; pending_confirm_count_known : bool
  ; pending_confirm_observation_action_required : bool
  ; global_confirm_count : int
  ; per_keeper :
      (string * bool * Keeper_event_queue_persistence.queue_residence * waiting_row list) list
  ; global_rows : waiting_row list
  ; schedule_observation :
      ((Schedule_store.state * Schedule_store.read_source), Schedule_store.read_error) result
  }

let read_inventory_snapshot ?keeper_name ~read_pending config =
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
         | [] -> Keeper_approval_queue_result.approval_queue_ready_state_json
         | first :: _ ->
           Keeper_approval_queue_result.approval_queue_unavailable_state_json first)
      , List.map pending_approval_read_error pending_approval_store_read_errors )
    | Error error ->
      ( []
      , Keeper_approval_queue_result.approval_queue_unavailable_state_json error
      , [ pending_approval_read_error error ] )
  in
  let fusion_runs = Fusion_run_registry.list_runs (Fusion_run_registry.global ()) in
  let pending_confirm_before = Pending_confirm_observation.read config in
  let pending_confirms, pending_confirm_read_error_rows =
    pending_confirms_or_error_rows config
  in
  let pending_confirm_after = Pending_confirm_observation.read config in
  let pending_confirm_observation_rows, pending_confirm_observation_action_required =
    pending_confirm_observation_rows ~before:pending_confirm_before ~after:pending_confirm_after in
  let schedule_observation = Schedule_store.read_state_observed config in
  let schedule_rows =
    schedule_rows_of_observation ?keeper_name ~keeper_names schedule_observation
  in
  let busy_names = busy_keeper_names ~base_path:config.Workspace.base_path in
  let per_keeper =
    keeper_rows ~now ~config ~pending_approvals ~fusion_runs
      ~pending_confirms keeper_names
    |> List.map (fun (keeper_name, queue_residence, rows) ->
      let rows = rows @ rows_for_keeper keeper_name schedule_rows in
      keeper_name, keeper_is_busy busy_names keeper_name, queue_residence, rows)
  in
  let global_confirm_rows = global_pending_confirm_rows ?keeper_name keeper_names pending_confirms in
  let global_rows =
    global_rows_from schedule_rows
    @ global_confirm_rows
    @ keeper_name_read_error_rows
    @ pending_confirm_read_error_rows
    @ pending_confirm_observation_rows
    @ pending_approval_read_error_rows
  in
  (match keeper_name with
   | None -> record_metrics ~now ~per_keeper ~global_rows
   | Some _ -> ());
  { base_path = config.Workspace.base_path
  ; now
  ; keeper_names
  ; keeper_count_known = keeper_name_read_error_rows = []
  ; pending_approval_state
  ; pending_confirm_count_known =
      pending_confirm_read_error_rows = [] && pending_confirm_observation_rows = []
  ; pending_confirm_observation_action_required
  ; global_confirm_count = List.length global_confirm_rows
  ; per_keeper
  ; global_rows
  ; schedule_observation
  }
;;

let inventory_rows snapshot =
  List.concat_map (fun (_name, _busy, _queue_residence, rows) -> rows) snapshot.per_keeper
  @ snapshot.global_rows
;;

let keeper_json_by_name_snapshot snapshot =
  List.map
    (fun (keeper_name, busy, queue_residence, rows) ->
      ( keeper_name
      , keeper_json ~base_path:snapshot.base_path keeper_name ~busy ~queue_residence rows ))
    snapshot.per_keeper
;;

let keeper_json_by_name config =
  let snapshot =
    read_inventory_snapshot
      ~read_pending:Keeper_approval_queue.list_pending_entries_with_read_errors_for_workspace
      config
  in
  let fleet_read_errors =
    List.filter
      (fun row -> row.source = Read_error || row.source = Observation_unavailable)
      snapshot.global_rows
  in
  let recovery_errors =
    match snapshot.schedule_observation with
    | Ok (_, Recovery_mirror cause) ->
      let waiting_on =
        match cause with
        | Primary_missing -> "schedule_primary_missing"
        | Primary_unusable -> "schedule_primary_unusable"
      in
      [ read_error_row ~waiting_on ~next_action:"repair_schedule_ledger"
          (`Assoc [ "source", `String "recovery_mirror" ]) ]
    | Ok (_, (Uninitialized | Primary_ledger)) | Error _ -> []
  in
  match fleet_read_errors @ recovery_errors with
  | [] -> Ok (keeper_json_by_name_snapshot snapshot)
  | errors -> Error (List.map waiting_row_json errors)
;;

let dashboard_json_of_snapshot snapshot =
  let per_keeper = snapshot.per_keeper in
  let global_rows = snapshot.global_rows in
  let keeper_json_rows = keeper_json_by_name_snapshot snapshot |> List.map snd in
  let all_keeper_rows =
    List.flatten
      (List.map
         (fun (_keeper_name, _busy, _queue_residence, rows) -> rows)
         per_keeper)
  in
  (* One flat list of every pending row across the fleet, so an operator can
     read the whole queue without walking each keeper's nested [waiting_on]
     array. The nested arrays stay for the per-keeper view; this is the same
     rows, not a second summary. *)
  let all_rows = all_keeper_rows @ global_rows in
  let oldest_since =
    all_rows
    |> List.filter_map (fun row -> row.since)
    |> List.fold_left
         (fun acc ts -> match acc with None -> Some ts | Some cur -> Some (min cur ts))
         None
  in
  let oldest_age_seconds =
    match oldest_since with
    | None -> `Null
    | Some ts -> `Float (Float.max 0.0 (snapshot.now -. ts))
  in
  let waiting_keeper_count =
    per_keeper
    |> List.fold_left
         (fun count (_keeper_name, busy, _queue_residence, rows) ->
            match keeper_state ~busy rows with
            | Idle -> count
            | Busy | Waiting | Deferred -> count + 1)
         0
  in
  `Assoc
    [ "schema", `String "masc.dashboard.keeper_waiting_inventory.v4"
    ; "source", `String "server_keeper_waiting_inventory"
    ; "generated_at", `String (Masc_domain.now_iso ())
    ; "supported_states", `List (List.map (fun value -> `String value) [ "idle"; "busy"; "waiting"; "deferred" ])
    ; "keeper_count_known", `Bool snapshot.keeper_count_known
    ; "keeper_count", `Int (List.length snapshot.keeper_names)
    ; "waiting_keeper_count", `Int waiting_keeper_count
    ; "row_count", `Int (List.length all_keeper_rows)
    ; "global_row_count", `Int (List.length global_rows)
    ; "total_row_count", `Int (List.length all_rows)
    ; "oldest_since", Json_util.float_opt_to_json oldest_since
    ; "oldest_since_iso", unix_iso_json oldest_since
    ; "oldest_age_seconds", oldest_age_seconds
    ; ( "global_pending_confirm_count_known"
      , `Bool snapshot.pending_confirm_count_known )
    ; "global_pending_confirm_count", `Int snapshot.global_confirm_count
    ; "pending_approval_state", snapshot.pending_approval_state
    ; "source_counts", `Assoc (source_counts (all_keeper_rows @ global_rows))
    ; "rows", `List (List.map waiting_row_json all_rows)
    ; "keepers", `List keeper_json_rows
    ; "global_waiting_on", `List (List.map waiting_row_json global_rows)
    ]
;;

let dashboard_json_with_pending_reader_scoped ?keeper_name ~read_pending config =
  read_inventory_snapshot ?keeper_name ~read_pending config
  |> dashboard_json_of_snapshot
;;

let dashboard_json_with_pending_reader ~read_pending config =
  dashboard_json_with_pending_reader_scoped
    ~read_pending:(fun ~base_path ->
      read_pending ~base_path |> Result.map (fun entries -> entries, []))
    config
;;

let schedule_health_observation observation =
  let source, known, state, reasons =
    match observation with
    | Ok (state, Schedule_store.Uninitialized) ->
      "uninitialized", true, Some state, []
    | Ok (state, Primary_ledger) -> "primary", true, Some state, []
    | Ok (state, Recovery_mirror cause) ->
      let reason =
        match cause with
        | Primary_missing -> "schedule_primary_missing"
        | Primary_unusable -> "schedule_primary_unusable"
      in
      "recovery", false, Some state, [ reason ]
    | Error (Schedule_store.Corrupt_read_ledger _) ->
      "unreadable", false, None, [ "schedule_ledger_unreadable" ]
  in
  let count = Option.map (fun state -> List.length state.Schedule_store.schedules) state in
  let observed_status_counts =
    match state with
    | None -> `Null
    | Some state ->
      `Assoc
        (List.map
           (fun status ->
             ( Schedule_domain.schedule_status_to_string status
             , `Int
                 (List.fold_left
                    (fun count (request : Schedule_domain.schedule_request) ->
                      if request.status = status then count + 1 else count)
                    0 state.schedules) ))
           Schedule_domain.all_schedule_statuses)
  in
  ( `Assoc
      [ "source", `String source
      ; "counts_known", `Bool known
      ; "schedule_count", (if known then Json_util.int_opt_to_json count else `Null)
      ; "observed_schedule_count", Json_util.int_opt_to_json count
      ; "observed_status_counts", observed_status_counts
      ]
  , known
  , reasons )
;;

let health_json_of_snapshot snapshot =
  let rows = inventory_rows snapshot in
  let read_errors = List.filter (fun row -> row.source = Read_error) rows in
  let observation_errors =
    List.filter (fun row -> row.source = Observation_unavailable) rows in
  (* Keepers that cannot dispatch until a provider resets. The operator can
     move them to a route with quota left, so they are an action reason, and
     the fleet is degraded while they wait (RFC-0484 §3.1). *)
  let quota_spent = List.filter (fun row -> row.source = Runtime_quota_spent) rows in
  let quota_spent_reasons =
    match quota_spent with
    | [] -> []
    | _ :: _ -> [ Printf.sprintf "runtime_quota_spent=%d" (List.length quota_spent) ]
  in
  let schedule_ledger, schedule_known, schedule_reasons =
    schedule_health_observation snapshot.schedule_observation
  in
  let counts_known =
    snapshot.keeper_count_known && read_errors = [] && observation_errors = [] && schedule_known
  in
  let action_reasons =
    schedule_reasons
    @ List.map (fun row -> row.waiting_on ^ "_unreadable") read_errors
    @ (if snapshot.pending_confirm_observation_action_required
       then [ "operator_pending_confirm_observer_unavailable" ] else [])
    @ quota_spent_reasons
    |> List.sort_uniq String.compare
  in
  let reasons =
    action_reasons
    @ List.map (fun row -> row.waiting_on ^ "_unavailable") observation_errors
    |> List.sort_uniq String.compare
  in
  let status =
    match read_errors, observation_errors, snapshot.schedule_observation with
    | _ :: _, _, _ | _, _ :: _, _ | [], [], Error (Corrupt_read_ledger _) -> Health_status.Unavailable
    | [], [], Ok (_, Recovery_mirror _) -> Health_status.Degraded
    | [], [], Ok (_, (Uninitialized | Primary_ledger)) -> Health_status.Ok
  in
  let status =
    match quota_spent with
    | [] -> status
    | _ :: _ -> Health_status.max status Health_status.Degraded
  in
  let work_rows =
    List.filter (fun row -> row.source <> Read_error && row.source <> Observation_unavailable) rows in
  let observed_count = List.length work_rows in
  let reason_json = `List (List.map (fun reason -> `String reason) reasons) in
  `Assoc
    [ "schema", `String "masc.health.keeper_waiting_inventory.v1"
    ; "status", `String (Health_status.to_string status)
    ; "operator_action_required", `Bool (action_reasons <> [])
    ; "status_reasons", reason_json
    ; "operator_action_reasons", `List (List.map (fun reason -> `String reason) action_reasons)
    ; "counts_known", `Bool counts_known
    ; "keeper_count_known", `Bool snapshot.keeper_count_known
    ; "keeper_count",
      (if snapshot.keeper_count_known
       then `Int (List.length snapshot.keeper_names) else `Null)
    ; "total_row_count", (if counts_known then `Int observed_count else `Null)
    ; "observed_row_count", `Int observed_count
    ; "observed_source_counts", `Assoc (source_counts work_rows)
    ; "read_error_count", `Int (List.length read_errors)
    ; "observation_error_count", `Int (List.length observation_errors)
    ; "read_errors",
      `List
        (List.map
           (fun row ->
             `Assoc
               [ "keeper_name", Json_util.string_opt_to_json row.keeper_name
               ; "waiting_on", `String row.waiting_on
               ; "next_action", `String row.next_action
               ])
           read_errors)
    ; "schedule_ledger", schedule_ledger
    ]
;;

let health_placeholder ~status =
  `Assoc
    [ "schema", `String "masc.health.keeper_waiting_inventory.v1"
    ; "status", `String (Health_status.to_string status)
    ; "status_reasons", `List [ `String "inventory_not_observed" ]
    ; "operator_action_required", `Bool (Health_status.requires_operator_action status)
    ; "counts_known", `Bool false
    ; "keeper_count_known", `Bool false
    ; "keeper_count", `Null
    ; "total_row_count", `Null
    ; "observed_row_count", `Null
    ; "observed_source_counts", `Null
    ; "read_error_count", `Null
    ; "observation_error_count", `Null
    ; "read_errors", `Null
    ; "schedule_ledger", `Null
    ]
;;

let compute_health_json read_snapshot =
  match read_snapshot () |> health_json_of_snapshot with
  | json -> json
  | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
  | exception exn ->
    Log.Misc.warn "waiting inventory health observation failed: %s"
      (Printexc.to_string exn);
    health_placeholder ~status:Health_status.Error
;;

let health_json_with_pending_reader ~read_pending config =
  compute_health_json (fun () ->
    read_inventory_snapshot
      ~read_pending:(fun ~base_path ->
        read_pending ~base_path |> Result.map (fun entries -> entries, []))
      config)
;;

let health_json config =
  compute_health_json (fun () ->
    read_inventory_snapshot
      ~read_pending:
        Keeper_approval_queue.list_pending_entries_with_read_errors_for_workspace
      config)
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
  let health_json_with_pending_reader = health_json_with_pending_reader

  let dashboard_json_with_pending_reader = dashboard_json_with_pending_reader


  let rows_for_queue_snapshot = rows_for_queue_snapshot
end
