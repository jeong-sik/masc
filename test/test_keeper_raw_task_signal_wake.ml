open Alcotest
open Masc

module WO = Keeper_world_observation

let base_observation : WO.world_observation =
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

let test_task_signals_reach_the_keeper_without_local_tool_semantics () =
  let assert_wakes label observation =
    check bool label true (WO.actionable_signal_present observation)
  in
  assert_wakes
    "claimable task is an observation"
    { base_observation with
      claimable_tasks =
        [ { Keeper_world_observation_inputs.task_id =
              Keeper_id.Task_id.of_string "task-claimable" |> Result.get_ok
          }
        ]
    };
  assert_wakes
    "failed task is an observation"
    { base_observation with failed_task_count = 1 }
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
