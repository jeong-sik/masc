(** Regression tests for keeping admitted and smart-idle observations live
    in the keeper registry's stale-run model. *)

open Alcotest
module Reg = Masc.Keeper_registry
module Sup = Masc.Keeper_supervisor
module KSM = Keeper_state_machine
module Keeper_meta_json_parse = Masc.Keeper_meta_json_parse
module Observations = Masc.Keeper_heartbeat_loop_observations

let temp_dir () =
  let dir = Filename.temp_file "test_keeper_idle_observation_liveness_" "" in
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
      ; ("network_mode", `String "host")
      ; ("tool_access", `List [])
      ]
  in
  match Keeper_meta_json_parse.meta_of_json json with
  | Ok meta -> meta
  | Error err -> fail ("make_meta: " ^ err)

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
    "Keeper_idle_observation_liveness"
    [ ( "registry liveness"
      , [ test_case
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
