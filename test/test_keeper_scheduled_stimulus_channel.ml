(* test_keeper_scheduled_stimulus_channel.ml

   A scheduler wake delivered through the event queue must run as
   [channel = Scheduled_autonomous]. Before the fix the stimulus rode the
   reactive trigger list, so the turn ran as [Reactive]: the reactive
   prompt/sleep semantics applied and every channel=scheduled_autonomous
   reader (proactive evidence, decision log proof) missed the wake — the
   feature matrix documented the resulting undercount on the Proactive
   row. A wake that coincides with a real reactive trigger still
   attributes to that trigger. *)

open Alcotest
module WO = Masc.Keeper_world_observation
module Scope = Masc.Keeper_world_observation_message_scope

let make_meta name =
  let json =
    `Assoc
      [ "name", `String name
      ; "trace_id", `String ("trace-sched-" ^ name)
      ]
  in
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok meta -> meta
  | Error err -> fail ("make_meta failed: " ^ err)
;;

let quiet_obs : WO.world_observation =
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

let reasons_of_verdict = function
  | WO.Run { reasons = first, rest } -> first :: rest
  | WO.Skip _ -> []
;;

let decide ?(event_queue_triggers = []) obs =
  WO.keeper_cycle_decision ~event_queue_triggers ~meta:(make_meta "sched-keeper") obs
;;

let test_queue_scheduled_stimulus_runs_scheduled_channel () =
  let d =
    decide ~event_queue_triggers:[ WO.Scheduled_automation_stimulus ] quiet_obs
  in
  check bool "scheduled stimulus drives a turn" true d.should_run;
  check
    bool
    "channel is Scheduled_autonomous, not Reactive"
    true
    (d.channel = WO.Scheduled_autonomous);
  check
    bool
    "verdict carries Scheduled_automation_due"
    true
    (List.mem WO.Scheduled_automation_due (reasons_of_verdict d.verdict))
;;

let test_scheduled_stimulus_with_mention_stays_reactive () =
  let obs =
    { quiet_obs with
      pending_messages =
        [ { Scope.message_id = "msg-1"
          ; speaker = "vincent"
          ; content = "@sched-keeper ping"
          ; kind = Scope.Mention
          }
        ]
    }
  in
  let d = decide ~event_queue_triggers:[ WO.Scheduled_automation_stimulus ] obs in
  check bool "coinciding mention still drives a turn" true d.should_run;
  check
    bool
    "attribution goes to the reactive trigger"
    true
    (d.channel = WO.Reactive);
  check
    bool
    "verdict carries Mention_pending"
    true
    (List.mem WO.Mention_pending (reasons_of_verdict d.verdict));
  check
    bool
    "scheduled due no longer rides the reactive reason list"
    false
    (List.mem WO.Scheduled_automation_due (reasons_of_verdict d.verdict))
;;

let test_plain_reactive_stimulus_unchanged () =
  let d =
    decide ~event_queue_triggers:[ WO.Connector_attention_stimulus ] quiet_obs
  in
  check bool "connector stimulus drives a turn" true d.should_run;
  check bool "channel stays Reactive" true (d.channel = WO.Reactive);
  check
    bool
    "verdict carries Connector_attention_pending"
    true
    (List.mem WO.Connector_attention_pending (reasons_of_verdict d.verdict))
;;

let () =
  run
    "keeper_scheduled_stimulus_channel"
    [ ( "queue-delivered scheduler wake attribution"
      , [ test_case
            "scheduled stimulus alone runs as Scheduled_autonomous"
            `Quick
            test_queue_scheduled_stimulus_runs_scheduled_channel
        ; test_case
            "scheduled stimulus with a mention attributes to the mention"
            `Quick
            test_scheduled_stimulus_with_mention_stays_reactive
        ; test_case
            "plain reactive stimulus keeps the Reactive channel"
            `Quick
            test_plain_reactive_stimulus_unchanged
        ] )
    ]
;;
