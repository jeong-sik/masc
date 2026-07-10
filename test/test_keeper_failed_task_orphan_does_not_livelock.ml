(** RFC-keeper-proactive-wake-actionability-invariant T3 — a static orphan does not produce a self-cadence livelock.

    Reproduces the executor incident shape (2026-06-21..24): a static
    [failed_task_count > 0] with nothing claimable, re-evaluated on the keeper's
    own cadence.  Pre-fix, every evaluation past [task_reactive_cooldown]
    returned [should_run = true] (backlog drives the turn) — 619 no-op turns
    over 3 days.  Post-fix (R1g), failed_task is advisory-only and drives no
    turn, so across a window below [min_interval] the count of [should_run=true]
    verdicts is zero.

    Distinct from [test_keeper_turn_livelock_10121]: that guard keys on turn-id
    reattempts and RESETS on forward advance, so it cannot catch a livelock that
    emits a fresh turn id each cycle (which this one did).

    A companion case pins the RFC-0303 interaction: [min_interval] is only a
    rate-limit for real work signals now, so a read-only orphan still must not
    open a blind housekeeping turn after [min_interval]. *)

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
  let path = Filename.temp_file "keeper_livelock_runtime_" ".toml" in
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
      ; ("trace_id", `String ("trace-livelock-" ^ name))
      ; ("goal", `String "orphan livelock regression test")
      ]
  in
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok meta -> meta
  | Error err -> Alcotest.fail ("make_meta failed: " ^ err)
;;

let warm_meta ~since_sec () =
  let meta = make_meta "livelock" in
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

(* Static orphan: failed_task present every cycle, nothing claimable, backlog
   marked updated so the pre-fix backlog_fresh path would also have fired. *)
let orphan_obs : WO.world_observation =
  { pending_mentions = []
  ; pending_board_events = []
  ; pending_scope_messages = []
  ; idle_seconds = 0
  ; active_goals = []
  ; context_ratio = lazy 0.0
  ; unclaimed_task_count = 0
  ; claimable_task_count = 0
  ; provider_capacity_blocked_task_count = 0
  ; failed_task_count = 2
  ; pending_verification_count = 0
  ; scheduled_automation = WO.empty_scheduled_automation_observation
  ; backlog_updated_since_last_scheduled_autonomous = true
  ; running_keeper_fiber_count = 1
  ; connected_surfaces = []
  }
;;

let decide ~since_sec =
  let meta = warm_meta ~since_sec () in
  (WO.keeper_cycle_decision
     ~provider_cooldown_remaining_sec:no_provider_cooldown
     ~reactive_wake:false
     ~meta
     orphan_obs)
    .should_run
;;

(* Simulate the keeper re-evaluating on its own cadence over a window below
   min_interval (900s).  None of these may drive a turn post-R1g. *)
let test_static_orphan_drives_zero_turns () =
  let cadence_points = [ 100.0; 200.0; 400.0; 600.0; 800.0 ] in
  let fired =
    List.filter (fun since_sec -> decide ~since_sec) cadence_points
  in
  Alcotest.(check int)
    "static orphan drives zero proactive turns below min_interval"
    0
    (List.length fired)
;;

(* RFC-0303: a read-only orphan is not a proactive work signal.  Crossing
   min_interval must not reintroduce the blind cadence turn that manufactured
   passive no-op cycles. *)
let test_orphan_stays_silent_past_min_interval () =
  Alcotest.(check bool)
    "orphan stays silent past min_interval"
    false
    (decide ~since_sec:1000.0)
;;

let () =
  init_runtime_default_for_tests ();
  run "keeper_failed_task_orphan_does_not_livelock"
    [ ( "livelock"
      , [ test_case "static orphan drives zero turns" `Quick
            test_static_orphan_drives_zero_turns
        ; test_case "orphan stays silent past min_interval" `Quick
            test_orphan_stays_silent_past_min_interval
        ] )
    ]
;;
