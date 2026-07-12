(** No-signal scheduler invariant for [keeper_cycle_decision].

    PR #21685 removed the [Entropic_oscillation] turn-trigger: a 600s / 5%
    random probe that, per the runtime decision log (96 entropic turns over
    ~19h on the analyst keeper), produced visible action 88.5% of the time —
    contradicting the scheduler policy: a structured-work-less proactive turn
    should not be opened.

    After the removal, a warm keeper (past bootstrap, [min_interval] not yet
    elapsed, no provider cooldown) with NO per-keeper signal (no mention, board
    event, or scope message) and NO global backlog must stay silent:
    [should_run = false]. This file pins that invariant.

    It is the structural dual of the thundering-herd backlog test
    ([test_keeper_reactive_wake_backlog_gate]): that file shows global backlog
    drives a run ([backlog=1] -> [should_run=true]); this file shows the
    absence of all signals suppresses scheduling ([backlog=0] ->
    [should_run=false]).

    The assertion is sensitive to [should_run]: a [|| true] mutation of the
    intent flag is killed by this test. The removed [Entropic_oscillation]
    fired on a 600s interval this warm (30s) meta never reaches, so this case
    pins the post-removal invariant (signal-less turn -> silence) rather than
    exercising the entropic path directly; its 5% jitter precluded a
    deterministic kill regardless. *)

open Alcotest

module WO = Masc.Keeper_world_observation

(* Provider cooldown is global in-memory state; pin it to "no cooldown" so the
   decision is driven purely by the no-signal branch under test. *)
let no_provider_cooldown ~keeper_name:_ ~runtime_id:_ = None

(* [keeper_cycle_decision] resolves a runtime id (via [runtime_id_of_meta] ->
   [Runtime.get_default_runtime_id]) unconditionally, which fails fast when no
   default runtime is initialised (RFC-0206 §2.1). Initialise a minimal default
   runtime the same way the other keeper unit tests do. *)
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
  let path = Filename.temp_file "keeper_silence_runtime_" ".toml" in
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
      ; ("trace_id", `String ("trace-silence-" ^ name))
      ; ("goal", `String "no-signal silence invariant test")
      ]
  in
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok meta -> meta
  | Error err -> Alcotest.fail ("make_meta failed: " ^ err)
;;

(* Warm, non-bootstrap meta: a recent-but-past scheduled-autonomous turn so the
   bootstrap and [min_interval] liveness paths are inactive. This isolates the
   no-signal branch: with nothing pending and [min_interval] not elapsed, the
   only thing that could drive a run is a signal, of which there is none. *)
let warm_meta () =
  let meta = make_meta "silence" in
  let now = Time_compat.now () in
  { meta with
    proactive = { enabled = true; idle_sec = 600; cooldown_sec = 1800 }
  ; runtime =
      { meta.runtime with
        proactive_rt =
          { meta.runtime.proactive_rt with
            last_ts = now -. 30.0
          ; consecutive_noop_count = 0
          }
      }
  }
;;

(* No signal whatsoever: no mention, no board event, no scope message, no
   global backlog, no backlog update since the last scheduled-autonomous turn.
   This is the state a warm keeper reaches when the world is quiet. *)
let no_signal_obs : WO.world_observation =
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
  ; backlog_updated_since_last_scheduled_autonomous = false
  ; running_keeper_fiber_count = 1
  ; connected_surfaces = []
  }
;;

let decide_no_signal () =
  let meta = warm_meta () in
  WO.keeper_cycle_decision
    ~provider_cooldown_remaining_sec:no_provider_cooldown
    ~reactive_wake:false
    ~meta
    no_signal_obs
;;

let schedule_attention_obs =
  { no_signal_obs with
    scheduled_automation =
      { WO.empty_scheduled_automation_observation with
        active_count = 1
      ; due_ready_count = 1
      }
  }
;;

let schedule_ready_meta () =
  let meta = warm_meta () in
  let now = Time_compat.now () in
  { meta with
    proactive = { meta.proactive with cooldown_sec = 60 }
  ; runtime =
      { meta.runtime with
        proactive_rt =
          { meta.runtime.proactive_rt with
            last_ts = now -. 120.0
          ; consecutive_noop_count = 0
          }
      }
  }
;;

let run_reasons d =
  match d.WO.verdict with
  | WO.Run { reasons = first, rest } -> first :: rest
  | WO.Skip _ -> []
;;

let has_run_reason reason d = List.exists (( = ) reason) (run_reasons d)

(* Core invariant (PR #21685): a warm keeper with no signal and no backlog
   stays silent. The removed [Entropic_oscillation] trigger was the only path
   that ran a turn in this state; deleting it makes [should_run] deterministically
   false here. *)
let test_no_signal_warm_keeper_stays_silent () =
  let d = decide_no_signal () in
  check
    bool
    "no-signal warm keeper stays silent (PR #21685 entropic removal invariant)"
    false
    d.should_run

(* The channel is unaffected: silence is a [Skip] verdict on the
   scheduled-autonomous channel, not a reactive redirect. *)
let test_no_signal_keeps_scheduled_channel () =
  let d = decide_no_signal () in
  check
    bool
    "no-signal silence stays on the scheduled-autonomous channel"
    true
    (match d.channel with
     | WO.Scheduled_autonomous -> true
     | WO.Reactive -> false)

let test_scheduled_automation_attention_runs_after_task_cooldown () =
  let meta = schedule_ready_meta () in
  let d =
    WO.keeper_cycle_decision
      ~provider_cooldown_remaining_sec:no_provider_cooldown
      ~reactive_wake:false
      ~meta
      schedule_attention_obs
  in
  check bool "scheduled automation attention runs" true d.should_run;
  check bool "reason includes scheduled_automation_due" true
    (has_run_reason WO.Scheduled_automation_due d)

let test_bootstrap_event_queue_trigger_runs_warm_keeper () =
  let meta = warm_meta () in
  let d =
    WO.keeper_cycle_decision
      ~provider_cooldown_remaining_sec:no_provider_cooldown
      ~reactive_wake:false
      ~event_queue_triggers:[ WO.Bootstrap_stimulus ]
      ~meta
      no_signal_obs
  in
  check bool "bootstrap event queue trigger runs" true d.should_run;
  check bool "bootstrap trigger stays reactive" true
    (match d.channel with
     | WO.Reactive -> true
     | WO.Scheduled_autonomous -> false);
  check bool "reason includes bootstrap stimulus" true
    (has_run_reason WO.Bootstrap_stimulus_pending d)

let test_no_progress_event_queue_trigger_runs_warm_keeper () =
  let meta = warm_meta () in
  let d =
    WO.keeper_cycle_decision
      ~provider_cooldown_remaining_sec:no_provider_cooldown
      ~reactive_wake:false
      ~event_queue_triggers:[ WO.No_progress_recovery_stimulus ]
      ~meta
      no_signal_obs
  in
  check bool "no-progress event queue trigger runs" true d.should_run;
  check bool "reason includes no-progress stimulus" true
    (has_run_reason WO.No_progress_recovery_stimulus_pending d)

let test_scheduled_event_queue_trigger_runs_warm_keeper () =
  let meta = warm_meta () in
  let d =
    WO.keeper_cycle_decision
      ~provider_cooldown_remaining_sec:no_provider_cooldown
      ~reactive_wake:false
      ~event_queue_triggers:[ WO.Scheduled_automation_stimulus ]
      ~meta
      no_signal_obs
  in
  check bool "scheduled event queue trigger runs" true d.should_run;
  check bool "reason includes scheduled automation due" true
    (has_run_reason WO.Scheduled_automation_due d)

let test_failure_judgment_control_respects_paused_keeper () =
  let meta = { (warm_meta ()) with paused = true } in
  let d =
    WO.keeper_cycle_decision
      ~provider_cooldown_remaining_sec:no_provider_cooldown
      ~reactive_wake:true
      ~event_queue_triggers:[ WO.Failure_judgment_stimulus ]
      ~meta
      no_signal_obs
  in
  check bool "paused keeper does not run judgment action" false d.should_run;
  check bool "operator pause remains authoritative" true
    (match d.verdict with
     | WO.Skip { reasons = WO.Keeper_paused, _ } -> true
     | WO.Skip _ | WO.Run _ -> false)

(* RFC-0303 Phase 2 stimulus-gate: a warm keeper whose [min_interval] HAS
   elapsed but that has NO opportunity (no signal, no claimed task, no backlog)
   now stays silent. Before Phase 2, [min_interval_elapsed] drove a blind
   housekeeping turn (verdict [Min_interval_elapsed]) with nothing to do, which
   manufactured the "passive" turns the no-progress stack then chased. Now
   [min_interval] is a rate-limit inside the proactive-work guard, not a
   standalone trigger. *)
let elapsed_min_interval_meta () =
  let meta = make_meta "silence-elapsed" in
  let now = Time_compat.now () in
  { meta with
    proactive = { enabled = true; idle_sec = 600; cooldown_sec = 1800 }
  ; runtime =
      { meta.runtime with
        proactive_rt =
          { meta.runtime.proactive_rt with
            last_ts = now -. 100_000.0 (* well past the 900s default min interval *)
          ; consecutive_noop_count = 0
          }
      }
  }
;;

let skip_reasons d =
  match d.WO.verdict with
  | WO.Skip { reasons = first, rest } -> first :: rest
  | WO.Run _ -> []
;;

let test_elapsed_min_interval_no_signal_stays_silent () =
  let meta = elapsed_min_interval_meta () in
  let d =
    WO.keeper_cycle_decision
      ~provider_cooldown_remaining_sec:no_provider_cooldown
      ~reactive_wake:false
      ~meta
      no_signal_obs
  in
  check
    bool
    "elapsed min_interval + no opportunity stays silent (RFC-0303 P2 stimulus-gate)"
    false
    d.should_run;
  check
    bool
    "silence carries the No_signal skip reason"
    true
    (List.exists (( = ) WO.No_signal) (skip_reasons d))
;;

(* Guard: gating the blind cadence must NOT silence a keeper that actually has
   work. A keeper holding a claimed task is proactive-work-ready, so an elapsed
   min_interval still drives its cadence turn. *)
let test_elapsed_min_interval_with_claimed_task_runs () =
  let task_id =
    match Keeper_id.Task_id.of_string "TASK-1" with
    | Ok id -> id
    | Error e -> Alcotest.failf "Task_id.of_string failed: %s" e
  in
  let meta = { (elapsed_min_interval_meta ()) with current_task_id = Some task_id } in
  let d =
    WO.keeper_cycle_decision
      ~provider_cooldown_remaining_sec:no_provider_cooldown
      ~reactive_wake:false
      ~meta
      no_signal_obs
  in
  check
    bool
    "keeper with a claimed task still runs on cadence (proactive work preserved)"
    true
    d.should_run;
  check
    bool
    "run reason includes Min_interval_elapsed"
    true
    (has_run_reason WO.Min_interval_elapsed d)
;;

let () = init_runtime_default_for_tests ()

let () =
  run
    "keeper no-signal silence"
    [ ( "entropic_removal_invariant"
      , [ test_case
            "no-signal warm keeper stays silent"
            `Quick
            test_no_signal_warm_keeper_stays_silent
        ; test_case
            "no-signal silence keeps scheduled channel"
            `Quick
            test_no_signal_keeps_scheduled_channel
        ; test_case
            "scheduled automation attention runs after task cooldown"
            `Quick
            test_scheduled_automation_attention_runs_after_task_cooldown
        ; test_case
            "bootstrap event queue trigger runs warm keeper"
            `Quick
            test_bootstrap_event_queue_trigger_runs_warm_keeper
        ; test_case
            "no-progress event queue trigger runs warm keeper"
            `Quick
            test_no_progress_event_queue_trigger_runs_warm_keeper
        ; test_case
            "scheduled event queue trigger runs warm keeper"
            `Quick
            test_scheduled_event_queue_trigger_runs_warm_keeper
        ; test_case
            "failure judgment control respects paused keeper"
            `Quick
            test_failure_judgment_control_respects_paused_keeper
        ; test_case
            "elapsed min_interval + no opportunity stays silent (RFC-0303 P2)"
            `Quick
            test_elapsed_min_interval_no_signal_stays_silent
        ; test_case
            "elapsed min_interval + claimed task still runs (RFC-0303 P2)"
            `Quick
            test_elapsed_min_interval_with_claimed_task_runs
        ] )
    ]
;;
