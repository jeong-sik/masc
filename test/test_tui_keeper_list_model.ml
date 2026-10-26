module Model = Masc_tui_keeper_list_model
module Decode = Masc.Tui_decode
module Control = Masc_tui_keeper_control

let runtime health name : Decode.keeper_runtime =
  { kr_name = name
  ; kr_identity = Ok { k_trace_id = "trace-" ^ name; k_created_at = "2026-01-01T00:00:00Z"; k_updated_at = "2026-01-01T00:00:00Z" }
  ; kr_portrait = Decode.Unavailable "test"
  ; kr_candle_balance_milli = None
  ; kr_candle_account_revision = Ok None
  ; kr_health = health
  ; kr_paused = false
  ; kr_next_action = None
  ; kr_keepalive_running = true
  ; kr_activation_mode = Decode.Activation_autonomous
  ; kr_runtime_id = "test.runtime"
  ; kr_phase = Option.get (Decode.keeper_phase_of_string "running")
  ; kr_sandbox_profile = "docker"
  ; kr_runtime_blocker_summary = None
  ; kr_last_failure = None
  ; kr_runtime_blocker_signature = None
  ; kr_runtime_lane_observation = None
  }

let keeper name : Decode.keeper =
  { k_origin = Decode.Persisted_keeper
  ; k_name = name
  ; k_paused = false
  ; k_identity = Error "not needed"
  ; k_activity = None
  }

let turn activity : Decode.keeper_turn_state =
  Decode.Keeper_turn_running
    { lane = Decode.Turn_lane_autonomous
    ; started_at_unix = 1.
    ; interrupt_token = "token"
    ; turn_ref = None
    ; preview = Some
        { ktp_text_position = { kpp_generation = 0; kpp_start_byte = 0 }
        ; ktp_status_text = "active"
        ; ktp_activity = Some activity
        ; ktp_updated_at_unix = 2.
        ; ktp_text_tail = ""
        ; ktp_last_tool = None
        ; ktp_preparation = None
        ; ktp_preparation_timeline = None
        ; ktp_execution_scope = None
        }
    }

let waiting_item ?(source = Model.Waiting_source_event_queue_pending)
    ?(producer = Model.Wake_keeper_owner_actor) ?(since = Some 10.) () : Decode.waiting_item =
  { kwi_source = source
  ; kwi_waiting_on = "queue-1"
  ; kwi_what = "waiting fixture"
  ; kwi_wake_producer = producer
  ; kwi_since = since
  ; kwi_due_at = None
  ; kwi_next_action = "resume"
  }

let waiting ?(state = Model.Keeper_waiting_blocked) ?(items = []) name : Decode.keeper_waiting_row =
  { kwr_keeper_name = name
  ; kwr_state = state
  ; kwr_waiting_count = List.length items
  ; kwr_since = None
  ; kwr_due_at = None
  ; kwr_waiting_on = items
  }

let approval name : Decode.keeper_tool_approval =
  { kta_keeper = name
  ; kta_tool_call_id = "call-1"
  ; kta_tool = "Execute"
  ; kta_args = "{}"
  ; kta_question = "May I?"
  ; kta_because = None
  ; kta_asked_at = 1.
  ; kta_timeout_sec = 10.
  }

let verification_task name : Decode.task =
  { id = "task-" ^ name
  ; title = "verify " ^ name
  ; status = Masc_domain.AwaitingVerification
      { assignee = name; started_at = "1"; submitted_at = "2"; verification_id = "verification-1" }
  ; priority = 3
  ; goal_ids = []
  }

let async_request ?(ownership = Decode.Async_runtime_owned) phase id : Decode.async_request_row =
  { ar_request_id = id
  ; ar_submitted_by = "test"
  ; ar_keeper_name = "row"
  ; ar_phase = phase
  ; ar_elapsed_sec = Some 1.
  ; ar_ownership = ownership
  }

let row ?(last_activity_at = Some 0.) ?turn ?waiting ?approval ?task
    ?(open_questions = 0) ?(async_requests = []) ?(paused = false) ?health name : Model.row =
  let liveness = match health with
    | None -> Control.Unobserved
    | Some health -> Control.Present (runtime health name)
  in
  { keeper = keeper name
  ; reading = { Control.name = name; paused = paused; liveness = liveness }
  ; turn
  ; waiting
  ; approval
  ; task
  ; open_questions
  ; async_requests
  ; last_activity_at
  }

let name (row : Model.row) = row.keeper.Decode.k_name
let names rows = List.map name rows
let health raw = Option.get (Decode.keeper_health_of_string raw)
let streaming = turn Masc.Keeper_turn_preview.Receiving_response
let preparing = turn Masc.Keeper_turn_preview.Preparing
let model_waiting = turn Masc.Keeper_turn_preview.Awaiting_response
let tool_waiting = turn Masc.Keeper_turn_preview.Tool_observed

let test_cycles () =
  Alcotest.(check bool) "compact to detailed" true (Model.next_layout Model.Compact = Model.Detailed);
  Alcotest.(check bool) "detailed to grouped" true (Model.next_layout Model.Detailed = Model.Grouped);
  Alcotest.(check bool) "grouped to compact" true (Model.next_layout Model.Grouped = Model.Compact);
  Alcotest.(check bool) "priority to recent" true (Model.next_sort Model.Priority = Model.Recent);
  Alcotest.(check bool) "recent to name" true (Model.next_sort Model.Recent = Model.Name);
  Alcotest.(check bool) "name to priority" true (Model.next_sort Model.Name = Model.Priority)

let test_priority_orders_attention_activity_waiting_then_inactive () =
  let rows =
    [ row ~last_activity_at:(Some 70.) "unknown"
    ; row ~last_activity_at:(Some 80.) ~waiting:(waiting "delegate") ~turn:model_waiting "model"
    ; row ~last_activity_at:(Some 90.) ~turn:streaming "stream"
    ; row ~last_activity_at:(Some 100.) ~approval:(approval "held") "held"
    ; row ~last_activity_at:(Some 70.) ~turn:Decode.Keeper_turn_idle ~waiting:(waiting ~state:Model.Keeper_waiting_idle "idle") "idle"
    ; row ~last_activity_at:(Some 100.) ~open_questions:1 "question"
    ; row ~last_activity_at:(Some 80.) ~waiting:(waiting "verify") ~task:(verification_task "verify") "verify"
    ; row ~last_activity_at:(Some 90.)
        ~async_requests:[async_request Decode.Async_running "a"; async_request ~ownership:Decode.Async_ownership_unknown Decode.Async_running "b"] "async"
    ; row ~last_activity_at:(Some 100.) ~health:(health "failing") "failure"
    ; row ~last_activity_at:(Some 70.) ~paused:true "paused"
    ; row ~last_activity_at:(Some 80.)
        ~waiting:(waiting ~items:[waiting_item ~producer:Model.Wake_keeper_delegate ()] "delegate") "delegate"
    ]
  in
  Alcotest.(check (list string)) "attention, activity, waiting, inactive"
    [ "failure"; "held"; "question"; "async"; "stream"; "delegate"; "model"; "verify"; "idle"; "paused"; "unknown" ]
    (names (Model.order_rows ~sort:Model.Priority rows))

let test_recent_and_name_have_deterministic_ties () =
  let rows =
    [ row ~last_activity_at:None "unknown"
    ; row ~last_activity_at:(Some 10.) "beta"
    ; row ~last_activity_at:(Some 1.) "old"
    ; row ~last_activity_at:(Some 10.) "alpha"
    ]
  in
  Alcotest.(check (list string)) "recent descending, name tie, unknown last"
    [ "alpha"; "beta"; "old"; "unknown" ] (names (Model.order_rows ~sort:Model.Recent rows));
  Alcotest.(check (list string)) "name ignores activity"
    [ "alpha"; "beta"; "old"; "unknown" ] (names (Model.order_rows ~sort:Model.Name rows));
  let duplicates = [ row ~last_activity_at:(Some 10.) "same-a"; row ~last_activity_at:(Some 10.) "same-b" ] in
  Alcotest.(check (list string)) "identical sort keys remain stable"
    [ "same-a"; "same-b" ] (names (Model.order_rows ~sort:Model.Recent duplicates))

let test_streaming_keeps_async_and_schedule_badges () =
  let value =
    row ~turn:streaming
      ~async_requests:
        [ async_request Decode.Async_running "a"
        ; async_request ~ownership:Decode.Async_ownership_unknown Decode.Async_running "b"
        ]
      ~waiting:(waiting ~items:[waiting_item ~source:Model.Waiting_source_schedule_waiting ()] "row")
      "row"
  in
  Alcotest.(check bool) "the turn remains primary" true
    (Model.primary_activity_of_row value = Model.Streaming);
  Alcotest.(check bool) "the row is active" true (Model.group_of_row value = Model.Active);
  let badges = Model.badges_of_row value in
  Alcotest.(check bool) "both async requests and ownership uncertainty survive" true
    (List.mem (Model.Badge_async { running = 2; ownership_unknown = 1 }) badges);
  Alcotest.(check bool) "the scheduled wake remains a secondary badge" true
    (List.mem Model.Badge_schedule badges)

let test_delegate_and_verification_remain_distinct_badges () =
  let value =
    row ~task:(verification_task "row")
      ~waiting:(waiting ~items:[waiting_item ~producer:Model.Wake_keeper_delegate ()] "row")
      "row"
  in
  Alcotest.(check bool) "delegation is primary without an active turn" true
    (Model.primary_activity_of_row value = Model.Delegating);
  Alcotest.(check bool) "delegation waits" true (Model.group_of_row value = Model.Waiting);
  let badges = Model.badges_of_row value in
  Alcotest.(check bool) "delegation badge" true (List.mem Model.Badge_delegate badges);
  Alcotest.(check bool) "verification badge" true (List.mem Model.Badge_verification badges)

let test_unobserved_is_not_idle () =
  let unknown = row "unknown" in
  let idle = row ~turn:Decode.Keeper_turn_idle ~waiting:(waiting ~state:Model.Keeper_waiting_idle "idle") "idle" in
  Alcotest.(check bool) "unknown remains unknown" true (Model.primary_activity_of_row unknown = Model.Unknown);
  Alcotest.(check bool) "observed idle remains idle" true (Model.primary_activity_of_row idle = Model.Idle);
  Alcotest.(check bool) "unknown and idle share only the inactive bucket" true
    (Model.group_of_row unknown = Model.Inactive && Model.group_of_row idle = Model.Inactive)

let test_paused_and_offline_hide_stale_activity () =
  let paused = row ~paused:true ~turn:streaming "paused" in
  let offline = row ~health:(health "offline") ~turn:streaming "offline" in
  Alcotest.(check bool) "paused wins over stale streaming" true
    (Model.primary_activity_of_row paused = Model.Paused && Model.group_of_row paused = Model.Inactive);
  Alcotest.(check bool) "offline wins over stale streaming" true
    (Model.primary_activity_of_row offline = Model.Offline && Model.group_of_row offline = Model.Inactive)

let test_confirmation_and_inventory_errors_need_attention () =
  let confirmation =
    row ~waiting:(waiting ~items:[waiting_item ~source:Model.Waiting_source_operator_pending_confirm ()] "row") "confirmation"
  in
  let failure = row ~waiting:(waiting ~items:[waiting_item ~source:Model.Waiting_source_read_error ()] "row") "failure" in
  Alcotest.(check bool) "operator confirmation needs a person" true
    (Model.primary_activity_of_row confirmation = Model.Confirmation && Model.group_of_row confirmation = Model.Needs_you);
  Alcotest.(check bool) "inventory failure needs repair" true
    (Model.primary_activity_of_row failure = Model.Failure && Model.group_of_row failure = Model.Needs_you);
  Alcotest.(check bool) "the failure badge remains explicit" true
    (List.mem Model.Badge_read_error (Model.badges_of_row failure))

let test_async_phases_and_preparing_remain_distinct () =
  let active = row ~turn:preparing "preparing" in
  let queued = row ~async_requests:[async_request Decode.Async_queued "queued"] "queued" in
  let cancelling = row ~async_requests:[async_request Decode.Async_cancelling "cancelling"] "cancelling" in
  let tool = row ~turn:tool_waiting "tool" in
  Alcotest.(check bool) "preparing is active" true
    (Model.primary_activity_of_row active = Model.Preparing && Model.group_of_row active = Model.Active);
  Alcotest.(check bool) "queued async waits" true (Model.group_of_row queued = Model.Waiting);
  Alcotest.(check bool) "cancelling async waits" true (Model.group_of_row cancelling = Model.Waiting);
  Alcotest.(check bool) "queued and cancelling badges do not become running" true
    (List.mem (Model.Badge_async_queued 1) (Model.badges_of_row queued)
     && List.mem (Model.Badge_async_cancelling 1) (Model.badges_of_row cancelling)
     && not (List.exists (function Model.Badge_async _ -> true | _ -> false) (Model.badges_of_row queued)));
  Alcotest.(check bool) "a synchronous tool wait is waiting" true
    (Model.primary_activity_of_row tool = Model.Tool_waiting && Model.group_of_row tool = Model.Waiting)

let test_group_counts () =
  let rows =
    [ row ~approval:(approval "held") "held"
    ; row ~turn:streaming "active"
    ; row ~turn:model_waiting "waiting"
    ; row "unknown"
    ]
  in
  Alcotest.(check bool) "counts use the same classification" true
    (Model.group_counts rows = (1, 1, 1, 1))

let () =
  Alcotest.run "tui_keeper_list_model"
    [ ( "decisions"
      , [ Alcotest.test_case "layout and sort cycles" `Quick test_cycles
        ; Alcotest.test_case "priority order" `Quick test_priority_orders_attention_activity_waiting_then_inactive
        ; Alcotest.test_case "recent and name ordering" `Quick test_recent_and_name_have_deterministic_ties
        ; Alcotest.test_case "streaming keeps async and schedule badges" `Quick test_streaming_keeps_async_and_schedule_badges
        ; Alcotest.test_case "delegate and verification badges" `Quick test_delegate_and_verification_remain_distinct_badges
        ; Alcotest.test_case "unobserved is not idle" `Quick test_unobserved_is_not_idle
        ; Alcotest.test_case "paused and offline hide stale activity" `Quick test_paused_and_offline_hide_stale_activity
        ; Alcotest.test_case "confirmation and inventory errors need attention" `Quick test_confirmation_and_inventory_errors_need_attention
        ; Alcotest.test_case "async phases and preparing remain distinct" `Quick test_async_phases_and_preparing_remain_distinct
        ; Alcotest.test_case "group counts" `Quick test_group_counts
        ] )
    ]
