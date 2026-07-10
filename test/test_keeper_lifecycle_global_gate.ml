(** RFC-0297 Phase 1 (P0-1): the global lifecycle kill-switches actually
    suppress their turns, resolved through the single SSOT
    [Keeper_lifecycle_gate_env.enabled].

    Before this, [key_to_env] had no reactive/proactive/autonomous
    [.enabled] mapping and each site gated only on the per-keeper meta flag;
    an operator's global "off" intent was silently dropped. These tests drive
    the real registry flag (via a boot override — the same precedence a
    runtime.toml value takes) and pin:

    1. MASC_KEEPER_PROACTIVE_ENABLED=false suppresses the scheduled-autonomous
       turn even though meta.proactive.enabled is true.
    2. MASC_KEEPER_REACTIVE_ENABLED=false suppresses a reactive (mention) turn
       (Skip Reactive_disabled).
    3. MASC_KEEPER_AUTONOMOUS_ENABLED=false blocks autonomous activation
       readiness even though meta.autoboot_enabled is true.
    4. With no override (default all-true) the same keeper runs / is ready —
       so the gate is the cause of the suppression. *)

open Alcotest
module WO = Masc.Keeper_world_observation
module Readiness = Masc.Keeper_activation_readiness

let contains haystack needle =
  let hl = String.length haystack
  and nl = String.length needle in
  let rec at i = i + nl <= hl && (String.sub haystack i nl = needle || at (i + 1)) in
  nl = 0 || at 0
;;

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
  let path = Filename.temp_file "keeper_gate_runtime_" ".toml" in
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
      ; ("trace_id", `String ("trace-gate-" ^ name))
      ; ("goal", `String "lifecycle global gate test")
      ]
  in
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok meta -> meta
  | Error err -> Alcotest.fail ("make_meta failed: " ^ err)
;;

(* Warm keeper whose scheduled-automation cooldown has elapsed, with both
   per-keeper flags on, so it WOULD open a scheduled-autonomous turn / be
   autonomously ready. Isolates the global gate as the cause of suppression. *)
let ready_meta () =
  let meta = make_meta "gate" in
  let now = Time_compat.now () in
  { meta with
    autoboot_enabled = true
  ; proactive = { enabled = true; idle_sec = 600; cooldown_sec = 60 }
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
  ; backlog_updated_since_last_scheduled_autonomous = false
  ; running_keeper_fiber_count = 1
  ; connected_surfaces = []
  }
;;

let schedule_attention_obs =
  { base_obs with
    scheduled_automation =
      { WO.empty_scheduled_automation_observation with
        active_count = 1
      ; due_ready_count = 1
      }
  }
;;

let mention_obs = { base_obs with pending_mentions = [ ("peer", "ping") ] }

(* Drive a real registry flag through a boot override, cleaned up afterwards. *)
let with_flag name value f =
  Config_boot_overrides.reset_for_tests ();
  Config_boot_overrides.set name value;
  Fun.protect ~finally:(fun () -> Config_boot_overrides.reset_for_tests ()) f
;;

let without_overrides f =
  Config_boot_overrides.reset_for_tests ();
  Fun.protect ~finally:(fun () -> Config_boot_overrides.reset_for_tests ()) f
;;

let decide ~meta obs =
  WO.keeper_cycle_decision
    ~provider_cooldown_remaining_sec:no_provider_cooldown
    ~reactive_wake:false
    ~meta
    obs
;;

let skip_reasons d =
  match d.WO.verdict with
  | WO.Skip { reasons = first, rest } -> first :: rest
  | WO.Run _ -> []
;;

(* Control: defaults on → scheduled turn runs. *)
let test_default_proactive_runs () =
  without_overrides @@ fun () ->
  let d = decide ~meta:(ready_meta ()) schedule_attention_obs in
  check bool "default: scheduled automation attention runs" true d.should_run

let test_global_proactive_off_suppresses () =
  with_flag "MASC_KEEPER_PROACTIVE_ENABLED" "false" @@ fun () ->
  let meta = ready_meta () in
  check bool "precondition: per-keeper proactive still enabled" true
    meta.proactive.enabled;
  let d = decide ~meta schedule_attention_obs in
  check bool "global proactive off suppresses the turn" false d.should_run;
  check bool "suppressed on scheduled-autonomous channel" true
    (match d.channel with WO.Scheduled_autonomous -> true | WO.Reactive -> false);
  check bool "skip reason scheduled_autonomous_disabled" true
    (List.exists (( = ) WO.Scheduled_autonomous_disabled) (skip_reasons d))

(* Control: defaults on → mention runs a reactive turn. *)
let test_default_reactive_runs () =
  without_overrides @@ fun () ->
  let d = decide ~meta:(ready_meta ()) mention_obs in
  check bool "default: mention runs" true d.should_run;
  check bool "on reactive channel" true
    (match d.channel with WO.Reactive -> true | WO.Scheduled_autonomous -> false)

let test_global_reactive_off_suppresses () =
  with_flag "MASC_KEEPER_REACTIVE_ENABLED" "false" @@ fun () ->
  let d = decide ~meta:(ready_meta ()) mention_obs in
  check bool "global reactive off suppresses the mention turn" false d.should_run;
  check bool "suppressed on reactive channel" true
    (match d.channel with WO.Reactive -> true | WO.Scheduled_autonomous -> false);
  check bool "skip reason reactive_disabled" true
    (List.exists (( = ) WO.Reactive_disabled) (skip_reasons d))

(* Review-flagged: a pending reactive trigger must not, on its own, starve
   the scheduled-autonomous decision when the reactive gate is off -- a
   persistent trigger (e.g. a stuck mention) would otherwise permanently
   block proactive turns even though MASC_KEEPER_PROACTIVE_ENABLED=true and
   the keeper is due for scheduled work. *)
let test_global_reactive_off_does_not_starve_scheduled_autonomous () =
  with_flag "MASC_KEEPER_REACTIVE_ENABLED" "false" @@ fun () ->
  let obs = { schedule_attention_obs with pending_mentions = mention_obs.pending_mentions } in
  let d = decide ~meta:(ready_meta ()) obs in
  check bool "scheduled-autonomous still runs despite the suppressed reactive trigger"
    true d.should_run;
  check bool "runs on the scheduled-autonomous channel, not reactive" true
    (match d.channel with WO.Scheduled_autonomous -> true | WO.Reactive -> false)

(* Autonomous gate flows through the same SSOT resolver in activation
   readiness. *)
let test_default_autonomous_ready () =
  without_overrides @@ fun () ->
  let r = Readiness.of_meta (ready_meta ()) in
  check bool "default: autonomous activation ready" true
    r.autonomous_activation.ok

let test_global_autonomous_off_blocks_readiness () =
  with_flag "MASC_KEEPER_AUTONOMOUS_ENABLED" "false" @@ fun () ->
  let meta = ready_meta () in
  check bool "precondition: per-keeper autoboot still enabled" true
    meta.autoboot_enabled;
  let r = Readiness.of_meta meta in
  check bool "global autonomous off blocks activation" false
    r.autonomous_activation.ok;
  check (option string) "blocker is autoboot_disabled" (Some "autoboot_disabled")
    r.autonomous_activation.blocker;
  (* Review-flagged: the hint must not tell the operator to set
     autoboot_enabled=true when the per-keeper flag is already true and the
     *global* kill-switch is the actual cause -- that would send them
     editing the wrong knob. *)
  check bool "hint names the global env var, not the already-true meta flag"
    true
    (match r.autonomous_activation.hint with
     | Some hint -> contains hint "MASC_KEEPER_AUTONOMOUS_ENABLED"
     | None -> false)

let () = init_runtime_default_for_tests ()

let () =
  run "keeper_lifecycle_global_gate"
    [ ( "proactive"
      , [ test_case "default runs" `Quick test_default_proactive_runs
        ; test_case "global off suppresses" `Quick
            test_global_proactive_off_suppresses
        ] )
    ; ( "reactive"
      , [ test_case "default runs" `Quick test_default_reactive_runs
        ; test_case "global off suppresses" `Quick
            test_global_reactive_off_suppresses
        ; test_case "global off does not starve scheduled-autonomous" `Quick
            test_global_reactive_off_does_not_starve_scheduled_autonomous
        ] )
    ; ( "autonomous"
      , [ test_case "default ready" `Quick test_default_autonomous_ready
        ; test_case "global off blocks readiness" `Quick
            test_global_autonomous_off_blocks_readiness
        ] )
    ]
;;
