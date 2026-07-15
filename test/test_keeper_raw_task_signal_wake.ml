open Alcotest
open Masc

module WO = Keeper_world_observation

let base_observation : WO.world_observation =
  { pending_messages = []
  ; pending_board_events = []
  ; keeper_invocation_joins = []
  ; idle_seconds = 0
  ; active_goals = []
  ; unclaimed_task_count = 0
  ; claimable_task_count = 0
  ; failed_task_count = 0
  ; pending_verification_count = 0
  ; scheduled_automation = WO.empty_scheduled_automation_observation
  ; backlog_updated_since_last_scheduled_autonomous = false
  ; running_keeper_fiber_count = 1
  ; connected_surfaces = []
  }
;;

let test_task_signals_reach_the_keeper_without_local_tool_semantics () =
  let assert_wakes label observation =
    check bool label true (WO.actionable_signal_present observation)
  in
  assert_wakes
    "claimable task is an observation"
    { base_observation with claimable_task_count = 1 };
  assert_wakes
    "failed task is an observation"
    { base_observation with failed_task_count = 1 };
  assert_wakes
    "pending verification is an observation"
    { base_observation with pending_verification_count = 1 }
;;

let () =
  run
    "keeper raw task signal wake"
    [ ( "wake"
      , [ test_case
            "task signals are not classified by local tool semantics"
            `Quick
            test_task_signals_reach_the_keeper_without_local_tool_semantics
        ] )
    ]
;;
