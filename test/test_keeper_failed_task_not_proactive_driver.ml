(** RFC-keeper-proactive-wake-actionability-invariant T1 — failed_task must not drive a proactive turn.

    The [failed_task] signal grants only the read-only [Task_audit] affordance
    (tools keeper_tasks_audit / keeper_tasks_list / masc_tasks), so a keeper
    woken by it cannot clear the signal.  Driving a proactive turn on it
    produced the 619-turn no-op livelock (executor keeper, 2026-06-21..24).

    This pins the post-fix invariant on [keeper_cycle_decision]: a
    failed-task-only observation does NOT yield [should_run = true], while a
    claimable-task observation (mutating [Task_claim]) still does.  Reverting
    R1g flips the failed-only case back to [should_run = true] (backlog drives a
    turn), so this assertion is a genuine revert-red discriminator.

    Structural dual of [test_keeper_reactive_wake_backlog_gate] (global backlog
    drives a run) and [test_keeper_no_signal_silence] (no signal -> silence). *)

open Alcotest

module WO = Masc.Keeper_world_observation

let no_provider_cooldown ~keeper_name:_ ~runtime_id:_ = None

let runtime_toml =
  {|
[runtime]
default = "test_provider.test_model"

[providers.test_provider]
display-name = "Test Provider"
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:1"

[models.test_model]
api-name = "test-model"
max-context = 8192
tools-support = true
streaming = true

[test_provider.test_model]
is-default = true
max-concurrent = 1
|}
;;

let init_runtime_default_for_tests () =
  let path = Filename.temp_file "keeper_failed_task_runtime_" ".toml" in
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc runtime_toml);
  match Runtime.init_default ~config_path:path with
  | Ok () -> ()
  | Error e -> Alcotest.failf "Runtime.init_default failed: %s" e
;;

let make_meta name =
  let json =
    `Assoc
      [ ("name", `String name)
      ; ("agent_name", `String ("agent-" ^ name))
      ; ("trace_id", `String ("trace-failedtask-" ^ name))
      ; ("goal", `String "failed_task not-a-driver invariant test")
      ]
  in
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok meta -> meta
  | Error err -> Alcotest.fail ("make_meta failed: " ^ err)
;;

(* Warm, non-bootstrap meta with a configurable [since_sec]: a past
   scheduled-autonomous turn [since_sec] seconds ago.  Keep [since_sec] below
   [min_interval] (900s default) so the housekeeping path does not fire and the
   only thing that could drive a run is an actionable signal. *)
let warm_meta ~since_sec () =
  let meta = make_meta "failedtask" in
  let now = Time_compat.now () in
  { meta with
    proactive = { enabled = true; idle_sec = 600; cooldown_sec = 1800 }
  ; runtime =
      { meta.runtime with
        proactive_rt =
          { meta.runtime.proactive_rt with
            last_ts = now -. since_sec
          ; consecutive_noop_count = 0
          }
      }
  }
;;

let base_obs : WO.world_observation =
  { pending_mentions = []
  ; pending_board_events = []
  ; pending_scope_messages = []
  ; idle_seconds = 0
  ; active_goals = []
  ; context_ratio = lazy 0.0
  ; unclaimed_task_count = 0
  ; claimable_task_count = 0
  ; provider_capacity_blocked_task_count = 0
  ; failed_task_count = 0
  ; pending_verification_count = 0
  ; scheduled_automation = WO.empty_scheduled_automation_observation
  ; backlog_updated_since_last_scheduled_autonomous = true
  ; running_keeper_fiber_count = 1
  ; connected_surfaces = []
  }
;;

let decide ~since_sec (obs : WO.world_observation) =
  let meta = warm_meta ~since_sec () in
  (WO.keeper_cycle_decision
     ~base_path:""
     ~provider_cooldown_remaining_sec:no_provider_cooldown
     ~reactive_wake:false
     ~meta
     obs)
    .should_run
;;

(* A static orphan (failed_task_count > 0) with nothing claimable and no other
   signal must NOT drive a proactive turn at any cadence below min_interval. *)
let test_failed_task_alone_does_not_drive_proactive_turn () =
  let obs = { base_obs with failed_task_count = 2 } in
  Alcotest.(check bool)
    "failed-only at since=200s -> no proactive turn"
    false (decide ~since_sec:200.0 obs);
  Alcotest.(check bool)
    "failed-only at since=700s (past task cooldown) -> no proactive turn"
    false (decide ~since_sec:700.0 obs)
;;

(* Discriminator: R1g must not over-silence.  A claimable task grants the
   mutating [Task_claim] affordance, so it still drives a turn. *)
let test_claimable_still_drives () =
  let obs = { base_obs with claimable_task_count = 1 } in
  Alcotest.(check bool)
    "claimable at since=200s -> proactive turn"
    true (decide ~since_sec:200.0 obs)
;;

(* pending_verification grants the mutating [Task_verify] affordance, so R1g
   keeps it as an actionable proactive-work signal. *)
let test_pending_verification_stays_actionable () =
  let obs = { base_obs with pending_verification_count = 1 } in
  Alcotest.(check bool)
    "pending_verification is an actionable signal"
    true
    (WO.actionable_signal_present obs)
;;

let () =
  init_runtime_default_for_tests ();
  run "keeper_failed_task_not_proactive_driver"
    [ ( "failed_task"
      , [ test_case "failed-only does not drive" `Quick
            test_failed_task_alone_does_not_drive_proactive_turn
        ; test_case "claimable still drives" `Quick test_claimable_still_drives
        ; test_case "pending_verification stays actionable" `Quick
            test_pending_verification_stays_actionable
        ] )
    ]
;;
