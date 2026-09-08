open Alcotest
open Masc
module WO = Keeper_world_observation
module Signal = Keeper_keepalive_signal

let meta () =
  match Masc_test_deps.meta_of_json_fixture
    (`Assoc ["name", `String "periodic"; "trace_id", `String "trace-periodic"]) with
  | Error error -> fail error
  | Ok meta -> { meta with proactive = { enabled = true }; autoboot_enabled = true }

let base_obs : WO.world_observation =
  { pending_messages = []
  ; pending_board_events = []
  ; idle_seconds = 0
  ; active_goals = []
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
  ; own_recent_actions = []
  }
;;


let decide wake triggers =
  Keeper_heartbeat_loop.decide_keepalive_scheduling ~wake
    ~event_queue_triggers:triggers ~stop:(Atomic.make false) ~meta:(meta ()) base_obs

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
    ; test_case "cadence updates and warmup" `Quick test_cadence_change_and_initial_warmup ] ]
