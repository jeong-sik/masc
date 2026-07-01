(** RFC-0297 Phase 1 (P0-1): the global proactive kill-switch actually
    suppresses the scheduled-autonomous turn.

    Before this, [key_to_env] had no [proactive.enabled] mapping and
    [keeper_cycle_decision] gated only on the per-keeper [meta.proactive.enabled];
    an operator's global "proactive off" intent was silently dropped. These
    tests pin that:

    1. A keeper that WOULD run a scheduled-automation turn is suppressed
       ([Skip Scheduled_autonomous_disabled]) when the global proactive gate is
       off, even though [meta.proactive.enabled = true].
    2. With the gate on (default all-enabled) the same keeper runs — so the gate
       is the cause of the suppression, not some other branch.
    3. The reactive path is unaffected: a pending mention still runs even with
       the global proactive gate off (the gate does not disable direct
       responses). *)

open Alcotest
module WO = Masc.Keeper_world_observation
module Gate = Masc.Keeper_lifecycle_gate

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

(* Warm keeper whose scheduled-automation cooldown has elapsed, so with the
   attention observation below it WOULD open a scheduled-autonomous turn. *)
let schedule_ready_meta () =
  let meta = make_meta "gate" in
  let now = Time_compat.now () in
  { meta with
    proactive = { enabled = true; idle_sec = 600; cooldown_sec = 60 }
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
  ; continuity_summary = ""
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

let decide ?lifecycle_global ~meta obs =
  WO.keeper_cycle_decision
    ~provider_cooldown_remaining_sec:no_provider_cooldown
    ~reactive_wake:false
    ?lifecycle_global
    ~meta
    obs
;;

let skip_reasons d =
  match d.WO.verdict with
  | WO.Skip { reasons = first, rest } -> first :: rest
  | WO.Run _ -> []
;;

(* Control: with the gate on (default), the scheduled-automation attention
   opens a turn. Anchors that the suppression below is caused by the gate. *)
let test_gate_on_runs () =
  let meta = schedule_ready_meta () in
  let d = decide ~lifecycle_global:Gate.all_enabled ~meta schedule_attention_obs in
  check bool "gate on: scheduled automation attention runs" true d.should_run

(* RFC-0297 P0-1: global proactive kill-switch suppresses the turn even though
   the per-keeper meta flag is still enabled. *)
let test_global_gate_off_suppresses () =
  let meta = schedule_ready_meta () in
  check bool "precondition: per-keeper proactive still enabled" true
    meta.proactive.enabled;
  let d =
    decide
      ~lifecycle_global:{ Gate.all_enabled with proactive = false }
      ~meta
      schedule_attention_obs
  in
  check bool "global proactive off suppresses the turn" false d.should_run;
  check bool "suppressed on scheduled-autonomous channel" true
    (match d.channel with
     | WO.Scheduled_autonomous -> true
     | WO.Reactive -> false);
  check bool "skip reason is scheduled_autonomous_disabled" true
    (List.exists (( = ) WO.Scheduled_autonomous_disabled) (skip_reasons d))

(* The gate does not disable reactive responses: a pending mention still runs
   even with the global proactive gate off. *)
let test_reactive_path_unaffected_by_proactive_gate () =
  let meta = schedule_ready_meta () in
  let obs = { base_obs with pending_mentions = [ ("peer", "ping") ] } in
  let d =
    decide ~lifecycle_global:{ Gate.all_enabled with proactive = false } ~meta obs
  in
  check bool "reactive turn still runs with proactive gate off" true d.should_run;
  check bool "reactive turn stays on the reactive channel" true
    (match d.channel with
     | WO.Reactive -> true
     | WO.Scheduled_autonomous -> false)

let () = init_runtime_default_for_tests ()

let () =
  run "keeper_lifecycle_global_gate"
    [ ( "proactive_kill_switch"
      , [ test_case "gate on runs" `Quick test_gate_on_runs
        ; test_case "global gate off suppresses" `Quick
            test_global_gate_off_suppresses
        ; test_case "reactive path unaffected" `Quick
            test_reactive_path_unaffected_by_proactive_gate
        ] )
    ]
;;
