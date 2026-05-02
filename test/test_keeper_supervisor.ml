(** Test suite for Keeper_supervisor — fiber liveness tracking and recovery.
    Pure tests for backoff/helpers. Fiber health queries now delegate to
    Keeper_registry (tested in test_keeper_registry.ml). *)

open Alcotest
module Sup = Masc_mcp.Keeper_supervisor
module Reg = Masc_mcp.Keeper_registry
module KT = Masc_mcp.Keeper_types
module AQ = Masc_mcp.Keeper_approval_queue

let temp_dir () =
  let dir = Filename.temp_file "test_keeper_supervisor_" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir

let ensure_fs env =
  if not (Fs_compat.has_fs ()) then
    Fs_compat.set_fs (Eio.Stdenv.fs env)

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then begin
        Sys.readdir path |> Array.iter (fun name -> rm (Filename.concat path name));
        Unix.rmdir path
      end else
        Unix.unlink path
  in
  try rm dir with _ -> ()

(* ── Pure tests: backoff_delay ──────────────────────────── *)

let test_backoff_delay_attempt_0 () =
  (* Default base: 10.0s *)
  let d = Sup.backoff_delay 0 in
  check (float 0.1) "attempt 0 = base" 10.0 d

let test_backoff_delay_exponential () =
  let d1 = Sup.backoff_delay 1 in
  let d2 = Sup.backoff_delay 2 in
  let d3 = Sup.backoff_delay 3 in
  check (float 0.1) "attempt 1 = 2*base" 20.0 d1;
  check (float 0.1) "attempt 2 = 4*base" 40.0 d2;
  check (float 0.1) "attempt 3 = 8*base" 80.0 d3

let test_backoff_delay_cap () =
  (* Default max: 300.0s. 2^5 * 10 = 320 > 300 *)
  let d5 = Sup.backoff_delay 5 in
  check (float 0.1) "attempt 5 capped at 300" 300.0 d5;
  let d10 = Sup.backoff_delay 10 in
  check (float 0.1) "attempt 10 capped at 300" 300.0 d10

let test_auto_resume_first_delay_capped () =
  let delay =
    Sup.next_auto_resume_after_sec
      ~initial_sec:7200.0 ~max_sec:3600.0 None
  in
  check (option (float 0.1)) "first delay capped at max"
    (Some 3600.0) delay

let test_auto_resume_disabled () =
  let delay =
    Sup.next_auto_resume_after_sec
      ~initial_sec:0.0 ~max_sec:3600.0 (Some 1800.0)
  in
  check (option (float 0.1)) "initial <= 0 disables auto-resume"
    None delay

(* ── Pure tests: keep_last_n ────────────────────────────── *)

let test_keep_last_n_under_limit () =
  let result = Sup.keep_last_n 5 "a" ["b"; "c"] in
  check int "length 3" 3 (List.length result);
  check string "first is new item" "a" (List.hd result)

let test_keep_last_n_at_limit () =
  let result = Sup.keep_last_n 3 "a" ["b"; "c"] in
  check int "length 3" 3 (List.length result);
  check string "first is new item" "a" (List.hd result)

let test_keep_last_n_over_limit () =
  let result = Sup.keep_last_n 3 "a" ["b"; "c"; "d"] in
  check int "length capped at 3" 3 (List.length result);
  check string "first is new item" "a" (List.hd result);
  (* oldest item "d" should be dropped *)
  check bool "old item dropped" false (List.mem "d" result)

(* ── Registry-based tests (replacing removed supervisor Hashtbl queries) *)

let test_fiber_health_unknown () =
  Reg.clear ();
  let health = Reg.fiber_health_of ~base_path:"/tmp" "nonexistent-keeper" in
  check bool "unknown for unregistered"
    true (health = KT.Fiber_unknown)

let test_registry_count_initially_zero () =
  Reg.clear ();
  check int "no keepers initially" 0 (Reg.count_running ())

let test_crash_log_empty_for_unknown () =
  Reg.clear ();
  check int "empty crash log" 0
    (List.length (Reg.crash_log_of ~base_path:"/tmp" "nonexistent"))

let test_should_cleanup_dead_true () =
  Reg.clear ();
  let _entry = Reg.register ~base_path:"/tmp" "dead1"
      (let json = `Assoc [
        ("name", `String "dead1");
        ("agent_name", `String "agent-dead1");
        ("trace_id", `String "trace-dead1");
        ("goal", `String "goal");
        ("sandbox_profile", `String "local");
        ("network_mode", `String "inherit");
      ] in
      match KT.meta_of_json json with
      | Ok meta -> meta
      | Error err -> fail err)
  in
  Reg.mark_dead ~base_path:"/tmp" "dead1" ~at:10.0;
  let entry = Option.get (Reg.get ~base_path:"/tmp" "dead1") in
  check bool "ttl exceeded" true
    (Sup.should_cleanup_dead ~now:4000.0 ~dead_ttl_sec:3600.0 entry)

let test_should_cleanup_dead_false_when_recent () =
  Reg.clear ();
  let _entry = Reg.register ~base_path:"/tmp" "dead2"
      (let json = `Assoc [
        ("name", `String "dead2");
        ("agent_name", `String "agent-dead2");
        ("trace_id", `String "trace-dead2");
        ("goal", `String "goal");
        ("sandbox_profile", `String "local");
        ("network_mode", `String "inherit");
      ] in
      match KT.meta_of_json json with
      | Ok meta -> meta
      | Error err -> fail err)
  in
  Reg.mark_dead ~base_path:"/tmp" "dead2" ~at:100.0;
  let entry = Option.get (Reg.get ~base_path:"/tmp" "dead2") in
  check bool "ttl not exceeded" false
    (Sup.should_cleanup_dead ~now:200.0 ~dead_ttl_sec:3600.0 entry)

(* ── Property: backoff invariants ───────────────────────── *)

let test_backoff_monotonic_until_cap () =
  (* backoff(n) <= backoff(n+1) for all n until cap *)
  let cap = Sup.backoff_delay 20 in  (* at attempt 20, always at cap *)
  let rec check_mono i prev =
    if i > 20 then ()
    else begin
      let curr = Sup.backoff_delay i in
      check bool (Printf.sprintf "attempt %d >= prev" i)
        true (curr >= prev);
      check bool (Printf.sprintf "attempt %d <= cap" i)
        true (curr <= cap);
      check_mono (i + 1) curr
    end
  in
  check_mono 0 0.0

let test_backoff_never_negative () =
  for i = 0 to 30 do
    let d = Sup.backoff_delay i in
    check bool (Printf.sprintf "attempt %d >= 0" i) true (d >= 0.0)
  done

(* ── Property: keep_last_n invariants ──────────────────── *)

let test_keep_last_n_never_exceeds () =
  let n = 5 in
  let result = ref [] in
  for _i = 0 to 20 do
    result := Sup.keep_last_n n "x" !result
  done;
  check bool "length <= n" true (List.length !result <= n)

(* ── Property: self-preservation subset ────────────────── *)

let bp = "/tmp/test-sp-prop"
let make_meta name =
  let json = `Assoc [
    ("name", `String name);
    ("agent_name", `String ("agent-" ^ name));
    ("trace_id", `String ("trace-" ^ name));
    ("goal", `String "test");
    ("sandbox_profile", `String "local");
    ("network_mode", `String "inherit");
  ] in
  match KT.meta_of_json json with
  | Ok meta -> meta
  | Error err -> fail ("make_meta: " ^ err)

let test_self_preservation_subset () =
  Eio_main.run @@ fun _env ->
  Reg.clear ();
  let names = ["a"; "b"; "c"; "d"; "e"] in
  let entries = List.map (fun name ->
    let _reg = Reg.register ~base_path:bp name (make_meta name) in
    ignore (Reg.dispatch_event ~base_path:bp name
      (Masc_mcp.Keeper_state_machine.Fiber_terminated { outcome = "test" }));
    Reg.set_failure_reason ~base_path:bp name
      (Some (Reg.Heartbeat_consecutive_failures 3));
    match Reg.get ~base_path:bp name with
    | Some e -> (e, "crash") | None -> fail name
  ) names in
  let result = Sup.apply_self_preservation ~keepers_dir:"/tmp/test-keepers" ~total_keepers:10 entries in
  let result_names = List.map (fun ((e : Reg.registry_entry), _) -> e.name) result in
  let input_names = List.map (fun ((e : Reg.registry_entry), _) -> e.name) entries in
  List.iter (fun rn ->
    check bool (Printf.sprintf "%s in input" rn) true (List.mem rn input_names)
  ) result_names

let test_self_preservation_empty_input () =
  let result = Sup.apply_self_preservation ~keepers_dir:"/tmp/test-keepers" ~total_keepers:5 [] in
  check int "empty in = empty out" 0 (List.length result)

(* ── Runtime override: fiber_health_of ─────────────────── *)

let test_fiber_health_respects_max_restarts_override () =
  Reg.clear ();
  let name = "override-test-keeper" in
  let meta = make_meta name in
  let reg = Reg.register ~base_path:bp name meta in
  (* Simulate crash: resolve done_p as Crashed *)
  Eio.Promise.resolve reg.done_r (`Crashed "test crash");
  (* Set restart_count to 3 *)
  Reg.restore_supervisor_state ~base_path:bp name
    ~restart_count:3 ~last_restart_ts:0.0 ~crash_log:[];
  (* Default max_restarts is 5 (from env_config).
     With restart_count=3 and done_p=Crashed, health = Fiber_zombie *)
  let health_before = Reg.fiber_health_of ~base_path:bp name in
  check bool "zombie at 3/5 restarts (restartable)"
    true (health_before = KT.Fiber_zombie);
  (* Override max_restarts to 2 — now restart_count 3 >= 2 = dead *)
  (match Masc_mcp.Runtime_params.set
    Masc_mcp.Governance_registry.keeper_supervisor_max_restarts 2 with
  | Ok () -> ()
  | Error msg -> fail msg);
  let health_after = Reg.fiber_health_of ~base_path:bp name in
  check bool "dead at 3/2 restarts (overridden)"
    true (health_after = KT.Fiber_dead);
  (* Restore default *)
  Masc_mcp.Runtime_params.clear
    Masc_mcp.Governance_registry.keeper_supervisor_max_restarts;
  Reg.clear ()

let test_sweep_restores_reconcile_gate_for_paused_keeper () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Masc_mcp.Keeper_keepalive.stop_keepalive ~base_path:base_dir "paused-reconcile";
      Reg.clear ();
      Masc_mcp.Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      let config = Masc_mcp.Coord.default_config base_dir in
      ignore (Masc_mcp.Coord.init config ~agent_name:(Some "supervisor"));
      let base = make_meta "paused-reconcile" in
      let meta =
        {
          base with
          paused = true;
          autoboot_enabled = true;
          runtime =
            {
              base.runtime with
              last_blocker =
                "turn outcome ambiguous after committed mutating tool call(s): [keeper_board_cleanup]; retry disabled to avoid duplicate mutation; original_error=Completion contract [require_tool_use] violated";
            };
        }
      in
      (match KT.write_meta config meta with
       | Ok () -> ()
       | Error err -> fail err);
      let ctx : _ KT.context =
        {
          config;
          agent_name = "supervisor";
          sw;
          clock = Eio.Stdenv.clock env;
          proc_mgr = Some (Eio.Stdenv.process_mgr env);
          net = Some (Eio.Stdenv.net env);
        }
      in
      let pending_before = AQ.pending_count () in
      Sup.sweep_and_recover ctx;
      check bool "paused keeper has pending approval" true
        (AQ.has_pending_for_keeper ~keeper_name:meta.name);
      check int "approval count incremented"
        (pending_before + 1) (AQ.pending_count ());
      let approval_id =
        match AQ.list_pending_json () with
        | `List entries ->
            entries
            |> List.find_map (function
                 | `Assoc fields ->
                     let row = `Assoc fields in
                     if Yojson.Safe.Util.(row |> member "keeper_name" |> to_string_option)
                        = Some meta.name
                     then Yojson.Safe.Util.(row |> member "id" |> to_string_option)
                     else None
                 | _ -> None)
            |> Option.value ~default:""
        | _ -> ""
      in
      check bool "approval id present" true (approval_id <> "");
      (match AQ.resolve ~id:approval_id ~decision:Agent_sdk.Hooks.Approve with
       | Ok () -> ()
       | Error err -> fail ("resolve failed: " ^ AQ.resolve_error_to_string err));
      let resumed_meta =
        match KT.read_meta config meta.name with
        | Ok (Some value) -> value
        | Ok None -> fail "expected resumed keeper meta"
        | Error err -> fail err
      in
      check bool "paused cleared after approval" false resumed_meta.paused;
      check string "blocker cleared after approval" "" resumed_meta.runtime.last_blocker;
      check bool "keeper registered after approval" true
        (Reg.is_registered ~base_path:config.base_path meta.name))

let test_restart_path_emits_attempt_and_started_outcome_metrics () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let name = "restart-metric-keeper" in
  Fun.protect
    ~finally:(fun () ->
      Masc_mcp.Keeper_keepalive.stop_keepalive ~base_path:base_dir name;
      Reg.clear ();
      Masc_mcp.Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      let config = Masc_mcp.Coord.default_config base_dir in
      ignore (Masc_mcp.Coord.init config ~agent_name:(Some "supervisor"));
      let meta = make_meta name in
      (match KT.write_meta config meta with
       | Ok () -> ()
       | Error err -> fail err);
      let reg = Reg.register ~base_path:config.base_path name meta in
      Eio.Promise.resolve reg.done_r (`Crashed "ordinary crash");
      Reg.restore_supervisor_state ~base_path:config.base_path name
        ~restart_count:0 ~last_restart_ts:0.0 ~crash_log:[];
      let attempt_labels = [ ("keeper", name) ] in
      let outcome_labels = [ ("keeper", name); ("outcome", "started") ] in
      let attempts_before =
        Masc_mcp.Prometheus.metric_value_or_zero
          Masc_mcp.Prometheus.metric_keeper_restart_attempts
          ~labels:attempt_labels ()
      in
      let outcomes_before =
        Masc_mcp.Prometheus.metric_value_or_zero
          Masc_mcp.Prometheus.metric_keeper_restart_outcomes
          ~labels:outcome_labels ()
      in
      let ctx : _ KT.context =
        {
          config;
          agent_name = "supervisor";
          sw;
          clock = Eio.Stdenv.clock env;
          proc_mgr = Some (Eio.Stdenv.process_mgr env);
          net = Some (Eio.Stdenv.net env);
        }
      in
      Sup.sweep_and_recover ctx;
      check (float 0.001) "restart attempt metric incremented"
        (attempts_before +. 1.0)
        (Masc_mcp.Prometheus.metric_value_or_zero
           Masc_mcp.Prometheus.metric_keeper_restart_attempts
           ~labels:attempt_labels ());
      check (float 0.001) "restart started outcome metric incremented"
        (outcomes_before +. 1.0)
        (Masc_mcp.Prometheus.metric_value_or_zero
           Masc_mcp.Prometheus.metric_keeper_restart_outcomes
           ~labels:outcome_labels ());
      match Reg.get ~base_path:config.base_path name with
      | None -> fail "expected restarted keeper in registry"
      | Some entry ->
          check int "restart count restored to attempt" 1 entry.restart_count)

let test_restart_path_emits_meta_unavailable_outcome_metric () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let name = "restart-missing-meta-metric-keeper" in
  Fun.protect
    ~finally:(fun () ->
      Reg.clear ();
      Masc_mcp.Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      let config = Masc_mcp.Coord.default_config base_dir in
      ignore (Masc_mcp.Coord.init config ~agent_name:(Some "supervisor"));
      let meta = make_meta name in
      let reg = Reg.register ~base_path:config.base_path name meta in
      Eio.Promise.resolve reg.done_r (`Crashed "ordinary crash");
      Reg.restore_supervisor_state ~base_path:config.base_path name
        ~restart_count:0 ~last_restart_ts:0.0 ~crash_log:[];
      let attempt_labels = [ ("keeper", name) ] in
      let outcome_labels =
        [ ("keeper", name); ("outcome", "meta_unavailable") ]
      in
      let attempts_before =
        Masc_mcp.Prometheus.metric_value_or_zero
          Masc_mcp.Prometheus.metric_keeper_restart_attempts
          ~labels:attempt_labels ()
      in
      let outcomes_before =
        Masc_mcp.Prometheus.metric_value_or_zero
          Masc_mcp.Prometheus.metric_keeper_restart_outcomes
          ~labels:outcome_labels ()
      in
      let ctx : _ KT.context =
        {
          config;
          agent_name = "supervisor";
          sw;
          clock = Eio.Stdenv.clock env;
          proc_mgr = Some (Eio.Stdenv.process_mgr env);
          net = Some (Eio.Stdenv.net env);
        }
      in
      Sup.sweep_and_recover ctx;
      check (float 0.001) "restart attempt metric incremented"
        (attempts_before +. 1.0)
        (Masc_mcp.Prometheus.metric_value_or_zero
           Masc_mcp.Prometheus.metric_keeper_restart_attempts
           ~labels:attempt_labels ());
      check (float 0.001) "missing-meta outcome metric incremented"
        (outcomes_before +. 1.0)
        (Masc_mcp.Prometheus.metric_value_or_zero
           Masc_mcp.Prometheus.metric_keeper_restart_outcomes
           ~labels:outcome_labels ());
      check bool "keeper unregistered after missing meta" false
        (Reg.is_registered ~base_path:config.base_path name))

(* ── Dead-state loud alert (PR-C) ──────────────────────── *)

(* Reproduces the 2026-04-25 incident pattern: 8 keepers crashed silently
   after the supervisor exhausted max_restarts. The ERROR log + Prometheus
   counter + structured OAS event emitted from sweep_and_recover give
   operators the signal that was missing. *)
let test_max_restarts_exhaustion_emits_dead_alert () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Reg.clear ();
      Masc_mcp.Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      let config = Masc_mcp.Coord.default_config base_dir in
      ignore (Masc_mcp.Coord.init config ~agent_name:(Some "supervisor"));
      let name = "dead-alert-keeper" in
      let meta = make_meta name in
      (match KT.write_meta config meta with
       | Ok () -> ()
       | Error err -> fail err);
      let reg = Reg.register ~base_path:config.base_path name meta in
      (* Drive the entry to Crashed with restart_count already at the
         default budget (5) so sweep takes the Dead branch on the first
         pass, not the restart branch. *)
      Eio.Promise.resolve reg.done_r (`Crashed "synthetic exhaustion");
      Reg.set_failure_reason ~base_path:config.base_path name
        (Some (Reg.Heartbeat_consecutive_failures 9));
      let max_restarts =
        Masc_mcp.Runtime_params.get
          Masc_mcp.Governance_registry.keeper_supervisor_max_restarts
      in
      Reg.restore_supervisor_state ~base_path:config.base_path name
        ~restart_count:max_restarts ~last_restart_ts:0.0 ~crash_log:[];
      let baseline =
        Masc_mcp.Prometheus.metric_total
          Masc_mcp.Prometheus.metric_keeper_dead_total
      in
      let ctx : _ KT.context =
        {
          config;
          agent_name = "supervisor";
          sw;
          clock = Eio.Stdenv.clock env;
          proc_mgr = Some (Eio.Stdenv.process_mgr env);
          net = Some (Eio.Stdenv.net env);
        }
      in
      Sup.sweep_and_recover ctx;
      let after =
        Masc_mcp.Prometheus.metric_total
          Masc_mcp.Prometheus.metric_keeper_dead_total
      in
      check (float 0.001) "metric_keeper_dead_total incremented by 1"
        (baseline +. 1.0) after;
      (* Phase advanced to Dead. *)
      let phase =
        Reg.get_phase ~base_path:config.base_path name
        |> Option.value ~default:Masc_mcp.Keeper_state_machine.Running
      in
      check bool "keeper phase advanced to Dead"
        true (phase = Masc_mcp.Keeper_state_machine.Dead))

(* ── Phase 2 (#10765): stale-termination storm auto-pause ──────── *)

(* Reproduces the Mode A failure pattern from 2026-04-27 fleet observation:
   keeper proactive turn fails (cascade dead / oas_timeout_budget) → stale
   watchdog kills fiber → supervisor restarts → 30 min later same stale →
   restart loop with no operator-actionable signal beyond log ERROR.

   With Phase 2 latched as last_failure_reason = Stale_termination_storm,
   sweep_and_recover must:
   1. Skip [to_restart] enqueue (the regression we are preventing).
   2. Persist [meta.paused = true] on disk so reconcile + future sweeps
      respect the pause across server restarts.
   3. Increment [masc_keeper_stale_storm_paused_total] for observability.
   4. Leave [restart_count] unchanged (storm is not a restart attempt). *)
let test_stale_storm_pause_skips_restart () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Reg.clear ();
      Masc_mcp.Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      let config = Masc_mcp.Coord.default_config base_dir in
      ignore (Masc_mcp.Coord.init config ~agent_name:(Some "supervisor"));
      let name = "stale-storm-keeper" in
      let meta = make_meta name in
      (match KT.write_meta config meta with
       | Ok () -> ()
       | Error err -> fail err);
      let reg = Reg.register ~base_path:config.base_path name meta in
      Eio.Promise.resolve reg.done_r (`Crashed "synthetic stale storm");
      (* [restore_supervisor_state] resets [last_failure_reason] to [None],
         so it MUST run before [set_failure_reason] (otherwise the storm
         latch is wiped and the supervisor sweeps the entry through the
         default crash path).  Order matters here. *)
      Reg.restore_supervisor_state ~base_path:config.base_path name
        ~restart_count:0 ~last_restart_ts:0.0 ~crash_log:[];
      Reg.set_failure_reason ~base_path:config.base_path name
        (Some (Reg.Stale_termination_storm { count = 5 }));
      let baseline_pause =
        Masc_mcp.Prometheus.metric_total "masc_keeper_stale_storm_paused_total"
      in
      let baseline_dead =
        Masc_mcp.Prometheus.metric_total
          Masc_mcp.Prometheus.metric_keeper_dead_total
      in
      let ctx : _ KT.context =
        {
          config;
          agent_name = "supervisor";
          sw;
          clock = Eio.Stdenv.clock env;
          proc_mgr = Some (Eio.Stdenv.process_mgr env);
          net = Some (Eio.Stdenv.net env);
        }
      in
      Sup.sweep_and_recover ctx;
      let after_pause =
        Masc_mcp.Prometheus.metric_total "masc_keeper_stale_storm_paused_total"
      in
      let after_dead =
        Masc_mcp.Prometheus.metric_total
          Masc_mcp.Prometheus.metric_keeper_dead_total
      in
      check (float 0.001) "stale_storm_paused counter incremented by 1"
        (baseline_pause +. 1.0) after_pause;
      check (float 0.001) "dead counter NOT incremented (storm is not death)"
        baseline_dead after_dead;
      (* meta.paused must be true on disk so reconcile + future sweeps
         honor the pause across server restarts. *)
      (match KT.read_meta config name with
       | Ok (Some m) ->
           check bool "meta.paused = true after storm pause"
             true m.paused
       | Ok None -> fail "meta missing after storm pause"
       | Error err -> fail ("read_meta failed: " ^ err));
      (* In-memory registry entry is unregistered so subsequent sweeps do
         NOT re-fire the storm-pause path within the same server instance.
         Reconcile_keepalive_keepers will skip this keeper on its next pass
         because [meta.paused = true]. *)
      check bool "registry entry unregistered after storm pause"
        false (Reg.is_registered ~base_path:config.base_path name))

let test_oas_timeout_budget_loop_pause_skips_restart () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Reg.clear ();
      Masc_mcp.Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      let config = Masc_mcp.Coord.default_config base_dir in
      ignore (Masc_mcp.Coord.init config ~agent_name:(Some "supervisor"));
      let name = "oas-timeout-loop-keeper" in
      let meta = make_meta name in
      (match KT.write_meta config meta with
       | Ok () -> ()
       | Error err -> fail err);
      let reg = Reg.register ~base_path:config.base_path name meta in
      Eio.Promise.resolve reg.done_r (`Crashed "synthetic OAS budget loop");
      Reg.restore_supervisor_state ~base_path:config.base_path name
        ~restart_count:0 ~last_restart_ts:0.0 ~crash_log:[];
      Reg.set_failure_reason ~base_path:config.base_path name
        (Some (Reg.Oas_timeout_budget_loop { count = 3 }));
      let baseline_pause =
        Masc_mcp.Prometheus.metric_total
          "masc_keeper_oas_timeout_budget_loop_paused_total"
      in
      let baseline_dead =
        Masc_mcp.Prometheus.metric_total
          Masc_mcp.Prometheus.metric_keeper_dead_total
      in
      let ctx : _ KT.context =
        {
          config;
          agent_name = "supervisor";
          sw;
          clock = Eio.Stdenv.clock env;
          proc_mgr = Some (Eio.Stdenv.process_mgr env);
          net = Some (Eio.Stdenv.net env);
        }
      in
      Sup.sweep_and_recover ctx;
      let after_pause =
        Masc_mcp.Prometheus.metric_total
          "masc_keeper_oas_timeout_budget_loop_paused_total"
      in
      let after_dead =
        Masc_mcp.Prometheus.metric_total
          Masc_mcp.Prometheus.metric_keeper_dead_total
      in
      check (float 0.001) "oas_timeout_budget_loop counter incremented by 1"
        (baseline_pause +. 1.0) after_pause;
      check (float 0.001) "dead counter NOT incremented (budget loop is pause)"
        baseline_dead after_dead;
      (match KT.read_meta config name with
       | Ok (Some m) ->
           check bool "meta.paused = true after OAS budget loop pause"
             true m.paused
       | Ok None -> fail "meta missing after OAS budget loop pause"
       | Error err -> fail ("read_meta failed: " ^ err));
      check bool "registry entry unregistered after OAS budget loop pause"
        false (Reg.is_registered ~base_path:config.base_path name))

let test_unresolved_watchdog_stopped_budget_loop_is_reaped () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Reg.clear ();
      Masc_mcp.Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      let config = Masc_mcp.Coord.default_config base_dir in
      ignore (Masc_mcp.Coord.init config ~agent_name:(Some "supervisor"));
      let name = "unresolved-watchdog-stopped" in
      let meta = make_meta name in
      (match KT.write_meta config meta with
       | Ok () -> ()
       | Error err -> fail err);
      let reg = Reg.register ~base_path:config.base_path name meta in
      Atomic.set reg.fiber_stop true;
      Reg.restore_supervisor_state ~base_path:config.base_path name
        ~restart_count:0 ~last_restart_ts:0.0 ~crash_log:[];
      Reg.set_failure_reason ~base_path:config.base_path name
        (Some (Reg.Oas_timeout_budget_loop { count = 3 }));
      let ctx : _ KT.context =
        {
          config;
          agent_name = "supervisor";
          sw;
          clock = Eio.Stdenv.clock env;
          proc_mgr = Some (Eio.Stdenv.process_mgr env);
          net = Some (Eio.Stdenv.net env);
        }
      in
      Sup.sweep_and_recover ctx;
      (match KT.read_meta config name with
       | Ok (Some m) ->
           check bool "meta.paused = true after unresolved watchdog stop"
             true m.paused
       | Ok None -> fail "meta missing after unresolved watchdog stop"
       | Error err -> fail ("read_meta failed: " ^ err));
      check bool "unresolved watchdog-stopped entry reaped"
        false (Reg.is_registered ~base_path:config.base_path name))

(* Regression guard: a `Crashed entry whose last_failure_reason is NOT a
   storm must still flow through the existing restart-or-mark-dead branch.
   Verifies the new gate is variant-specific, not a blanket short-circuit. *)
let test_non_storm_crashed_restarts_normally () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Reg.clear ();
      Masc_mcp.Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      let config = Masc_mcp.Coord.default_config base_dir in
      ignore (Masc_mcp.Coord.init config ~agent_name:(Some "supervisor"));
      let name = "non-storm-keeper" in
      let meta = make_meta name in
      (match KT.write_meta config meta with
       | Ok () -> ()
       | Error err -> fail err);
      let reg = Reg.register ~base_path:config.base_path name meta in
      Eio.Promise.resolve reg.done_r (`Crashed "ordinary crash");
      let max_restarts =
        Masc_mcp.Runtime_params.get
          Masc_mcp.Governance_registry.keeper_supervisor_max_restarts
      in
      (* Set restart_count to max_restarts so the default crash branch routes
         to [to_mark_dead] (not [to_restart]).  The point of this regression
         test is verifying the storm-gate is variant-specific, not exercising
         the restart path (which would fork a heartbeat fiber and hang). *)
      Reg.restore_supervisor_state ~base_path:config.base_path name
        ~restart_count:max_restarts ~last_restart_ts:0.0 ~crash_log:[];
      Reg.set_failure_reason ~base_path:config.base_path name
        (Some (Reg.Heartbeat_consecutive_failures 3));
      let baseline_pause =
        Masc_mcp.Prometheus.metric_total "masc_keeper_stale_storm_paused_total"
      in
      let ctx : _ KT.context =
        {
          config;
          agent_name = "supervisor";
          sw;
          clock = Eio.Stdenv.clock env;
          proc_mgr = Some (Eio.Stdenv.process_mgr env);
          net = Some (Eio.Stdenv.net env);
        }
      in
      Sup.sweep_and_recover ctx;
      let after_pause =
        Masc_mcp.Prometheus.metric_total "masc_keeper_stale_storm_paused_total"
      in
      check (float 0.001) "stale_storm_paused counter NOT incremented for non-storm"
        baseline_pause after_pause;
      (* meta.paused stays false. *)
      (match KT.read_meta config name with
       | Ok (Some m) ->
           check bool "meta.paused stays false after non-storm crash"
             false m.paused
       | Ok None -> fail "meta missing"
       | Error err -> fail ("read_meta failed: " ^ err)))

(* ── Phase 3: self-healing circuit breaker ──────────────────── *)

(* Test: storm pause sets [auto_resume_after_sec] in meta. *)
let test_storm_pause_sets_auto_resume_after_sec () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Reg.clear ();
      Masc_mcp.Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      let config = Masc_mcp.Coord.default_config base_dir in
      ignore (Masc_mcp.Coord.init config ~agent_name:(Some "supervisor"));
      let name = "storm-auto-resume-setter" in
      let meta = make_meta name in
      (* Ensure no prior auto_resume_after_sec. *)
      check bool "initial auto_resume_after_sec = None"
        true (meta.auto_resume_after_sec = None);
      (match KT.write_meta config meta with
       | Ok () -> ()
       | Error err -> fail err);
      let reg = Reg.register ~base_path:config.base_path name meta in
      Eio.Promise.resolve reg.done_r (`Crashed "storm");
      Reg.restore_supervisor_state ~base_path:config.base_path name
        ~restart_count:0 ~last_restart_ts:0.0 ~crash_log:[];
      Reg.set_failure_reason ~base_path:config.base_path name
        (Some (Reg.Stale_termination_storm { count = 5 }));
      let ctx : _ KT.context =
        {
          config;
          agent_name = "supervisor";
          sw;
          clock = Eio.Stdenv.clock env;
          proc_mgr = Some (Eio.Stdenv.process_mgr env);
          net = Some (Eio.Stdenv.net env);
        }
      in
      Sup.sweep_and_recover ctx;
      (* After storm pause, meta must have auto_resume_after_sec set
         (initial value: 3600s from env default or test env override). *)
      (match KT.read_meta config name with
       | Ok (Some m) ->
           check bool "meta.paused = true" true m.paused;
           check bool "auto_resume_after_sec set (Some _)"
             true (Option.is_some m.auto_resume_after_sec)
       | Ok None -> fail "meta missing after storm pause"
       | Error err -> fail ("read_meta failed: " ^ err)))

(* Test: exponential back-off doubles on successive auto-pauses. *)
let test_auto_resume_after_sec_doubles_on_repause () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Reg.clear ();
      Masc_mcp.Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      let config = Masc_mcp.Coord.default_config base_dir in
      ignore (Masc_mcp.Coord.init config ~agent_name:(Some "supervisor"));
      let name = "backoff-doubles" in
      (* Simulate a keeper that was already auto-paused with 1h delay. *)
      let initial_meta =
        { (make_meta name) with
          auto_resume_after_sec = Some 3600.0;
        }
      in
      (match KT.write_meta config initial_meta with
       | Ok () -> ()
       | Error err -> fail err);
      let reg = Reg.register ~base_path:config.base_path name initial_meta in
      Eio.Promise.resolve reg.done_r (`Crashed "storm");
      Reg.restore_supervisor_state ~base_path:config.base_path name
        ~restart_count:0 ~last_restart_ts:0.0 ~crash_log:[];
      Reg.set_failure_reason ~base_path:config.base_path name
        (Some (Reg.Stale_termination_storm { count = 5 }));
      let ctx : _ KT.context =
        {
          config;
          agent_name = "supervisor";
          sw;
          clock = Eio.Stdenv.clock env;
          proc_mgr = Some (Eio.Stdenv.process_mgr env);
          net = Some (Eio.Stdenv.net env);
        }
      in
      Sup.sweep_and_recover ctx;
      (* Back-off must double: 3600 -> 7200. *)
      (match KT.read_meta config name with
       | Ok (Some m) ->
           check bool "meta.paused = true" true m.paused;
           (match m.auto_resume_after_sec with
            | Some sec ->
                check (float 0.1) "auto_resume_after_sec doubled to 7200"
                  7200.0 sec
            | None -> fail "auto_resume_after_sec should be Some after repause")
       | Ok None -> fail "meta missing after repause"
       | Error err -> fail ("read_meta failed: " ^ err)))

(* Test: Phase 3.5 sweep auto-resumes a keeper whose timer has elapsed. *)
let test_sweep_auto_resumes_after_backoff () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Reg.clear ();
      Masc_mcp.Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      let config = Masc_mcp.Coord.default_config base_dir in
      ignore (Masc_mcp.Coord.init config ~agent_name:(Some "supervisor"));
      let name = "auto-resume-keeper" in
      (* Simulate a keeper paused 2h ago with a 1h (3600s) auto-resume
         delay.  Since 7200 > 3600 the sweep should clear [paused]. *)
      let two_hours_ago =
        let t = Unix.gmtime (Unix.time () -. 7200.0) in
        Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
          (t.tm_year + 1900) (t.tm_mon + 1) t.tm_mday
          t.tm_hour t.tm_min t.tm_sec
      in
      let paused_meta =
        { (make_meta name) with
          paused = true;
          auto_resume_after_sec = Some 3600.0;
          updated_at = two_hours_ago;
        }
      in
      (match KT.write_meta config paused_meta with
       | Ok () -> ()
       | Error err -> fail err);
      let baseline_auto_resume =
        Masc_mcp.Prometheus.metric_total
          Masc_mcp.Prometheus.metric_keeper_auto_resumed_total
      in
      let ctx : _ KT.context =
        {
          config;
          agent_name = "supervisor";
          sw;
          clock = Eio.Stdenv.clock env;
          proc_mgr = Some (Eio.Stdenv.process_mgr env);
          net = Some (Eio.Stdenv.net env);
        }
      in
      Sup.sweep_and_recover ctx;
      (* meta.paused must be cleared after the back-off timer elapsed. *)
      (match KT.read_meta config name with
       | Ok (Some m) ->
           check bool "meta.paused = false after auto-resume"
             false m.paused;
           (* auto_resume_after_sec is retained (ready for next pause). *)
           check bool "auto_resume_after_sec retained for next cycle"
             true (Option.is_some m.auto_resume_after_sec)
       | Ok None -> fail "meta missing after auto-resume"
       | Error err -> fail ("read_meta failed: " ^ err));
      let after_auto_resume =
        Masc_mcp.Prometheus.metric_total
          Masc_mcp.Prometheus.metric_keeper_auto_resumed_total
      in
      check (float 0.001) "metric_keeper_auto_resumed_total incremented by 1"
        (baseline_auto_resume +. 1.0) after_auto_resume)

(* Test: operator-paused keeper ([auto_resume_after_sec = None]) is NOT
   auto-resumed by the sweep — only the human can clear it. *)
let test_operator_pause_not_auto_resumed () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Reg.clear ();
      Masc_mcp.Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      let config = Masc_mcp.Coord.default_config base_dir in
      ignore (Masc_mcp.Coord.init config ~agent_name:(Some "supervisor"));
      let name = "operator-paused-keeper" in
      (* Paused 2h ago with NO auto_resume_after_sec (operator pause). *)
      let two_hours_ago =
        let t = Unix.gmtime (Unix.time () -. 7200.0) in
        Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
          (t.tm_year + 1900) (t.tm_mon + 1) t.tm_mday
          t.tm_hour t.tm_min t.tm_sec
      in
      let paused_meta =
        { (make_meta name) with
          paused = true;
          auto_resume_after_sec = None;   (* operator pause *)
          updated_at = two_hours_ago;
        }
      in
      (match KT.write_meta config paused_meta with
       | Ok () -> ()
       | Error err -> fail err);
      let baseline_auto_resume =
        Masc_mcp.Prometheus.metric_total
          Masc_mcp.Prometheus.metric_keeper_auto_resumed_total
      in
      let ctx : _ KT.context =
        {
          config;
          agent_name = "supervisor";
          sw;
          clock = Eio.Stdenv.clock env;
          proc_mgr = Some (Eio.Stdenv.process_mgr env);
          net = Some (Eio.Stdenv.net env);
        }
      in
      Sup.sweep_and_recover ctx;
      (* meta.paused must remain true: operator pauses need human action. *)
      (match KT.read_meta config name with
       | Ok (Some m) ->
           check bool "meta.paused stays true for operator pause"
             true m.paused
       | Ok None -> fail "meta missing"
       | Error err -> fail ("read_meta failed: " ^ err));
      let after_auto_resume =
        Masc_mcp.Prometheus.metric_total
          Masc_mcp.Prometheus.metric_keeper_auto_resumed_total
      in
      check (float 0.001) "metric_keeper_auto_resumed_total NOT incremented"
        baseline_auto_resume after_auto_resume)

(* Regression test: initial delay is capped at max_sec even when
   MASC_KEEPER_AUTO_RESUME_INITIAL_SEC > MASC_KEEPER_AUTO_RESUME_MAX_SEC.
   The None -> initial_sec path must apply Float.min max_sec initial_sec. *)
let test_initial_auto_resume_capped_at_max () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Reg.clear ();
      Masc_mcp.Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      let config = Masc_mcp.Coord.default_config base_dir in
      ignore (Masc_mcp.Coord.init config ~agent_name:(Some "supervisor"));
      let name = "initial-cap-regression" in
      (* meta has no prior auto_resume_after_sec (first auto-pause). *)
      let meta = make_meta name in
      check bool "precondition: auto_resume_after_sec = None"
        true (meta.auto_resume_after_sec = None);
      (match KT.write_meta config meta with
       | Ok () -> ()
       | Error err -> fail err);
      let reg = Reg.register ~base_path:config.base_path name meta in
      Eio.Promise.resolve reg.done_r (`Crashed "storm");
      Reg.restore_supervisor_state ~base_path:config.base_path name
        ~restart_count:0 ~last_restart_ts:0.0 ~crash_log:[];
      Reg.set_failure_reason ~base_path:config.base_path name
        (Some (Reg.Stale_termination_storm { count = 5 }));
      (* Use explicit values because Env_config values are module-level
         bindings and cannot be reloaded per test. *)
      let initial_sec = 35996400.0 in
      let max_sec = 3600.0 in
      let capped = Float.min max_sec initial_sec in
      check (float 0.001) "Float.min max_sec initial_sec = max_sec"
        3600.0 capped;
      check bool "initial > max is captured by Float.min"
        true (initial_sec > max_sec && capped = max_sec);
      (* Also exercise the production path directly by constructing the
         same expression the supervisor uses, without relying on env-lazy
         module values that can't be reloaded per-test. *)
      let auto_resume_after_sec =
        Sup.next_auto_resume_after_sec ~initial_sec ~max_sec
          meta.auto_resume_after_sec
      in
      (match auto_resume_after_sec with
       | None -> fail "expected Some after storm pause"
       | Some v ->
           check (float 0.001)
             "first auto-pause delay capped at max_sec even when initial > max"
             3600.0 v);
      ignore (sw, reg))

(* ── Test runner ────────────────────────────────────────── *)

let () =
  run "keeper_supervisor" [
    "backoff", [
      test_case "attempt 0 = base" `Quick test_backoff_delay_attempt_0;
      test_case "exponential growth" `Quick test_backoff_delay_exponential;
      test_case "cap at max" `Quick test_backoff_delay_cap;
      test_case "first auto-resume delay capped at max" `Quick
        test_auto_resume_first_delay_capped;
      test_case "auto-resume disabled by zero initial delay" `Quick
        test_auto_resume_disabled;
    ];
    "keep_last_n", [
      test_case "under limit" `Quick test_keep_last_n_under_limit;
      test_case "at limit" `Quick test_keep_last_n_at_limit;
      test_case "over limit drops oldest" `Quick test_keep_last_n_over_limit;
    ];
    "fiber_health", [
      test_case "unknown for unregistered" `Quick test_fiber_health_unknown;
      test_case "registry count zero" `Quick test_registry_count_initially_zero;
      test_case "crash_log empty" `Quick test_crash_log_empty_for_unknown;
      test_case "should cleanup dead when ttl exceeded" `Quick test_should_cleanup_dead_true;
      test_case "should not cleanup dead when recent" `Quick test_should_cleanup_dead_false_when_recent;
    ];
    "backoff_properties", [
      test_case "monotonic until cap" `Quick test_backoff_monotonic_until_cap;
      test_case "never negative" `Quick test_backoff_never_negative;
    ];
    "keep_last_n_properties", [
      test_case "never exceeds limit" `Quick test_keep_last_n_never_exceeds;
    ];
    "self_preservation_properties", [
      test_case "output subset of input" `Quick test_self_preservation_subset;
      test_case "empty input → empty output" `Quick test_self_preservation_empty_input;
    ];
    "runtime_override", [
      test_case "fiber_health_of respects max_restarts override" `Quick
        test_fiber_health_respects_max_restarts_override;
    ];
    "reconcile_gate_recovery", [
      test_case "sweep restores reconcile gate for paused keeper" `Quick
        test_sweep_restores_reconcile_gate_for_paused_keeper;
    ];
    "restart_metrics", [
      test_case "restart path emits attempt and started outcome metrics" `Quick
        test_restart_path_emits_attempt_and_started_outcome_metrics;
      test_case "restart path emits missing-meta outcome metrics" `Quick
        test_restart_path_emits_meta_unavailable_outcome_metric;
    ];
    "dead_state_alert", [
      test_case "max_restarts exhaustion emits Dead alert" `Quick
        test_max_restarts_exhaustion_emits_dead_alert;
    ];
    "stale_storm_phase2", [
      test_case "Stale_termination_storm skips restart, persists paused, increments counter" `Quick
        test_stale_storm_pause_skips_restart;
      test_case "Oas_timeout_budget_loop skips restart, persists paused, increments counter" `Quick
        test_oas_timeout_budget_loop_pause_skips_restart;
      test_case "unresolved watchdog-stopped budget loop is reaped" `Quick
        test_unresolved_watchdog_stopped_budget_loop_is_reaped;
      test_case "non-storm Crashed still routes to restart (regression guard)" `Quick
        test_non_storm_crashed_restarts_normally;
    ];
    "self_healing_circuit_breaker", [
      test_case "storm pause sets auto_resume_after_sec" `Quick
        test_storm_pause_sets_auto_resume_after_sec;
      test_case "auto_resume_after_sec doubles on successive auto-pauses" `Quick
        test_auto_resume_after_sec_doubles_on_repause;
      test_case "sweep auto-resumes keeper when timer elapsed" `Quick
        test_sweep_auto_resumes_after_backoff;
      test_case "operator pause (None) is NOT auto-resumed by sweep" `Quick
        test_operator_pause_not_auto_resumed;
      test_case "initial delay capped at max_sec when initial > max (regression)" `Quick
        test_initial_auto_resume_capped_at_max;
    ];
  ]
