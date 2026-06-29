(** Idle threshold contract between the OAS loop guard and the masc
    graduated idle hook.

    The hook ({!Keeper_hooks_oas_idle}) escalates over consecutive idle
    turns: nudge -> final warning (skip_at - 1) -> graceful Skip (skip_at).
    The OAS loop guard aborts the run with [IdleDetected] once the idle
    counter reaches [max_idle_turns]. The contract: for every turn channel,
    the guard must sit strictly above the hook's skip threshold — otherwise
    Skip is unreachable, the final warning is injected on a turn the model
    never gets, and the run dies as an error instead of ending gracefully.

    Regression context: the kmsg (user chat) path used to fall back to the
    OAS default guard of 3 while skip_at defaults to 4, so user chat turns
    were killed as [IdleDetected] errors while autonomous turns (guard
    10-15) ended via Skip. *)

open Alcotest
module Reg = Masc.Keeper_registry
module Sup = Masc.Keeper_supervisor
module KSM = Keeper_state_machine
module Keeper_meta_json_parse = Masc.Keeper_meta_json_parse
module Observations = Masc.Keeper_heartbeat_loop_observations

let skip_at = Env_config_keeper.KeeperKeepalive.idle_skip_threshold

let temp_dir () =
  let dir = Filename.temp_file "test_keeper_idle_threshold_contract_" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path
    then
      if Sys.is_directory path
      then (
        Sys.readdir path |> Array.iter (fun name -> rm (Filename.concat path name));
        Unix.rmdir path)
      else Unix.unlink path
  in
  try rm dir with _ -> ()

let make_meta name =
  let json =
    `Assoc
      [ ("name", `String name)
      ; ("agent_name", `String ("agent-" ^ name))
      ; ("trace_id", `String ("trace-" ^ name))
      ; ("goal", `String "test")
      ; ("sandbox_profile", `String "local")
      ; ("network_mode", `String "inherit")
      ; ("tool_access", `List [])
      ]
  in
  match Keeper_meta_json_parse.meta_of_json json with
  | Ok meta -> meta
  | Error err -> fail ("make_meta: " ^ err)

let test_reactive_guard_above_skip () =
  let guard = Masc.Keeper_runtime_resolved.reactive_max_idle_turns () in
  check bool
    (Printf.sprintf
       "reactive guard (%d) must exceed idle skip threshold (%d)"
       guard
       skip_at)
    true
    (guard > skip_at)

let test_autonomous_guard_above_skip () =
  let guard = Masc.Keeper_runtime_resolved.autonomous_max_idle_turns () in
  check bool
    (Printf.sprintf
       "autonomous guard (%d) must exceed idle skip threshold (%d)"
       guard
       skip_at)
    true
    (guard > skip_at)

(* The hook injects its final warning at [skip_at - 1]; the model needs at
   least one further turn to react before the guard aborts. Equivalent to
   the strict inequality above, stated separately so a future threshold
   reshuffle that breaks only the warning headroom still fails loudly. *)
let test_final_warning_has_a_reaction_turn () =
  let reactive = Masc.Keeper_runtime_resolved.reactive_max_idle_turns () in
  let autonomous = Masc.Keeper_runtime_resolved.autonomous_max_idle_turns () in
  let final_warning_at = skip_at - 1 in
  check bool
    (Printf.sprintf
       "reactive guard (%d) leaves a turn after final warning (%d)"
       reactive
       final_warning_at)
    true
    (reactive > final_warning_at + 1);
  check bool
    (Printf.sprintf
       "autonomous guard (%d) leaves a turn after final warning (%d)"
       autonomous
       final_warning_at)
    true
    (autonomous > final_warning_at + 1)

(* An env override below the hook's skip threshold must not be able to
   reintroduce the dead zone: resolution clamps the guard to
   skip_at + 1. This is the exact reproduction that used to fail —
   MASC_KEEPER_MAX_IDLE_TURNS_REACTIVE=3 with skip_at=4. *)
let with_env key value f =
  let prev = Sys.getenv_opt key in
  Unix.putenv key value;
  Fun.protect
    ~finally:(fun () ->
      (match prev with
       | Some v -> Unix.putenv key v
       | None -> Unix.putenv key "");
      Masc.Keeper_runtime_resolved.reset_for_tests ())
    f

let test_env_override_cannot_lower_guard_below_skip () =
  with_env "MASC_KEEPER_MAX_IDLE_TURNS_REACTIVE" "3" (fun () ->
    Masc.Keeper_runtime_resolved.reset_for_tests ();
    let guard = Masc.Keeper_runtime_resolved.reactive_max_idle_turns () in
    check bool
      (Printf.sprintf
         "override 3 resolves to %d, still above skip threshold (%d)"
         guard
         skip_at)
      true
      (guard > skip_at))

(* Regression: the heartbeat-loop Runtime_admitted skip branch must refresh
   last_turn_ts so the stale watchdog does not misclassify a legitimate
   no-work keeper as Idle_turn. The branch performs:
     1. record_skip_reasons
     2. touch_last_turn_ts
   Without step 2, the old timestamp stays in place and assess_stale_run
   returns Some (Stale_turn_timeout (Idle_turn _)). *)
let test_runtime_admitted_skip_refreshes_last_turn_ts () =
  let bp = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir bp)
    (fun () ->
      let name = "skip-touch-keeper" in
      let meta = make_meta name in
      let entry = Reg.register ~base_path:bp name meta in
      let stale_ts = 100.0 in
      let now = 300.0 in
      let threshold = 150.0 in
      (* touch_last_turn_ts uses wall-clock time, so fresh_ts will be far larger than now,
         keeping the keeper inside the threshold. *)
      (* Keeper completed a turn long ago. *)
      let stale_meta =
        let runtime = entry.meta.runtime in
        let usage = runtime.usage in
        { entry.meta with
          runtime = { runtime with usage = { usage with last_turn_ts = stale_ts } }
        }
      in
      Reg.update_meta ~base_path:bp name stale_meta;
      (* Model the Runtime_admitted skip branch: record reasons, then touch. *)
      let admitted_skip ~base_path name ~reasons =
        Reg.record_skip_reasons ~base_path name ~reasons;
        Reg.touch_last_turn_ts ~base_path name
      in
      (* Step 1 alone leaves last_turn_ts stale -> Idle_turn. *)
      Reg.record_skip_reasons ~base_path:bp name ~reasons:[ "no_signal" ];
      (match
         Sup.assess_stale_run
           ~phase:KSM.Running
           ~in_turn:None
           ~last_turn_ts:stale_ts
           ~started_at:0.0
           ~now
           ~threshold
       with
       | Some (Reg.Stale_turn_timeout (Reg.Idle_turn _)) -> ()
       | other ->
         fail
           (Printf.sprintf
              "record_skip_reasons alone should leave keeper stale (Idle_turn), got %s"
              (match other with
               | Some r -> Reg.failure_reason_to_string r
               | None -> "None")));
      (* Step 2 is the regression fix: touch_last_turn_ts refreshes activity. *)
      admitted_skip ~base_path:bp name ~reasons:[ "no_signal" ];
      match Reg.get ~base_path:bp name with
      | None -> fail "keeper should still be registered after admitted skip"
      | Some entry ->
        let fresh_ts = entry.meta.runtime.usage.last_turn_ts in
        check bool "touch_last_turn_ts advances last_turn_ts" true (fresh_ts > stale_ts);
        check bool
          "after admitted skip touch, assess_stale_run returns None"
          true
          (Option.is_none
             (Sup.assess_stale_run
                ~phase:KSM.Running
                ~in_turn:None
                ~last_turn_ts:fresh_ts
                ~started_at:0.0
                ~now
                ~threshold)))

let test_smart_idle_sleep_refreshes_last_turn_ts () =
  let bp = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir bp)
    (fun () ->
      let name = "smart-idle-touch-keeper" in
      let meta = make_meta name in
      let entry = Reg.register ~base_path:bp name meta in
      let stale_ts = 100.0 in
      let now = 300.0 in
      let threshold = 150.0 in
      let stale_meta =
        let runtime = entry.meta.runtime in
        let usage = runtime.usage in
        { entry.meta with
          runtime = { runtime with usage = { usage with last_turn_ts = stale_ts } }
        }
      in
      Reg.update_meta ~base_path:bp name stale_meta;
      Observations.record_smart_idle_sleep_observation ~base_path:bp ~keeper_name:name;
      match Reg.get ~base_path:bp name with
      | None -> fail "keeper should still be registered after smart idle observation"
      | Some entry ->
        let fresh_ts = entry.meta.runtime.usage.last_turn_ts in
        check bool "smart idle touch advances last_turn_ts" true (fresh_ts > stale_ts);
        (match entry.last_skip_observation with
         | Some (skip_ts, reasons) ->
           check bool "smart idle skip timestamp is fresh" true (skip_ts > stale_ts);
           check
             (list string)
             "smart idle skip reasons recorded"
             Observations.smart_idle_sleep_observation_reasons
             reasons
         | None -> fail "smart idle skip observation missing");
        check bool
          "after smart idle touch, assess_stale_run returns None"
          true
          (Option.is_none
             (Sup.assess_stale_run
                ~phase:KSM.Running
                ~in_turn:None
                ~last_turn_ts:fresh_ts
                ~started_at:0.0
                ~now
                ~threshold)))

let test_smart_idle_admission_refreshes_last_turn_ts_before_sleep () =
  let bp = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir bp)
    (fun () ->
      let name = "smart-idle-admission-touch-keeper" in
      let meta = make_meta name in
      let entry = Reg.register ~base_path:bp name meta in
      let stale_ts = 100.0 in
      let now = 300.0 in
      let threshold = 150.0 in
      let stale_meta =
        let runtime = entry.meta.runtime in
        let usage = runtime.usage in
        { entry.meta with
          runtime = { runtime with usage = { usage with last_turn_ts = stale_ts } }
        }
      in
      Reg.update_meta ~base_path:bp name stale_meta;
      Observations.record_smart_idle_sleep_admission ~base_path:bp ~keeper_name:name;
      match Reg.get ~base_path:bp name with
      | None -> fail "keeper should still be registered after smart idle admission"
      | Some entry ->
        let fresh_ts = entry.meta.runtime.usage.last_turn_ts in
        check bool "smart idle admission touch advances last_turn_ts" true
          (fresh_ts > stale_ts);
        (match entry.last_skip_observation with
         | Some (skip_ts, reasons) ->
           check bool "smart idle admission timestamp is fresh" true (skip_ts > stale_ts);
           check
             (list string)
             "smart idle admission reasons recorded"
             Observations.smart_idle_sleep_admission_reasons
             reasons
         | None -> fail "smart idle admission observation missing");
        check bool
          "after smart idle admission touch, assess_stale_run returns None"
          true
          (Option.is_none
             (Sup.assess_stale_run
                ~phase:KSM.Running
                ~in_turn:None
                ~last_turn_ts:fresh_ts
                ~started_at:0.0
                ~now
                ~threshold)))

let () =
  Alcotest.run
    "Keeper_idle_threshold_contract"
    [ ( "guard vs skip threshold"
      , [ test_case "reactive channel" `Quick test_reactive_guard_above_skip
        ; test_case "autonomous channel" `Quick test_autonomous_guard_above_skip
        ; test_case
            "final warning leaves a reaction turn"
            `Quick
            test_final_warning_has_a_reaction_turn
        ; test_case
            "env override cannot lower guard below skip"
            `Quick
            test_env_override_cannot_lower_guard_below_skip
        ; test_case
            "Runtime_admitted skip refreshes last_turn_ts"
            `Quick
            test_runtime_admitted_skip_refreshes_last_turn_ts
        ; test_case
            "smart idle sleep refreshes last_turn_ts"
            `Quick
            test_smart_idle_sleep_refreshes_last_turn_ts
        ; test_case
            "smart idle admission refreshes last_turn_ts before sleep"
            `Quick
            test_smart_idle_admission_refreshes_last_turn_ts_before_sleep
        ] )
    ]
