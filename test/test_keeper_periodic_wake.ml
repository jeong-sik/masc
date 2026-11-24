open Alcotest
open Masc
module WO = Keeper_world_observation
module Signal = Keeper_keepalive_signal

let meta () =
  match Masc_test_deps.meta_of_json_fixture
    (`Assoc ["name", `String "periodic"; "trace_id", `String "trace-periodic"]) with
  | Error error -> fail error
  | Ok meta -> { meta with activation_mode = Keeper_activation_mode.Autonomous }

let base_obs : WO.world_observation =
  { pending_messages = []
  ; pending_board_events = []
  ; idle_seconds = 0
  ; active_goals = Ok []
  ; unclaimed_task_count = 0
  ; claimable_tasks = []
  ; held_task_skills = []
  ; failed_task_count = 0
  ; scheduled_automation = WO.empty_scheduled_automation_observation
  ; approval_authority =
      { revision = 1; state = WO.Approval_authority_complete; pending = [] }
  ; backlog_revision = Some 1
  ; running_keeper_fiber_count = 1
  ; connected_surfaces = []
  ; connected_surface_failures = []
  ; own_recent_board_posts = []
  ; fleet_messages = []
  ; own_recent_actions = Ok []
  }
;;


let decide ?(obs = base_obs) wake triggers =
  Keeper_heartbeat_loop.decide_keepalive_scheduling ~wake
    ~event_queue_triggers:triggers ~stop:(Atomic.make false) ~meta:(meta ()) obs

let deferred_lane =
  Keeper_turn_driver.For_testing.make_deferred_runtime_lane
    ~assignment_id:"periodic"
    ~failed_runtime_id:"lane-a"
    ~next_runtime_id:"lane-b"
    ~later_runtime_ids:[]
    ~failure:(Agent_core.Error.Internal "test failure")
;;

let test_empty_hints_keep_periodic_boundary () =
  let cadence = Signal.consume_periodic ~now:0. in
  List.iter (fun now ->
    check bool "hint has not reached periodic boundary" false
      (Signal.periodic_is_due ~now ~interval:600. cadence);
    check bool "empty hint does not manufacture a turn" false
      (decide WO.Attention_wake []).should_run_turn;
    check (float 0.) "original due time survives each hint" (600. -. now)
      (Signal.periodic_remaining ~now ~interval:600. cadence))
    [ 1.; 60.; 120.; 300.; 599. ];
  check bool "repeated hints cannot starve the due tick" true
    (Signal.periodic_is_due ~now:600. ~interval:600. cadence);
  check bool "periodic tick schedules a turn" true
    (decide WO.Periodic_tick []).should_run_turn

let test_durable_attention_remains_immediate () =
  List.iter (fun trigger ->
    check bool "durable work runs before periodic due time" true
      (decide WO.Attention_wake [trigger]).should_run_turn)
    [ WO.Scheduled_automation_stimulus; WO.Workspace_message_stimulus
    ; WO.Hitl_resolved_stimulus; WO.Ask_answered_stimulus; WO.Bootstrap_stimulus ]

let test_deferred_lane_authorizes_empty_intake () =
  let wake =
    Keeper_heartbeat_loop.For_testing.cycle_wake
      ~periodic_due:false
      ~deferred_runtime_lane:(Some deferred_lane)
  in
  let scheduling = decide wake [] in
  check bool "the deferred suffix schedules a turn" true scheduling.should_run_turn;
  check (list string) "the deferred suffix remains observable"
    [ "deferred_runtime_lane_pending"; "scheduled_autonomous_turn"; "never_started" ]
    scheduling.verdict_reasons;
  check bool "empty Event Queue intake reaches the turn"
    true
    (Keeper_heartbeat_loop.should_run_turn_after_event_intake
       ~scheduled:scheduling.should_run_turn
       ~event_queue_intake_error:None)
;;

let test_deferred_lane_remains_visible_with_reactive_input () =
  let wake =
    Keeper_heartbeat_loop.For_testing.cycle_wake
      ~periodic_due:false
      ~deferred_runtime_lane:(Some deferred_lane)
  in
  let scheduling = decide wake [ WO.Workspace_message_stimulus ] in
  check bool "the reactive input and deferred suffix schedule one turn"
    true scheduling.should_run_turn;
  check string "the reactive source keeps its channel"
    "turn" scheduling.channel;
  check (list string) "both dispatch facts remain observable"
    [ "workspace_message_pending"; "deferred_runtime_lane_pending" ]
    scheduling.verdict_reasons
;;

let test_reaction_carries_exactly_its_due_work () =
  let obs = { base_obs with failed_task_count = 2 } in
  let reasons ~periodic_due ~deferred_runtime_lane =
    let wake = Keeper_heartbeat_loop.For_testing.cycle_wake ~periodic_due ~deferred_runtime_lane in
    let scheduling = decide ~obs wake [ WO.Workspace_message_stimulus ] in
    check bool "a workspace message opens a reactive turn" true
      (scheduling.should_run_turn && scheduling.turn_decision.channel = WO.Reactive);
    match scheduling.turn_decision.verdict with
    | WO.Run { reasons = first, rest } -> first :: rest
    | WO.Skip _ -> fail "the reactive turn was skipped"
  in
  let input = WO.Workspace_message_pending in
  let backlog = WO.Task_backlog { unclaimed = 0; failed = 2 } in
  let deferred = WO.Deferred_runtime_lane_pending in
  let check_reasons label expected actual = check bool label true (expected = actual) in
  check_reasons "a due tick carries backlog with no deferred input" [input; backlog]
    (reasons ~periodic_due:true ~deferred_runtime_lane:None);
  check_reasons "an early deferred reaction has no periodic backlog duty" [input; deferred]
    (reasons ~periodic_due:false ~deferred_runtime_lane:(Some deferred_lane));
  check_reasons "a due tick with deferred input carries both duties" [input; backlog; deferred]
    (reasons ~periodic_due:true ~deferred_runtime_lane:(Some deferred_lane))
;;

let test_deferred_lane_consumes_a_simultaneously_due_cadence () =
  let now = 600. and interval = 600. in
  let cadence = Signal.consume_periodic ~now:0. in
  let periodic_due = Signal.periodic_is_due ~now ~interval cadence in
  check bool "the periodic boundary is due" true periodic_due;
  let wake =
    Keeper_heartbeat_loop.For_testing.cycle_wake
      ~periodic_due
      ~deferred_runtime_lane:(Some deferred_lane)
  in
  check bool "the unfinished suffix keeps the wake label" true
    (wake = WO.Deferred_runtime_lane { periodic_due = true });
  let cadence =
    Keeper_heartbeat_loop.For_testing.periodic_cadence_after_cycle
      ~periodic_due
      ~due_schedule:Keeper_heartbeat_loop.No_due_schedule_served
      ~now
      cadence
  in
  check bool "the served boundary is not due again" false
    (Signal.periodic_is_due ~now ~interval cadence);
  check (float 0.) "the next boundary remains one interval away" interval
    (Signal.periodic_remaining ~now ~interval cadence)
;;

module L = Keeper_heartbeat_loop

let test_a_served_due_schedule_moves_the_periodic_boundary () =
  let interval = 1800. and schedule_turn_end = 300. in
  let cadence = Signal.consume_periodic ~now:0. in
  let cadence =
    L.For_testing.periodic_cadence_after_cycle
      ~periodic_due:false
      ~due_schedule:L.Due_schedule_served
      ~now:schedule_turn_end
      cadence
  in
  check bool "the boundary the schedule turn served is not due" false
    (Signal.periodic_is_due ~now:interval ~interval cadence);
  check (float 0.) "the next periodic turn is one interval after the schedule turn"
    interval
    (Signal.periodic_remaining ~now:schedule_turn_end ~interval cadence);
  let unchanged =
    L.For_testing.periodic_cadence_after_cycle
      ~periodic_due:false
      ~due_schedule:L.No_due_schedule_served
      ~now:schedule_turn_end
      (Signal.consume_periodic ~now:0.)
  in
  check (float 0.) "a cycle that served no due schedule keeps the boundary"
    (interval -. schedule_turn_end)
    (Signal.periodic_remaining ~now:schedule_turn_end ~interval unchanged)
;;

let test_only_a_finished_schedule_turn_serves () =
  (* The third column says whether that status may serve at all; it serves
     only with an acked batch that held a due schedule. *)
  let statuses =
    [ "succeeded", L.Turn_cycle_turn_succeeded, true
    ; "failed", L.Turn_cycle_turn_failed, false
    ; "without turn", L.Turn_cycle_without_turn, false
    ; "lifecycle blocked", L.Turn_cycle_lifecycle_blocked, false
    ; "owner rejected", L.Turn_cycle_owner_rejected, false
    ; "interrupted", L.Turn_cycle_interrupted, false
    ; "crashed", L.Turn_cycle_crashed, false
    ; "busy", L.Turn_cycle_busy (Keeper_owner.Turn_busy None), false
    ; "rested", L.Turn_cycle_rested, false
    ]
  in
  List.iter
    (fun (label, cycle_status, may_serve) ->
       List.iter
         (fun (stimuli_acked, batch_has_due_schedule) ->
            let expected =
              if may_serve && stimuli_acked && batch_has_due_schedule
              then L.Due_schedule_served
              else L.No_due_schedule_served
            in
            check bool
              (Printf.sprintf "%s acked=%b due_schedule=%b" label stimuli_acked
                 batch_has_due_schedule)
              true
              (L.due_schedule_service_of_cycle ~cycle_status ~stimuli_acked
                 ~batch_has_due_schedule
               = expected))
         [ true, true; true, false; false, true; false, false ])
    statuses
;;

let selection payload =
  { Keeper_event_queue_state.source =
      { Keeper_event_queue.post_id = "periodic-wake-test"
      ; urgency = Keeper_event_queue.Immediate
      ; arrived_at = 1.0
      ; payload
      }
  ; admitted_revision = 1L
  ; arrival = 1L
  ; checkpoint_retentions = 0
  ; first_admitted_at = None
  }
;;

let test_the_batch_holds_a_due_schedule () =
  let due_schedule =
    selection
      (Keeper_event_queue.Schedule_due
         { Keeper_event_queue.occurrence_id = "schedule-occurrence:periodic"
         ; schedule_instance_id = "instance-periodic"
         ; schedule_id = "sched-periodic"
         ; due_at = 1.0
         ; payload_digest = "digest-periodic"
         ; title = None
         ; message = "patrol"
         ; result_delivery = None
         })
  and other = selection Keeper_event_queue.Bootstrap in
  check bool "a batch with a due schedule beside other work" true
    (L.batch_has_due_schedule [ other; due_schedule ]);
  check bool "a batch without a due schedule" false
    (L.batch_has_due_schedule [ other ]);
  check bool "an empty batch" false (L.batch_has_due_schedule [])
;;

let test_cadence_change_and_initial_warmup () =
  let cadence = Signal.consume_periodic ~now:0. in
  check (float 0.) "new interval uses previous periodic boundary" 480.
    (Signal.periodic_remaining ~now:120. ~interval:600. cadence);
  check bool "shortening an interval can make it due" true
    (Signal.periodic_is_due ~now:120. ~interval:100. cadence);
  check (float 0.) "warmup is only initial due time" 15.
    (Signal.periodic_remaining ~now:5. ~interval:600. (Signal.Initial_due 20.))

let () =
  run "keeper_periodic_wake"
    [ "authority", [ test_case "empty hints neither run nor starve" `Quick test_empty_hints_keep_periodic_boundary
    ; test_case "durable attention remains immediate" `Quick test_durable_attention_remains_immediate
    ; test_case "deferred lane authorizes empty intake" `Quick test_deferred_lane_authorizes_empty_intake
    ; test_case "deferred lane remains visible with reactive input" `Quick test_deferred_lane_remains_visible_with_reactive_input
    ; test_case "a reaction carries exactly the due and deferred duties" `Quick test_reaction_carries_exactly_its_due_work
    ; test_case "deferred lane consumes a simultaneously due cadence" `Quick
        test_deferred_lane_consumes_a_simultaneously_due_cadence
    ; test_case "a served due schedule moves the periodic boundary" `Quick
        test_a_served_due_schedule_moves_the_periodic_boundary
    ; test_case "only a finished schedule turn serves the boundary" `Quick
        test_only_a_finished_schedule_turn_serves
    ; test_case "the batch holds a due schedule" `Quick test_the_batch_holds_a_due_schedule
    ; test_case "cadence updates and warmup" `Quick test_cadence_change_and_initial_warmup ] ]
