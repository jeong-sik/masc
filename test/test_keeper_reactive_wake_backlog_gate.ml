(** Reactive-wake gate for [keeper_cycle_decision] — thundering-herd fix.

    A single task release/add broadcasts to every keeper with [mention=None],
    which wakes ALL keepers ([wakeup_all_keepers]) at once. Before this gate,
    each woken keeper saw the GLOBAL (claimable-by-anyone) backlog signal and
    ran a full LLM turn, so one claimable task produced N turns. The gate keys
    backlog-driven turns on the wake source:

    - cadence wake ([Timeout], [reactive_wake=false]): global backlog drives a
      turn as before (the keeper's own scheduled cadence).
    - broadcast wake ([Woken], [reactive_wake=true]): global backlog alone does
      NOT drive a turn — the work is picked up on the keeper's own cadence and by
      the supervisor sweep, not by an all-keeper stampede.

    Per-keeper Reactive triggers (mention/board/scope) and time-based liveness
    reasons (bootstrap / min_interval / idle_gate+cooldown / oscillation) are
    unaffected; only the global-backlog path is gated. *)

open Alcotest

module WO = Masc.Keeper_world_observation

(* Provider cooldown is global in-memory state; pin it to "no cooldown" so the
   decision is driven purely by the backlog gate under test. *)
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
  let path = Filename.temp_file "keeper_herd_runtime_" ".toml" in
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
      ; ("trace_id", `String ("trace-herd-" ^ name))
      ; ("goal", `String "thundering herd backlog gate test")
      ]
  in
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok meta -> meta
  | Error err -> Alcotest.fail ("make_meta failed: " ^ err)

(* Warm, non-bootstrap meta: a recent-but-past scheduled-autonomous turn so
   [since_last] is small and finite. This avoids the bootstrap / min_interval
   time-based liveness paths, isolating the global-backlog decision branch.
   Uses the same clock ([Time_compat.now]) the decision reads. (The
   entropic-oscillation path this comment used to list was removed in #21685.) *)
let warm_backlog_meta () =
  let meta = make_meta "herd" in
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

(* Global backlog present (one claimable task in the shared pool, backlog just
   updated) but NO per-keeper reactive trigger: no mention, no board event, no
   scope message. This is exactly the broadcast-wake-into-shared-pool scenario. *)
let global_backlog_obs : WO.world_observation =
  { pending_mentions = []
  ; pending_board_events = []
  ; pending_scope_messages = []
  ; idle_seconds = 0
  ; active_goals = []
  ; context_ratio = lazy 0.0
  ; unclaimed_task_count = 1
  ; claimable_task_count = 1
  ; provider_capacity_blocked_task_count = 0
  ; failed_task_count = 0
  ; pending_verification_count = 0
  ; scheduled_automation = WO.empty_scheduled_automation_observation
  ; backlog_updated_since_last_scheduled_autonomous = true
  ; running_keeper_fiber_count = 1
  ; connected_surfaces = []
  }

let decide ~reactive_wake =
  let meta = warm_backlog_meta () in
  WO.keeper_cycle_decision
    ~base_path:""
    ~provider_cooldown_remaining_sec:no_provider_cooldown
    ~reactive_wake
    ~meta
    global_backlog_obs

(* Baseline: the keeper's own cadence (Timeout) still runs on global backlog. *)
let test_cadence_wake_runs_on_backlog () =
  let d = decide ~reactive_wake:false in
  check bool "cadence wake (Timeout) runs on global backlog" true d.should_run

(* Fix: a broadcast-driven wake (Woken) must NOT run on global backlog alone,
   otherwise every keeper stampedes on each task release/add. *)
let test_broadcast_wake_skips_global_backlog () =
  let d = decide ~reactive_wake:true in
  check
    bool
    "broadcast wake (Woken) does NOT stampede on global backlog"
    false
    d.should_run

(* The gate must not change the channel: this is still a scheduled-autonomous
   evaluation (the reactive channel handles per-keeper mention/board/scope). *)
let test_gate_keeps_scheduled_channel () =
  let d = decide ~reactive_wake:true in
  check
    bool
    "gated broadcast wake stays on the scheduled-autonomous channel"
    true
    (match d.channel with
     | WO.Scheduled_autonomous -> true
     | WO.Reactive -> false)

let test_live_keeper_count_ignores_empty_agent_registry () =
  let base_path = Filename.temp_file "keeper-live-count-" "" in
  Sys.remove base_path;
  Unix.mkdir base_path 0o755;
  let masc_dir = Filename.concat base_path ".masc" in
  let agents_dir = Filename.concat masc_dir "agents" in
  Unix.mkdir masc_dir 0o755;
  Unix.mkdir agents_dir 0o755;
  let rec remove_tree path =
    if Sys.is_directory path
    then (
      Array.iter
        (fun name -> remove_tree (Filename.concat path name))
        (Sys.readdir path);
      Unix.rmdir path)
    else Sys.remove path
  in
  Fun.protect
    ~finally:(fun () ->
      Masc.Keeper_registry.clear ();
      remove_tree base_path)
    (fun () ->
      Masc.Keeper_registry.clear ();
      let config = Masc.Workspace.default_config base_path in
      let meta = make_meta "live-count" in
      ignore
        (Masc.Keeper_registry.register ~base_path:config.base_path meta.name meta);
      check int "counts running keepers, not .masc/agents" 1
        (Masc.Keeper_world_observation_inputs.count_running_keeper_fibers ~config))

let () = init_runtime_default_for_tests ()

let () =
  run
    "keeper reactive-wake backlog gate"
    [ ( "thundering_herd"
      , [ test_case
            "cadence wake runs on global backlog"
            `Quick
            test_cadence_wake_runs_on_backlog
        ; test_case
            "broadcast wake skips global backlog"
            `Quick
            test_broadcast_wake_skips_global_backlog
        ; test_case
            "gate keeps scheduled-autonomous channel"
            `Quick
            test_gate_keeps_scheduled_channel
        ; test_case
            "live keeper count ignores empty agent registry"
            `Quick
            test_live_keeper_count_ignores_empty_agent_registry
        ] )
    ]
;;
