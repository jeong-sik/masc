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
module Admission = Masc.Keeper_lifecycle_admission
module State_machine = Keeper_state_machine
module Shutdown_types = Masc.Keeper_shutdown_types

let contains haystack needle =
  let hl = String.length haystack
  and nl = String.length needle in
  let rec at i = i + nl <= hl && (String.sub haystack i nl = needle || at (i + 1)) in
  nl = 0 || at 0
;;

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
      ; ("trace_id", `String ("trace-gate-" ^ name))
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
  ; proactive = { enabled = true }
  ; runtime =
      { meta.runtime with
        proactive_rt =
          { meta.runtime.proactive_rt with
            last_ts = now -. 120.0
          }
      }
  }
;;

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

let schedule_attention_obs =
  { base_obs with
    scheduled_automation =
      { WO.empty_scheduled_automation_observation with
        active_count = 1
      ; due_ready_count = 1
      }
  }
;;

let mention_obs =
  { base_obs with
    pending_messages =
      [ { Masc.Keeper_world_observation_message_scope.message_id = "mention-1"
        ; speaker = "peer"
        ; content = "ping"
        ; kind = Mention
        }
      ]
  }

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

let test_global_reactive_off_does_not_suppress_typed_mention () =
  with_flag "MASC_KEEPER_REACTIVE_ENABLED" "false" @@ fun () ->
  let d = decide ~meta:(ready_meta ()) mention_obs in
  check bool "typed mention remains runnable" true d.should_run;
  check (list string) "typed mention has no skip reasons" []
    (List.map WO.skip_reason_to_string (skip_reasons d))

(* Review-flagged: a pending reactive trigger must not, on its own, starve
   the scheduled-autonomous decision when the reactive gate is off -- a
   persistent trigger (e.g. a stuck mention) would otherwise permanently
   block proactive turns even though MASC_KEEPER_PROACTIVE_ENABLED=true and
   the keeper is due for scheduled work. *)
let test_global_reactive_off_does_not_starve_scheduled_autonomous () =
  with_flag "MASC_KEEPER_REACTIVE_ENABLED" "false" @@ fun () ->
  let obs = { schedule_attention_obs with pending_messages = mention_obs.pending_messages } in
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
  check bool "blocker is typed autoboot_disabled" true
    (match r.autonomous_activation.blocker with
     | Some Readiness.Autoboot_disabled -> true
     | Some (Readiness.Lifecycle_denied _ | Readiness.Proactive_disabled) | None ->
       false);
  (* Review-flagged: the hint must not tell the operator to set
     autoboot_enabled=true when the per-keeper flag is already true and the
     *global* kill-switch is the actual cause -- that would send them
     editing the wrong knob. *)
  check bool "hint names the global env var, not the already-true meta flag"
    true
    (match r.autonomous_activation.hint with
     | Some hint -> contains hint "MASC_KEEPER_AUTONOMOUS_ENABLED"
     | None -> false)

let owner_runtime ~phase ~live_fiber =
  Readiness.Owner_registered
    { phase; live_fiber; lane_exited = false }
;;

let test_owner_execution_requires_live_fiber () =
  without_overrides @@ fun () ->
  check bool "policy permission without a registered owner is recoverable" true
    (match
       Readiness.classify_owner_execution
         ~shutdown_operation_id:None
         ~runtime:Readiness.Owner_unregistered
         (Ok (ready_meta ()))
     with
     | Readiness.Recoverable -> true
     | Readiness.Executable
     | Readiness.Retained_disabled _
     | Readiness.Paused_dead _
     | Readiness.Shutdown_fenced _
     | Readiness.Unknown _ -> false);
  check bool "registered but non-running owner remains recoverable" true
    (match
       Readiness.classify_owner_execution
         ~shutdown_operation_id:None
         ~runtime:(owner_runtime ~phase:State_machine.Offline ~live_fiber:false)
         (Ok (ready_meta ()))
     with
     | Readiness.Recoverable -> true
     | Readiness.Executable
     | Readiness.Retained_disabled _
     | Readiness.Paused_dead _
     | Readiness.Shutdown_fenced _
     | Readiness.Unknown _ -> false);
  check bool "only an observed live fiber is executable" true
    (match
       Readiness.classify_owner_execution
         ~shutdown_operation_id:None
         ~runtime:(owner_runtime ~phase:State_machine.Running ~live_fiber:true)
         (Ok (ready_meta ()))
     with
     | Readiness.Executable -> true
     | Readiness.Recoverable
     | Readiness.Retained_disabled _
     | Readiness.Paused_dead _
     | Readiness.Shutdown_fenced _
     | Readiness.Unknown _ -> false)
;;

let test_durable_demand_does_not_require_proactive () =
  without_overrides @@ fun () ->
  let ready = ready_meta () in
  let proactive_disabled =
    { ready with proactive = { enabled = false } }
  in
  check bool "ordinary autonomous execution remains disabled" true
    (match
       Readiness.classify_owner_execution
         ~shutdown_operation_id:None
         ~runtime:(owner_runtime ~phase:State_machine.Running ~live_fiber:true)
         (Ok proactive_disabled)
     with
     | Readiness.Retained_disabled Readiness.Retained_proactive_disabled -> true
     | Readiness.Executable
     | Readiness.Recoverable
     | Readiness.Retained_disabled _
     | Readiness.Paused_dead _
     | Readiness.Shutdown_fenced _
     | Readiness.Unknown _ -> false);
  check bool "persisted reactive demand can wake the live owner" true
    (match
       Readiness.classify_durable_demand_execution
         ~shutdown_operation_id:None
         ~runtime:(owner_runtime ~phase:State_machine.Running ~live_fiber:true)
         (Ok proactive_disabled)
     with
     | Readiness.Executable -> true
     | Readiness.Recoverable
     | Readiness.Retained_disabled _
     | Readiness.Paused_dead _
     | Readiness.Shutdown_fenced _
     | Readiness.Unknown _ -> false);
  check bool "persisted demand can recover an absent owner" true
    (match
       Readiness.classify_durable_demand_execution
         ~shutdown_operation_id:None
         ~runtime:Readiness.Owner_unregistered
         (Ok proactive_disabled)
     with
     | Readiness.Recoverable -> true
     | Readiness.Executable
     | Readiness.Retained_disabled _
     | Readiness.Paused_dead _
     | Readiness.Shutdown_fenced _
     | Readiness.Unknown _ -> false);
  with_flag "MASC_KEEPER_AUTONOMOUS_ENABLED" "false" @@ fun () ->
  check bool "persisted demand still respects the autoboot kill-switch" true
    (match
       Readiness.classify_durable_demand_execution
         ~shutdown_operation_id:None
         ~runtime:Readiness.Owner_unregistered
         (Ok proactive_disabled)
     with
     | Readiness.Retained_disabled Readiness.Retained_autoboot_disabled -> true
     | Readiness.Executable
     | Readiness.Recoverable
     | Readiness.Retained_disabled _
     | Readiness.Paused_dead _
     | Readiness.Shutdown_fenced _
     | Readiness.Unknown _ -> false)
;;

let test_durable_demand_bypasses_autoboot_only_for_live_running_owner () =
  without_overrides @@ fun () ->
  let autoboot_disabled = { (ready_meta ()) with autoboot_enabled = false } in
  let classify ?(shutdown_operation_id = None) runtime =
    Readiness.classify_durable_demand_execution
      ~shutdown_operation_id
      ~runtime
      (Ok autoboot_disabled)
  in
  check bool "live running owner accepts persisted demand" true
    (match
       classify (owner_runtime ~phase:State_machine.Running ~live_fiber:true)
     with
     | Readiness.Executable -> true
     | Readiness.Recoverable
     | Readiness.Retained_disabled _
     | Readiness.Paused_dead _
     | Readiness.Shutdown_fenced _
     | Readiness.Unknown _ -> false);
  let remains_autoboot_disabled runtime =
    match classify runtime with
    | Readiness.Retained_disabled Readiness.Retained_autoboot_disabled -> true
    | Readiness.Executable
    | Readiness.Recoverable
    | Readiness.Retained_disabled _
    | Readiness.Paused_dead _
    | Readiness.Shutdown_fenced _
    | Readiness.Unknown _ -> false
  in
  check bool "absent owner is not autobooted" true
    (remains_autoboot_disabled Readiness.Owner_unregistered);
  check bool "dead fiber is not treated as executable" true
    (remains_autoboot_disabled
       (owner_runtime ~phase:State_machine.Running ~live_fiber:false));
  check bool "terminal owner is not treated as executable" true
    (remains_autoboot_disabled
       (owner_runtime ~phase:State_machine.Stopped ~live_fiber:true));
  let operation_id = Shutdown_types.Operation_id.generate () in
  check bool "shutdown fence still dominates the live-owner exception" true
    (match
       classify
         ~shutdown_operation_id:(Some operation_id)
         (owner_runtime ~phase:State_machine.Running ~live_fiber:true)
     with
     | Readiness.Shutdown_fenced actual ->
       Shutdown_types.Operation_id.equal operation_id actual
     | Readiness.Executable
     | Readiness.Recoverable
     | Readiness.Retained_disabled _
     | Readiness.Paused_dead _
     | Readiness.Unknown _ -> false);
  with_flag "MASC_KEEPER_AUTONOMOUS_ENABLED" "false" @@ fun () ->
  check bool "global autonomous kill-switch still dominates" true
    (match
       classify (owner_runtime ~phase:State_machine.Running ~live_fiber:true)
     with
     | Readiness.Retained_disabled Readiness.Retained_autoboot_disabled -> true
     | Readiness.Executable
     | Readiness.Recoverable
     | Readiness.Retained_disabled _
     | Readiness.Paused_dead _
     | Readiness.Shutdown_fenced _
     | Readiness.Unknown _ -> false)
;;

let test_owner_execution_shutdown_fence_blocks_boot () =
  without_overrides @@ fun () ->
  let operation_id = Shutdown_types.Operation_id.generate () in
  check bool "shutdown fence is a closed activation blocker" true
    (match
       Readiness.classify_owner_execution
         ~shutdown_operation_id:(Some operation_id)
         ~runtime:Readiness.Owner_unregistered
         (Ok (ready_meta ()))
     with
     | Readiness.Shutdown_fenced actual ->
       Shutdown_types.Operation_id.equal operation_id actual
     | Readiness.Executable
     | Readiness.Recoverable
     | Readiness.Retained_disabled _
     | Readiness.Paused_dead _
     | Readiness.Unknown _ -> false)

let test_owner_execution_unknown_fails_closed () =
  check bool "unreadable owner truth cannot authorize activation" true
    (match
       Readiness.classify_owner_execution
         ~shutdown_operation_id:None
         ~runtime:Readiness.Owner_unregistered
         (Error "meta unavailable")
     with
     | Readiness.Unknown "meta unavailable" -> true
     | Readiness.Executable
     | Readiness.Recoverable
     | Readiness.Retained_disabled _
     | Readiness.Paused_dead _
     | Readiness.Shutdown_fenced _
     | Readiness.Unknown _ -> false)

let operator_pause =
  Keeper_latched_reason.Operator_paused
    { operator_actor = Keeper_latched_reason.operator_actor_keeper_down }
;;

let lifecycle_state ~paused ~latched_reason =
  Admission.state ~paused ~latched_reason
;;

let test_active_admission () =
  let state = lifecycle_state ~paused:false ~latched_reason:None in
  check bool "state is active" true
    (match state with
     | Admission.Active -> true
     | Admission.Paused _ -> false);
  check bool "manual one-shot admitted" true
    (match Admission.admit_manual_one_shot state with
     | Admission.Manual_admitted_active -> true
     | Admission.Manual_admitted_paused_recovery _ -> false);
  check bool "autonomous admitted" true
    (match Admission.admit_autonomous state with
     | Admission.Autonomous_admitted -> true
     | Admission.Autonomous_denied _ -> false)
;;

let test_classified_pause_admission () =
  let state =
    lifecycle_state ~paused:true ~latched_reason:(Some operator_pause)
  in
  check bool "state is a classified pause" true
    (match state with
     | Admission.Paused (Admission.Classified reason) ->
       Keeper_latched_reason.equal reason operator_pause
     | Admission.Active | Admission.Paused Admission.Unclassified -> false);
  check bool "manual one-shot is an explicit recovery" true
    (match Admission.admit_manual_one_shot state with
     | Admission.Manual_admitted_paused_recovery (Admission.Classified reason) ->
       Keeper_latched_reason.equal reason operator_pause
     | Admission.Manual_admitted_active
     | Admission.Manual_admitted_paused_recovery Admission.Unclassified
     -> false);
  check bool "autonomous execution is denied" true
    (match Admission.admit_autonomous state with
     | Admission.Autonomous_denied
         (Admission.Autonomous_paused (Admission.Classified reason)) ->
       Keeper_latched_reason.equal reason operator_pause
     | Admission.Autonomous_admitted
     | Admission.Autonomous_denied
         (Admission.Autonomous_paused Admission.Unclassified) -> false)
;;

let test_unclassified_pause_fails_closed () =
  let state = lifecycle_state ~paused:true ~latched_reason:None in
  check bool "missing latch remains paused" true
    (match state with
     | Admission.Paused Admission.Unclassified -> true
     | Admission.Active | Admission.Paused (Admission.Classified _) -> false);
  check bool "unclassified pause blocks autonomous execution" true
    (match Admission.admit_autonomous state with
     | Admission.Autonomous_denied
         (Admission.Autonomous_paused Admission.Unclassified) -> true
     | Admission.Autonomous_admitted
     | Admission.Autonomous_denied
         (Admission.Autonomous_paused (Admission.Classified _)) -> false)
;;



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
        ; test_case "global off does not suppress typed mention" `Quick
            test_global_reactive_off_does_not_suppress_typed_mention
        ; test_case "global off does not starve scheduled-autonomous" `Quick
            test_global_reactive_off_does_not_starve_scheduled_autonomous
        ] )
    ; ( "autonomous"
      , [ test_case "default ready" `Quick test_default_autonomous_ready
        ; test_case "global off blocks readiness" `Quick
            test_global_autonomous_off_blocks_readiness
        ; test_case "execution requires live fiber" `Quick
            test_owner_execution_requires_live_fiber
        ; test_case "durable demand bypasses proactive policy" `Quick
            test_durable_demand_does_not_require_proactive
        ; test_case "durable demand bypasses autoboot only for live owner" `Quick
            test_durable_demand_bypasses_autoboot_only_for_live_running_owner
        ; test_case "shutdown fence blocks boot" `Quick
            test_owner_execution_shutdown_fence_blocks_boot
        ; test_case "unknown owner truth fails closed" `Quick
            test_owner_execution_unknown_fails_closed
        ] )
    ; ( "typed lifecycle admission"
      , [ test_case "active" `Quick test_active_admission
        ; test_case "classified pause" `Quick test_classified_pause_admission
        ; test_case "unclassified pause fails closed" `Quick
            test_unclassified_pause_fails_closed

        ] )
    ]
;;
