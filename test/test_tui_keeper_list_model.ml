module Model = Masc_tui_keeper_list_model
module Decode = Masc.Tui_decode
module Control = Masc_tui_keeper_control

let runtime health name : Decode.keeper_runtime =
  { kr_name = name
  ; kr_identity = Ok { k_trace_id = "trace-" ^ name; k_created_at = "2026-01-01T00:00:00Z"; k_updated_at = "2026-01-01T00:00:00Z" }
  ; kr_portrait = Decode.Unavailable "test"
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
  ; kr_runtime_path_rest = Ok None
  ; kr_operator_disposition = Ok None
  ; kr_failing_since = None
  ; kr_recent_turns = None
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
  ; kta_approval_id = "approval-call-1"
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
  ; ar_submitted_at = 1.
  ; ar_ownership = ownership
  }

let row ?(last_activity_at = Some 0.) ?turn ?waiting ?(waiting_unavailable = false) ?approval
    ?(awaiting_verification = false) ?(open_questions = 0) ?(async_requests = [])
    ?(paused = false) ?health ?(edit = Fun.id) name : Model.row =
  let liveness = match health with
    | None -> Control.Unobserved
    | Some health -> Control.Present (edit (runtime health name))
  in
  { keeper = keeper name
  ; reading = { Control.name = name; paused = paused; liveness = liveness }
  ; turn
  ; waiting = (if waiting_unavailable then Model.Waiting_unavailable else
      match waiting with Some row -> Model.Waiting_observed row | None -> Model.Waiting_unobserved)
  ; approval
  ; task = None
  ; awaiting_verification
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

let views = [ Model.Plain; Model.By_state; Model.By_cause; Model.By_runtime; Model.Day_wall ]

let test_cycles () =
  Alcotest.(check (list string)) "v walks the views in the RFC order and comes back"
    (List.map Model.view_label (List.tl views @ [ Model.Plain ]))
    (List.map (fun view -> Model.view_label (Model.next_view view)) views);
  List.iter
    (fun view ->
      Alcotest.(check bool) ("view label reads back: " ^ Model.view_label view) true
        (Model.view_of_string (Model.view_label view) = Some view))
    views;
  Alcotest.(check bool) "one line to two" true (Model.next_density Model.One_line = Model.Two_lines);
  Alcotest.(check bool) "two lines to one" true (Model.next_density Model.Two_lines = Model.One_line);
  List.iter
    (fun density ->
      Alcotest.(check bool) ("density label reads back: " ^ Model.density_label density) true
        (Model.density_of_string (Model.density_label density) = Some density))
    [ Model.One_line; Model.Two_lines ];
  Alcotest.(check bool) "priority to recent" true (Model.next_sort Model.Priority = Model.Recent);
  Alcotest.(check bool) "recent to oldest" true (Model.next_sort Model.Recent = Model.Oldest);
  Alcotest.(check bool) "oldest to activity" true (Model.next_sort Model.Oldest = Model.Activity);
  Alcotest.(check bool) "activity to name" true (Model.next_sort Model.Activity = Model.Name);
  Alcotest.(check bool) "name to priority" true (Model.next_sort Model.Name = Model.Priority)

let test_priority_orders_attention_activity_waiting_then_inactive () =
  let rows =
    [ row ~last_activity_at:(Some 70.) "unknown"
    ; row ~last_activity_at:(Some 80.) ~waiting:(waiting "delegate") ~turn:model_waiting "model"
    ; row ~last_activity_at:(Some 90.) ~turn:streaming "stream"
    ; row ~last_activity_at:(Some 100.) ~approval:(approval "held") "held"
    ; row ~last_activity_at:(Some 70.) ~turn:Decode.Keeper_turn_idle ~waiting:(waiting ~state:Model.Keeper_waiting_idle "idle") "idle"
    ; row ~last_activity_at:(Some 100.) ~open_questions:1 "question"
    ; row ~last_activity_at:(Some 80.) ~waiting:(waiting "verify") ~awaiting_verification:true "verify"
    ; row ~last_activity_at:(Some 90.)
        ~async_requests:[async_request Decode.Async_running "a"; async_request ~ownership:Decode.Async_ownership_unknown Decode.Async_running "b"] "async"
    ; row ~last_activity_at:(Some 100.) ~health:(health "failing") "failure"
    ; row ~last_activity_at:(Some 70.) ~paused:true "paused"
    ; row ~last_activity_at:(Some 80.)
        ~waiting:(waiting ~items:[waiting_item ~producer:Model.Wake_keeper_delegate ()] "delegate") "delegate"
    ]
  in
  Alcotest.(check (list string)) "attention, failing, activity, waiting, inactive"
    [ "held"; "question"; "failure"; "async"; "stream"; "delegate"; "model"; "verify"; "idle"; "paused"; "unknown" ]
    (names (Model.order_rows ~view:Model.Plain ~now:0. ~sort:Model.Priority rows))

let test_recent_and_name_have_deterministic_ties () =
  let rows =
    [ row ~last_activity_at:None "unknown"
    ; row ~last_activity_at:(Some 10.) "beta"
    ; row ~last_activity_at:(Some 1.) "old"
    ; row ~last_activity_at:(Some 10.) "alpha"
    ]
  in
  Alcotest.(check (list string)) "recent descending, name tie, unknown last"
    [ "alpha"; "beta"; "old"; "unknown" ] (names (Model.order_rows ~view:Model.Plain ~now:0. ~sort:Model.Recent rows));
  Alcotest.(check (list string)) "name ignores activity"
    [ "alpha"; "beta"; "old"; "unknown" ] (names (Model.order_rows ~view:Model.Plain ~now:0. ~sort:Model.Name rows));
  let duplicates = [ row ~last_activity_at:(Some 10.) "same-a"; row ~last_activity_at:(Some 10.) "same-b" ] in
  Alcotest.(check (list string)) "identical sort keys remain stable"
    [ "same-a"; "same-b" ] (names (Model.order_rows ~view:Model.Plain ~now:0. ~sort:Model.Recent duplicates))

let with_runtime_id runtime_id (runtime : Decode.keeper_runtime) = { runtime with kr_runtime_id = runtime_id }

let test_runtime_view_groups_by_runtime_id () =
  let healthy = health "healthy" in
  let rows =
    [ row ~health:healthy ~edit:(with_runtime_id "b.runtime") "b1"
    ; row "unread"
    ; row ~health:healthy ~edit:(with_runtime_id "a.runtime") "a1"
    ; row ~health:healthy ~edit:(with_runtime_id "b.runtime") "b2"
    ]
  in
  Alcotest.(check (list string)) "runtime ids in order, then the unread row"
    [ "a1"; "b1"; "b2"; "unread" ]
    (names (Model.order_rows ~view:Model.By_runtime ~sort:Model.Name ~now:0. rows));
  Alcotest.(check bool) "a read row is grouped by its runtime id" true
    (Model.group_of_view Model.By_runtime (List.hd rows)
     = Some (Model.Group_runtime (Model.Runtime_named "b.runtime")));
  Alcotest.(check bool) "an unread row has its own group" true
    (Model.group_of_view Model.By_runtime (List.nth rows 1)
     = Some (Model.Group_runtime Model.Runtime_unread));
  Alcotest.(check bool) "the plain list does not group" true
    (Model.group_of_view Model.Plain (List.hd rows) = None)

let test_cause_view_puts_failing_rows_first () =
  let rows = [ row ~health:(health "healthy") "sound"; row ~health:(health "failing") "failing" ] in
  Alcotest.(check (list string)) "a failing row before a sound one"
    [ "failing"; "sound" ]
    (names (Model.order_rows ~view:Model.By_cause ~sort:Model.Name ~now:0. rows));
  Alcotest.(check bool) "a failure with no receipt names no cause" true
    (Model.group_of_view Model.By_cause (List.nth rows 1)
     = Some (Model.Group_cause Model.Cause_unnamed));
  Alcotest.(check bool) "a sound row is not failing" true
    (Model.group_of_view Model.By_cause (List.hd rows) = Some (Model.Group_cause Model.Not_failing))

let day = float_of_int Masc.Keeper_turn_pulse.window_seconds
let slot_seconds = Masc.Keeper_turn_pulse.slot_seconds
let now = 1_794_000_000.

let failed_slot ~ago : Masc.Keeper_turn_pulse.slot =
  { starts_at = Masc.Keeper_turn_pulse.slot_start (now -. ago)
  ; tally = { ok = 0; rested = 0; failed = 1 } }

let with_pulse slots (runtime : Decode.keeper_runtime) =
  { runtime with kr_recent_turns = Some { known_since = now -. day; slots } }

let test_day_wall_puts_the_most_failed_half_hours_first () =
  let healthy = health "healthy" in
  let rows =
    [ row ~health:healthy "no-pulse"
    ; row ~health:healthy ~edit:(with_pulse [ failed_slot ~ago:600. ]) "one"
    ; row ~health:healthy ~edit:(with_pulse [ failed_slot ~ago:(day +. 3600.) ]) "older"
    ; row ~health:healthy
        ~edit:(with_pulse [ failed_slot ~ago:600.; failed_slot ~ago:(float_of_int (4 * slot_seconds)) ])
        "two"
    ]
  in
  Alcotest.(check (list (option int))) "failed half-hours within the last day"
    [ None; Some 1; Some 0; Some 2 ]
    (List.map (Model.failed_half_hours ~now) rows);
  Alcotest.(check (list string)) "most failed first, rows without a pulse last"
    [ "two"; "one"; "older"; "no-pulse" ]
    (names (Model.order_rows ~view:Model.Day_wall ~sort:Model.Name ~now rows));
  Alcotest.(check bool) "the day wall does not group" true
    (Model.group_of_view Model.Day_wall (List.hd rows) = None);
  Alcotest.(check bool) "the day wall can reorder every half hour" true
    (Model.order_clock_step Model.Day_wall = Some (float_of_int slot_seconds));
  Alcotest.(check bool) "the state view only reorders on new readings" true
    (Model.order_clock_step Model.By_state = None)

let test_streaming_keeps_async_and_schedule_badges () =
  let value =
    row ~turn:streaming
      ~async_requests:
        [ async_request Decode.Async_running "a"
        ; async_request ~ownership:Decode.Async_ownership_unknown Decode.Async_running "b"
        ]
      ~waiting:(waiting
        ~items:
          [ waiting_item ~source:Model.Waiting_source_schedule_waiting ()
          ; waiting_item ~source:Model.Waiting_source_read_error ()
          ]
        "row")
      "row"
  in
  Alcotest.(check bool) "the turn remains primary" true
    (Model.primary_activity_of_row value = Model.Streaming);
  Alcotest.(check bool) "the row is active" true (Model.group_of_row value = Model.Active);
  let badges = Model.badges_of_row value in
  Alcotest.(check bool) "both async requests and ownership uncertainty survive" true
    (List.mem (Model.Badge_async { running = 2; ownership_unknown = 1 }) badges);
  Alcotest.(check bool) "the scheduled wake remains a secondary badge" true
    (List.mem Model.Badge_schedule badges);
  Alcotest.(check bool) "an observation failure stays a secondary badge" true
    (List.mem Model.Badge_read_error badges)

let test_quota_spent_wait_has_its_own_badge () =
  let value =
    row
      ~waiting:(waiting
        ~items:[ waiting_item ~source:Model.Waiting_source_runtime_quota_spent ~producer:Model.Wake_keeper_supervisor () ]
        "row")
      "row"
  in
  let badges = Model.badges_of_row value in
  Alcotest.(check bool) "a Keeper whose every candidate spent its quota is marked" true
    (List.mem Model.Badge_quota_spent badges);
  Alcotest.(check bool) "the wait is not read as a read error" false
    (List.mem Model.Badge_read_error badges);
  Alcotest.(check bool) "the wait is not read as a schedule" false
    (List.mem Model.Badge_schedule badges)

let test_delegate_and_verification_remain_distinct_badges () =
  let value =
    row ~awaiting_verification:true
      ~waiting:(waiting ~items:[waiting_item ~producer:Model.Wake_keeper_delegate ()] "row")
      "row"
  in
  Alcotest.(check bool) "a queued delegate result is primary without an active turn" true
    (Model.primary_activity_of_row value = Model.Delegate_result);
  Alcotest.(check bool) "the result awaits the Keeper" true (Model.group_of_row value = Model.Waiting);
  let badges = Model.badges_of_row value in
  Alcotest.(check bool) "delegation badge" true (List.mem Model.Badge_delegate badges);
  Alcotest.(check bool) "verification badge" true (List.mem Model.Badge_verification badges)

let test_unobserved_is_not_idle () =
  let unknown = row "unknown" in
  let idle = row ~turn:Decode.Keeper_turn_idle ~waiting:(waiting ~state:Model.Keeper_waiting_idle "idle") "idle" in
  Alcotest.(check bool) "unknown remains unknown" true (Model.primary_activity_of_row unknown = Model.Unknown);
  Alcotest.(check bool) "observed idle remains idle" true (Model.primary_activity_of_row idle = Model.Idle);
  Alcotest.(check bool) "unknown is not counted as inactive" true
    (Model.group_of_row unknown = Model.Unobserved && Model.group_of_row idle = Model.Inactive);
  let unavailable = row ~turn:Decode.Keeper_turn_idle ~waiting_unavailable:true "unavailable" in
  let active = row ~turn:streaming ~waiting_unavailable:true "active" in
  Alcotest.(check bool) "idle turn with unreadable waiting remains unknown" true
    (Model.primary_activity_of_row unavailable = Model.Unknown
     && Model.group_of_row unavailable = Model.Unobserved
     && List.mem Model.Badge_waiting_unavailable (Model.badges_of_row unavailable));
  Alcotest.(check bool) "an independent active turn stays active" true
    (Model.primary_activity_of_row active = Model.Streaming
     && Model.group_of_row active = Model.Active)

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
  let read_error =
    row ~waiting:(waiting ~items:[waiting_item ~source:Model.Waiting_source_read_error ()] "row")
      "read-error"
  in
  Alcotest.(check bool) "operator confirmation needs a person" true
    (Model.primary_activity_of_row confirmation = Model.Confirmation && Model.group_of_row confirmation = Model.Attention);
  Alcotest.(check bool) "an inventory read failure does not become a Keeper failure" true
    (Model.primary_activity_of_row read_error = Model.External_waiting
     && Model.group_of_row read_error = Model.Waiting);
  Alcotest.(check bool) "the observation failure badge remains explicit" true
    (List.mem Model.Badge_read_error (Model.badges_of_row read_error))

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

let test_waiting_summary_counts_primary_reasons_and_background_work () =
  let rows =
    [ row ~turn:tool_waiting
        ~async_requests:
          [ async_request Decode.Async_running "tool-running"
          ; async_request Decode.Async_queued "tool-queued"
          ; async_request Decode.Async_cancelling "tool-cancelling"
          ]
        "tool"
    ; row ~turn:model_waiting
        ~async_requests:[ async_request Decode.Async_running "model-running" ]
        "model"
    ; row ~waiting:(waiting "external") "external"
    ; row
        ~waiting:(waiting ~items:[ waiting_item ~producer:Model.Wake_keeper_delegate () ] "delegate")
        "delegate"
    ; row ~awaiting_verification:true "verify"
    ; row ~turn:streaming
        ~async_requests:[ async_request Decode.Async_running "active-running" ]
        "active"
    ]
  in
  let summary = Model.waiting_summary rows in
  Alcotest.(check bool) "all five primary reasons are counted once" true
    (summary.tool = 1 && summary.model = 1 && summary.external_wait = 1
     && summary.delegate = 1 && summary.verification = 1);
  Alcotest.(check int) "only waiting rows contribute background async running" 2 summary.background

let task_with_status id status : Decode.task =
  { id; title = id; status; priority = 3; goal_ids = [] }

let test_a_submitter_is_found_by_assignee () =
  let tasks =
    [ verification_task "alpha"
    ; task_with_status "task-beta" (Masc_domain.InProgress { assignee = "beta"; started_at = "1" })
    ; task_with_status "task-gamma"
        (Masc_domain.Done { assignee = "gamma"; completed_at = "2"; notes = None })
    ; task_with_status "task-open" Masc_domain.Todo
    ]
  in
  let holders = Model.verification_holders tasks in
  Alcotest.(check bool) "the assignee of an awaiting task holds one" true
    (Model.holds_awaiting_verification holders ~keeper_name:"alpha");
  Alcotest.(check bool) "an assignee whose task is still in progress does not" false
    (Model.holds_awaiting_verification holders ~keeper_name:"beta");
  Alcotest.(check bool) "an assignee whose task is done does not" false
    (Model.holds_awaiting_verification holders ~keeper_name:"gamma");
  Alcotest.(check bool) "a Keeper without a task does not" false
    (Model.holds_awaiting_verification holders ~keeper_name:"delta");
  Alcotest.(check bool) "an empty task list holds none" false
    (Model.holds_awaiting_verification (Model.verification_holders []) ~keeper_name:"alpha")

let test_a_submitter_without_a_current_task_waits_for_its_verdict () =
  let submitter =
    row ~turn:Decode.Keeper_turn_idle
      ~waiting:(waiting ~state:Model.Keeper_waiting_idle "row")
      ~awaiting_verification:true "row"
  in
  Alcotest.(check bool) "an idle submitter waits for its verdict" true
    (Model.primary_activity_of_row submitter = Model.Verifying);
  Alcotest.(check bool) "it sits in the waiting group" true
    (Model.group_of_row submitter = Model.Waiting);
  Alcotest.(check bool) "the verification badge shows" true
    (List.mem Model.Badge_verification (Model.badges_of_row submitter));
  let working = row ~turn:streaming ~awaiting_verification:true "working" in
  Alcotest.(check bool) "active work stays primary" true
    (Model.primary_activity_of_row working = Model.Streaming);
  Alcotest.(check bool) "the verification badge still shows beside it" true
    (List.mem Model.Badge_verification (Model.badges_of_row working));
  let idle =
    row ~turn:Decode.Keeper_turn_idle ~waiting:(waiting ~state:Model.Keeper_waiting_idle "idle") "idle"
  in
  Alcotest.(check bool) "without a submitted task the Keeper stays idle" true
    (Model.primary_activity_of_row idle = Model.Idle)

let test_a_failing_keeper_shows_what_it_does_and_sits_in_the_failing_group () =
  let failing = health "failing" in
  let working = row ~health:failing ~turn:streaming "working" in
  let quiet =
    row ~health:failing ~turn:Decode.Keeper_turn_idle
      ~waiting:(waiting ~state:Model.Keeper_waiting_idle "quiet") "quiet"
  in
  let stopped = row ~health:failing ~paused:true "stopped" in
  Alcotest.(check bool) "a failing Keeper with an open turn shows the turn" true
    (Model.primary_activity_of_row working = Model.Streaming
     && Model.group_of_row working = Model.Failing);
  Alcotest.(check bool) "a failing Keeper with nothing to wait on shows idle" true
    (Model.primary_activity_of_row quiet = Model.Idle
     && Model.group_of_row quiet = Model.Failing);
  Alcotest.(check bool) "a failing Keeper a person paused shows paused" true
    (Model.primary_activity_of_row stopped = Model.Paused
     && Model.group_of_row stopped = Model.Failing)

let test_a_decision_for_a_person_outranks_a_failing_health_reading () =
  let failing = health "failing" in
  let asked = row ~health:failing ~open_questions:1 "asked" in
  let held = row ~health:failing ~approval:(approval "held") "held" in
  Alcotest.(check bool) "an open question keeps the row in attention" true
    (Model.primary_activity_of_row asked = Model.Question
     && Model.group_of_row asked = Model.Attention);
  Alcotest.(check bool) "a held call keeps the row in attention" true
    (Model.primary_activity_of_row held = Model.Held_call
     && Model.group_of_row held = Model.Attention)

let test_a_failed_attempt_in_the_open_turn_does_not_need_a_failing_health_reading () =
  let attempt =
    row ~health:(health "healthy") ~turn:(turn Masc.Keeper_turn_preview.Failed) "attempt"
  in
  Alcotest.(check bool) "the failed attempt is the activity and the group follows it" true
    (Model.primary_activity_of_row attempt = Model.Attempt_failed
     && Model.group_of_row attempt = Model.Failing)

let test_waiting_summary_leaves_out_a_failing_keeper () =
  let rows =
    [ row ~turn:tool_waiting "tool"
    ; row ~health:(health "failing") ~turn:tool_waiting
        ~async_requests:[ async_request Decode.Async_running "failing-running" ]
        "failing-tool"
    ]
  in
  let summary = Model.waiting_summary rows in
  Alcotest.(check int) "a failing Keeper that waits on a tool is not counted as waiting" 1
    summary.tool;
  Alcotest.(check int) "its background async work is left out too" 0 summary.background

let test_group_counts () =
  let rows =
    [ row ~approval:(approval "held") "held"
    ; row ~health:(health "failing") ~turn:streaming "failing"
    ; row ~turn:streaming "active"
    ; row ~turn:model_waiting "waiting"
    ; row "unknown"
    ]
  in
  Alcotest.(check bool) "counts use the same classification" true
    (Model.group_counts rows
     = { Model.attention_rows = 1; failing_rows = 1; active_rows = 1; waiting_rows = 1
       ; inactive_rows = 0; unobserved_rows = 1 })

let () =
  Alcotest.run "tui_keeper_list_model"
    [ ( "decisions"
      , [ Alcotest.test_case "view, density and sort cycles" `Quick test_cycles
        ; Alcotest.test_case "priority order" `Quick test_priority_orders_attention_activity_waiting_then_inactive
        ; Alcotest.test_case "recent and name ordering" `Quick test_recent_and_name_have_deterministic_ties
        ; Alcotest.test_case "streaming keeps async and schedule badges" `Quick test_streaming_keeps_async_and_schedule_badges
        ; Alcotest.test_case "quota spent wait badge" `Quick test_quota_spent_wait_has_its_own_badge
        ; Alcotest.test_case "delegate and verification badges" `Quick test_delegate_and_verification_remain_distinct_badges
        ; Alcotest.test_case "unobserved is not idle" `Quick test_unobserved_is_not_idle
        ; Alcotest.test_case "paused and offline hide stale activity" `Quick test_paused_and_offline_hide_stale_activity
        ; Alcotest.test_case "confirmation and inventory errors need attention" `Quick test_confirmation_and_inventory_errors_need_attention
        ; Alcotest.test_case "async phases and preparing remain distinct" `Quick test_async_phases_and_preparing_remain_distinct
        ; Alcotest.test_case "waiting summary counts reasons and background work" `Quick
            test_waiting_summary_counts_primary_reasons_and_background_work
        ; Alcotest.test_case "a submitter is found by assignee" `Quick test_a_submitter_is_found_by_assignee
        ; Alcotest.test_case "a submitter without a current task waits for its verdict" `Quick
            test_a_submitter_without_a_current_task_waits_for_its_verdict
        ; Alcotest.test_case "a failing Keeper shows what it does and sits in the failing group" `Quick
            test_a_failing_keeper_shows_what_it_does_and_sits_in_the_failing_group
        ; Alcotest.test_case "a decision for a person outranks a failing health reading" `Quick
            test_a_decision_for_a_person_outranks_a_failing_health_reading
        ; Alcotest.test_case "a failed attempt does not need a failing health reading" `Quick
            test_a_failed_attempt_in_the_open_turn_does_not_need_a_failing_health_reading
        ; Alcotest.test_case "waiting summary leaves out a failing Keeper" `Quick
            test_waiting_summary_leaves_out_a_failing_keeper
        ; Alcotest.test_case "group counts" `Quick test_group_counts
        ; Alcotest.test_case "runtime view groups by runtime id" `Quick
            test_runtime_view_groups_by_runtime_id
        ; Alcotest.test_case "cause view puts failing rows first" `Quick
            test_cause_view_puts_failing_rows_first
        ; Alcotest.test_case "day wall puts the most failed half-hours first" `Quick
            test_day_wall_puts_the_most_failed_half_hours_first
        ] )
    ]
