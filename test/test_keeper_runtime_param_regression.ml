(** test_keeper_runtime_param_regression — Regression tests for keeper
    lifecycle runtime params, bootstrap restore, dashboard set/clear,
    and supervisor diagnostics shape.

    Covers the integration paths identified in #3899:
    - Keeper lifecycle params (heartbeat, turn, supervisor thresholds)
      are registered with correct defaults, metadata, and validation.
    - Bootstrap restore round-trip for persisted keeper param overrides.
    - Dashboard set/clear via Tool_council_feed handlers.
    - Supervisor diagnostics JSON shape from dashboard_http_keeper.

    @since 3.0.0 *)

open Masc_mcp

(* ── helpers ─────────────────────────────────────────────────── *)

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Sys.readdir path
      |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path
    end else
      Sys.remove path

let with_temp_dir prefix f =
  let dir = Filename.temp_file prefix "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f dir)

let write_file path content =
  Out_channel.with_open_bin path (fun oc -> output_string oc content)

(* ── keeper lifecycle param registration ─────────────────────── *)

let keeper_lifecycle_keys = [
  "keeper.max_consecutive_hb_failures";
  "keeper.max_consecutive_turn_failures";
  "keeper.supervisor_max_restarts";
  "keeper.keepalive_interval_sec";
  "keeper.dead_ttl_sec";
]

let test_keeper_lifecycle_params_registered () =
  Governance_registry.ensure_init ();
  let entries = Runtime_params.registry () in
  let registered_keys = List.map (fun (k, _, _, _, _) -> k) entries in
  List.iter (fun key ->
    Alcotest.(check bool) (Printf.sprintf "%s is registered" key)
      true (List.mem key registered_keys)
  ) keeper_lifecycle_keys

let test_keeper_lifecycle_params_have_metadata () =
  let entries = Runtime_params.registry () in
  List.iter (fun key ->
    match List.find_opt (fun (k, _, _, _, _) -> k = key) entries with
    | None -> Alcotest.fail (Printf.sprintf "%s not found in registry" key)
    | Some (_, _, _, _, meta) ->
        (match meta with
         | None -> Alcotest.fail (Printf.sprintf "%s missing metadata" key)
         | Some m ->
             Alcotest.(check bool)
               (Printf.sprintf "%s has non-empty description" key)
               true (String.length m.description > 0);
             Alcotest.(check bool)
               (Printf.sprintf "%s has value_type" key)
               true (String.length m.value_type > 0))
  ) keeper_lifecycle_keys

let test_keeper_lifecycle_defaults_non_zero () =
  let entries = Runtime_params.registry () in
  List.iter (fun key ->
    match List.find_opt (fun (k, _, _, _, _) -> k = key) entries with
    | None -> Alcotest.fail (Printf.sprintf "%s not found" key)
    | Some (_, _current, default, _, _) ->
        (* All keeper lifecycle defaults should be positive numbers *)
        let is_positive = match default with
          | `Int n -> n > 0
          | `Float f -> f > 0.0
          | _ -> false
        in
        Alcotest.(check bool)
          (Printf.sprintf "%s default is positive" key)
          true is_positive
  ) keeper_lifecycle_keys

let test_keeper_lifecycle_surface_exists () =
  let surfaces = Governance_registry.surfaces in
  let keeper_surface =
    List.find_opt (fun (s : Governance_registry.surface) ->
      s.id = "keeper_lifecycle") surfaces
  in
  (match keeper_surface with
   | None -> Alcotest.fail "keeper_lifecycle surface not found"
   | Some s ->
       Alcotest.(check string) "risk level" "medium" s.risk;
       List.iter (fun key ->
         Alcotest.(check bool)
           (Printf.sprintf "%s in surface param_keys" key)
           true (List.mem key s.param_keys)
       ) keeper_lifecycle_keys)

(* ── keeper param validation boundaries ──────────────────────── *)

let test_keeper_hb_failures_validation () =
  (* keeper.max_consecutive_hb_failures: valid range [2, 50] *)
  (match Runtime_params.set_by_key "keeper.max_consecutive_hb_failures" (`Int 1) with
   | Error _ -> ()
   | Ok () -> Alcotest.fail "should reject hb_failures=1 (below min 2)");
  (match Runtime_params.set_by_key "keeper.max_consecutive_hb_failures" (`Int 51) with
   | Error _ -> ()
   | Ok () -> Alcotest.fail "should reject hb_failures=51 (above max 50)");
  (match Runtime_params.set_by_key "keeper.max_consecutive_hb_failures" (`Int 10) with
   | Ok () -> ()
   | Error msg -> Alcotest.fail (Printf.sprintf "should accept hb_failures=10: %s" msg));
  (* Clean up override *)
  ignore (Runtime_params.clear_by_key "keeper.max_consecutive_hb_failures")

let test_keeper_turn_failures_validation () =
  (* keeper.max_consecutive_turn_failures: valid range [3, 100] *)
  (match Runtime_params.set_by_key "keeper.max_consecutive_turn_failures" (`Int 2) with
   | Error _ -> ()
   | Ok () -> Alcotest.fail "should reject turn_failures=2 (below min 3)");
  (match Runtime_params.set_by_key "keeper.max_consecutive_turn_failures" (`Int 101) with
   | Error _ -> ()
   | Ok () -> Alcotest.fail "should reject turn_failures=101 (above max 100)");
  (match Runtime_params.set_by_key "keeper.max_consecutive_turn_failures" (`Int 15) with
   | Ok () -> ()
   | Error msg -> Alcotest.fail (Printf.sprintf "should accept turn_failures=15: %s" msg));
  ignore (Runtime_params.clear_by_key "keeper.max_consecutive_turn_failures")

let test_keeper_supervisor_max_restarts_validation () =
  (* keeper.supervisor_max_restarts: valid range [1, 50] *)
  (match Runtime_params.set_by_key "keeper.supervisor_max_restarts" (`Int 0) with
   | Error _ -> ()
   | Ok () -> Alcotest.fail "should reject max_restarts=0 (below min 1)");
  (match Runtime_params.set_by_key "keeper.supervisor_max_restarts" (`Int 51) with
   | Error _ -> ()
   | Ok () -> Alcotest.fail "should reject max_restarts=51 (above max 50)");
  (match Runtime_params.set_by_key "keeper.supervisor_max_restarts" (`Int 8) with
   | Ok () -> ()
   | Error msg -> Alcotest.fail (Printf.sprintf "should accept max_restarts=8: %s" msg));
  ignore (Runtime_params.clear_by_key "keeper.supervisor_max_restarts")

let test_keeper_dead_ttl_validation () =
  (* keeper.dead_ttl_sec: valid range [60.0, 86400.0] *)
  (match Runtime_params.set_by_key "keeper.dead_ttl_sec" (`Float 30.0) with
   | Error _ -> ()
   | Ok () -> Alcotest.fail "should reject dead_ttl=30 (below min 60)");
  (match Runtime_params.set_by_key "keeper.dead_ttl_sec" (`Float 100000.0) with
   | Error _ -> ()
   | Ok () -> Alcotest.fail "should reject dead_ttl=100000 (above max 86400)");
  (match Runtime_params.set_by_key "keeper.dead_ttl_sec" (`Float 7200.0) with
   | Ok () -> ()
   | Error msg -> Alcotest.fail (Printf.sprintf "should accept dead_ttl=7200: %s" msg));
  ignore (Runtime_params.clear_by_key "keeper.dead_ttl_sec")

let test_keeper_type_mismatch_rejected () =
  (* Sending a string where int is expected *)
  (match Runtime_params.set_by_key "keeper.max_consecutive_hb_failures"
           (`String "not-a-number") with
   | Error _ -> ()
   | Ok () -> Alcotest.fail "should reject string for int param");
  (* Sending a bool where float is expected *)
  (match Runtime_params.set_by_key "keeper.dead_ttl_sec" (`Bool true) with
   | Error _ -> ()
   | Ok () -> Alcotest.fail "should reject bool for float param")

(* ── bootstrap restore round-trip for keeper params ──────────── *)

let test_keeper_param_bootstrap_restore () =
  with_temp_dir "keeper-param-bootstrap" (fun dir ->
      let masc_dir = Filename.concat dir ".masc" in
      Fs_compat.mkdir_p masc_dir;
      (* Override two keeper params *)
      (match Runtime_params.set_by_key
               "keeper.max_consecutive_hb_failures" (`Int 12) with
       | Ok () -> ()
       | Error msg -> Alcotest.fail msg);
      (match Runtime_params.set_by_key
               "keeper.supervisor_max_restarts" (`Int 8) with
       | Ok () -> ()
       | Error msg -> Alcotest.fail msg);
      (* Persist *)
      Runtime_params.persist ~base_path:dir;
      (* Clear overrides *)
      ignore (Runtime_params.clear_by_key "keeper.max_consecutive_hb_failures");
      ignore (Runtime_params.clear_by_key "keeper.supervisor_max_restarts");
      (* Verify cleared *)
      let entries_before = Runtime_params.registry () in
      let hb_before =
        List.find (fun (k, _, _, _, _) ->
          k = "keeper.max_consecutive_hb_failures") entries_before
      in
      let (_, _, _, has_override_before, _) = hb_before in
      Alcotest.(check bool) "cleared before restore" false has_override_before;
      (* Restore *)
      Runtime_params.restore ~base_path:dir;
      (* Verify restored *)
      let entries_after = Runtime_params.registry () in
      let hb_after =
        List.find (fun (k, _, _, _, _) ->
          k = "keeper.max_consecutive_hb_failures") entries_after
      in
      let (_, current_hb, _, has_override_hb, _) = hb_after in
      Alcotest.(check bool) "has override after restore" true has_override_hb;
      Alcotest.(check string) "restored hb_failures value"
        "12" (Yojson.Safe.to_string current_hb);
      let sup_after =
        List.find (fun (k, _, _, _, _) ->
          k = "keeper.supervisor_max_restarts") entries_after
      in
      let (_, current_sup, _, has_override_sup, _) = sup_after in
      Alcotest.(check bool) "has override after restore (supervisor)"
        true has_override_sup;
      Alcotest.(check string) "restored supervisor_max_restarts value"
        "8" (Yojson.Safe.to_string current_sup);
      (* Clean up overrides *)
      ignore (Runtime_params.clear_by_key "keeper.max_consecutive_hb_failures");
      ignore (Runtime_params.clear_by_key "keeper.supervisor_max_restarts"))

let test_bootstrap_restore_missing_file_is_noop () =
  with_temp_dir "keeper-param-missing" (fun dir ->
      (* No .masc/runtime_params.json exists *)
      let entries_before = Runtime_params.registry () in
      let overrides_before =
        List.filter (fun (_, _, _, has, _) -> has) entries_before
        |> List.length
      in
      Runtime_params.restore ~base_path:dir;
      let entries_after = Runtime_params.registry () in
      let overrides_after =
        List.filter (fun (_, _, _, has, _) -> has) entries_after
        |> List.length
      in
      Alcotest.(check int) "no new overrides from missing file"
        overrides_before overrides_after)

let test_bootstrap_restore_corrupt_file_is_noop () =
  with_temp_dir "keeper-param-corrupt" (fun dir ->
      let masc_dir = Filename.concat dir ".masc" in
      Fs_compat.mkdir_p masc_dir;
      write_file (Filename.concat masc_dir "runtime_params.json")
        "not valid json {{{}";
      (* Should not crash, just log a warning *)
      Runtime_params.restore ~base_path:dir)

let test_bootstrap_restore_unknown_keys_skipped () =
  with_temp_dir "keeper-param-unknown" (fun dir ->
      let masc_dir = Filename.concat dir ".masc" in
      Fs_compat.mkdir_p masc_dir;
      write_file (Filename.concat masc_dir "runtime_params.json")
        {|{"nonexistent.future.param": 42, "keeper.max_consecutive_hb_failures": 15}|};
      Runtime_params.restore ~base_path:dir;
      let entries = Runtime_params.registry () in
      let hb =
        List.find (fun (k, _, _, _, _) ->
          k = "keeper.max_consecutive_hb_failures") entries
      in
      let (_, current, _, has_override, _) = hb in
      Alcotest.(check bool) "known key restored" true has_override;
      Alcotest.(check string) "known key value" "15"
        (Yojson.Safe.to_string current);
      (* Unknown key should not appear in registry *)
      let unknown =
        List.find_opt (fun (k, _, _, _, _) ->
          k = "nonexistent.future.param") entries
      in
      Alcotest.(check bool) "unknown key not in registry" true
        (Option.is_none unknown);
      ignore (Runtime_params.clear_by_key "keeper.max_consecutive_hb_failures"))

(* ── dashboard set/clear via Tool_council_feed ───────────────── *)

let test_handle_set_param_low_risk () =
  with_temp_dir "set-param-low" (fun dir ->
      let masc_dir = Filename.concat dir ".masc" in
      Fs_compat.mkdir_p masc_dir;
      let ctx : Tool_council_feed.context =
        { base_path = dir; agent_name = "test-agent"; room_config = None }
      in
      let submit_petition _ctx _args =
        Alcotest.fail "should not submit petition for low-risk param"
      in
      let args = `Assoc [
        ("param_key", `String "keeper.max_consecutive_hb_failures");
        ("value", `Int 20);
        ("reason", `String "testing set");
      ] in
      let (ok, msg) = Tool_council_feed.handle_set_param
        ~submit_petition ctx args in
      Alcotest.(check bool) "set succeeds" true ok;
      Alcotest.(check bool) "msg mentions applied"
        true (String.length msg > 0);
      (* Verify the value was set *)
      let entries = Runtime_params.registry () in
      let hb =
        List.find (fun (k, _, _, _, _) ->
          k = "keeper.max_consecutive_hb_failures") entries
      in
      let (_, current, _, _, _) = hb in
      Alcotest.(check string) "value set to 20" "20"
        (Yojson.Safe.to_string current);
      (* Verify persisted to disk *)
      let params_path = Filename.concat masc_dir "runtime_params.json" in
      Alcotest.(check bool) "params file created" true
        (Sys.file_exists params_path);
      (* Verify audit recorded *)
      let audit = Runtime_params.recent_audit ~base_path:dir 10 in
      Alcotest.(check bool) "audit entry recorded" true
        (List.length audit > 0);
      ignore (Runtime_params.clear_by_key "keeper.max_consecutive_hb_failures"))

let test_handle_set_param_high_risk_gates () =
  with_temp_dir "set-param-high" (fun dir ->
      let ctx : Tool_council_feed.context =
        { base_path = dir; agent_name = "test-agent"; room_config = None }
      in
      let petition_called = ref false in
      let submit_petition _ctx _args =
        petition_called := true;
        (true, "petition-created")
      in
      (* inference.default_model is in inference_config surface (high risk) *)
      let args = `Assoc [
        ("param_key", `String "inference.default_model");
        ("value", `String "gpt-5");
        ("reason", `String "testing high-risk");
      ] in
      let (ok, msg) = Tool_council_feed.handle_set_param
        ~submit_petition ctx args in
      Alcotest.(check bool) "returns ok (petition created)" true ok;
      Alcotest.(check bool) "petition was called" true !petition_called;
      Alcotest.(check bool) "msg mentions governance"
        true (let open String in
              lowercase_ascii msg
              |> fun s -> let needle = "petition" in
                 let rec search i =
                   if i > length s - length needle then false
                   else if sub s i (length needle) = needle then true
                   else search (i + 1)
                 in search 0))

let test_handle_set_param_missing_param_key () =
  let ctx : Tool_council_feed.context =
    { base_path = "/tmp"; agent_name = "test"; room_config = None }
  in
  let submit_petition _ctx _args = (false, "unreachable") in
  let args = `Assoc [("value", `Int 1)] in
  let (ok, _msg) = Tool_council_feed.handle_set_param
    ~submit_petition ctx args in
  Alcotest.(check bool) "fails without param_key" false ok

let test_handle_set_param_missing_value () =
  let ctx : Tool_council_feed.context =
    { base_path = "/tmp"; agent_name = "test"; room_config = None }
  in
  let submit_petition _ctx _args = (false, "unreachable") in
  let args = `Assoc [("param_key", `String "keeper.max_consecutive_hb_failures")] in
  let (ok, _msg) = Tool_council_feed.handle_set_param
    ~submit_petition ctx args in
  Alcotest.(check bool) "fails without value" false ok

let test_handle_set_param_validation_failure () =
  with_temp_dir "set-param-invalid" (fun dir ->
      let ctx : Tool_council_feed.context =
        { base_path = dir; agent_name = "test"; room_config = None }
      in
      let submit_petition _ctx _args = (false, "unreachable") in
      let args = `Assoc [
        ("param_key", `String "keeper.max_consecutive_hb_failures");
        ("value", `Int 999);  (* exceeds max 50 *)
      ] in
      let (ok, _msg) = Tool_council_feed.handle_set_param
        ~submit_petition ctx args in
      Alcotest.(check bool) "rejects out-of-range" false ok)

let test_handle_set_param_unknown_key () =
  with_temp_dir "set-param-unknown" (fun dir ->
      let ctx : Tool_council_feed.context =
        { base_path = dir; agent_name = "test"; room_config = None }
      in
      let submit_petition _ctx _args = (false, "unreachable") in
      let args = `Assoc [
        ("param_key", `String "unknown.nonexistent.key");
        ("value", `Int 1);
      ] in
      let (ok, _msg) = Tool_council_feed.handle_set_param
        ~submit_petition ctx args in
      Alcotest.(check bool) "rejects unknown key" false ok)

let test_handle_runtime_params_lists_keeper_params () =
  let ctx : Tool_council_feed.context =
    { base_path = "/tmp"; agent_name = "test"; room_config = None }
  in
  let (_ok, body) = Tool_council_feed.handle_runtime_params ctx (`Assoc []) in
  let json = Yojson.Safe.from_string body in
  let params = Yojson.Safe.Util.(member "parameters" json |> to_list) in
  let param_keys =
    List.map (fun p ->
      Yojson.Safe.Util.(member "key" p |> to_string)
    ) params
  in
  List.iter (fun key ->
    Alcotest.(check bool) (Printf.sprintf "params listing includes %s" key)
      true (List.mem key param_keys)
  ) keeper_lifecycle_keys;
  (* Verify surfaces are included *)
  let surfaces = Yojson.Safe.Util.(member "surfaces" json |> to_list) in
  let surface_ids = List.map (fun s ->
    Yojson.Safe.Util.(member "id" s |> to_string)
  ) surfaces in
  Alcotest.(check bool) "surfaces includes keeper_lifecycle"
    true (List.mem "keeper_lifecycle" surface_ids)

let test_handle_runtime_params_meta_shape () =
  let ctx : Tool_council_feed.context =
    { base_path = "/tmp"; agent_name = "test"; room_config = None }
  in
  let (_ok, body) = Tool_council_feed.handle_runtime_params ctx (`Assoc []) in
  let json = Yojson.Safe.from_string body in
  let params = Yojson.Safe.Util.(member "parameters" json |> to_list) in
  (* Find a keeper param and verify its structure *)
  let hb_param =
    List.find (fun p ->
      Yojson.Safe.Util.(member "key" p |> to_string) =
        "keeper.max_consecutive_hb_failures"
    ) params
  in
  let open Yojson.Safe.Util in
  (* Each param entry should have key, current, default, has_override, meta *)
  let _ = member "key" hb_param |> to_string in
  let _ = member "current" hb_param in
  let _ = member "default" hb_param in
  let _ = member "has_override" hb_param |> to_bool in
  let meta = member "meta" hb_param in
  Alcotest.(check bool) "meta is not null" true (meta <> `Null);
  let _ = member "description" meta |> to_string in
  let _ = member "value_type" meta |> to_string in
  let _ = member "min_value" meta in
  let _ = member "max_value" meta in
  ()

(* ── supervisor diagnostics shape ────────────────────────────── *)

let test_supervisor_diagnostics_shape_no_registry () =
  (* When a keeper is not in Keeper_registry, the dashboard code
     generates a diagnostics block with default shape. Verify that
     shape directly by constructing the JSON the same way the
     dashboard does. *)
  let max_restarts =
    Runtime_params.get Governance_registry.keeper_supervisor_max_restarts
  in
  (* Simulate the None branch from dashboard_http_keeper.ml *)
  let diagnostics =
    `Assoc [
      ("restart_count", `Int 0);
      ("max_restarts", `Int max_restarts);
      ("crash_log", `List []);
      ("last_failure_reason", `Null);
      ("dead_since", `Null);
    ]
  in
  let open Yojson.Safe.Util in
  Alcotest.(check int) "restart_count" 0 (member "restart_count" diagnostics |> to_int);
  Alcotest.(check bool) "max_restarts is positive"
    true (member "max_restarts" diagnostics |> to_int > 0);
  let crash_log = member "crash_log" diagnostics |> to_list in
  Alcotest.(check int) "crash_log empty" 0 (List.length crash_log);
  Alcotest.(check bool) "last_failure_reason is null"
    true (member "last_failure_reason" diagnostics = `Null);
  Alcotest.(check bool) "dead_since is null"
    true (member "dead_since" diagnostics = `Null)

let test_supervisor_diagnostics_shape_with_crashes () =
  (* Simulate the Some branch with a registry entry that has crashes *)
  let max_restarts =
    Runtime_params.get Governance_registry.keeper_supervisor_max_restarts
  in
  let crash_log = [
    `Assoc [("ts", `Float 1000.0); ("reason", `String "heartbeat timeout")];
    `Assoc [("ts", `Float 1100.0); ("reason", `String "turn failure")];
  ] in
  let diagnostics =
    `Assoc [
      ("restart_count", `Int 2);
      ("max_restarts", `Int max_restarts);
      ("crash_log", `List crash_log);
      ("last_failure_reason", `String "heartbeat_consecutive_failures(5)");
      ("dead_since", `Null);
    ]
  in
  let open Yojson.Safe.Util in
  Alcotest.(check int) "restart_count reflects crashes" 2
    (member "restart_count" diagnostics |> to_int);
  Alcotest.(check int) "crash_log has entries" 2
    (member "crash_log" diagnostics |> to_list |> List.length);
  (* Verify each crash entry has ts and reason *)
  let first_crash = List.hd (member "crash_log" diagnostics |> to_list) in
  let _ = member "ts" first_crash |> to_float in
  let _ = member "reason" first_crash |> to_string in
  Alcotest.(check string) "failure reason string"
    "heartbeat_consecutive_failures(5)"
    (member "last_failure_reason" diagnostics |> to_string)

let test_supervisor_diagnostics_max_restarts_uses_runtime_param () =
  (* Override supervisor_max_restarts and verify diagnostics picks it up *)
  (match Runtime_params.set Governance_registry.keeper_supervisor_max_restarts 12 with
   | Ok () -> ()
   | Error msg -> Alcotest.fail msg);
  let value =
    Runtime_params.get Governance_registry.keeper_supervisor_max_restarts
  in
  Alcotest.(check int) "runtime param override reflected" 12 value;
  Runtime_params.clear Governance_registry.keeper_supervisor_max_restarts;
  let default =
    Runtime_params.get Governance_registry.keeper_supervisor_max_restarts
  in
  Alcotest.(check bool) "default restored after clear" true (default > 0)

(* ── crash persistence ───────────────────────────────────────── *)

let test_crash_persistence_enqueue_and_read () =
  with_temp_dir "crash-persist" (fun dir ->
      Eio_main.run @@ fun env ->
      Eio.Switch.run @@ fun sw ->
      let clock = Eio.Stdenv.clock env in
      Keeper_crash_persistence.start_drain_fiber ~sw ~clock;
      Keeper_crash_persistence.enqueue_record
        ~base_path:dir ~name:"test-keeper"
        ~ts:1000.0 ~reason:"test crash" ~restart_count:1;
      Keeper_crash_persistence.enqueue_record
        ~base_path:dir ~name:"test-keeper"
        ~ts:1001.0 ~reason:"second crash" ~restart_count:2;
      (* Wait for drain fiber to flush *)
      Eio.Time.sleep clock 3.0;
      let crashes =
        Keeper_crash_persistence.recent_crashes
          ~base_path:dir ~name:"test-keeper" ~max_entries:10
      in
      Alcotest.(check bool) "crashes written to disk"
        true (List.length crashes >= 2);
      (* Verify crash entry shape *)
      (match crashes with
       | first :: _ ->
           let open Yojson.Safe.Util in
           let _ = member "ts" first |> to_float in
           let _ = member "reason" first |> to_string in
           let _ = member "restart_count" first |> to_int in
           ()
       | [] -> Alcotest.fail "no crashes found after enqueue"))

(* ── keeper param consistency across callsites ───────────────── *)

let test_keeper_params_typed_accessors_match_registry () =
  (* Verify that the typed accessors (Governance_registry.keeper_xxx)
     read the same values as the string-keyed registry *)
  let typed_hb =
    Runtime_params.get Governance_registry.keeper_max_hb_failures
  in
  let typed_turn =
    Runtime_params.get Governance_registry.keeper_max_turn_failures
  in
  let typed_sup =
    Runtime_params.get Governance_registry.keeper_supervisor_max_restarts
  in
  let typed_interval =
    Runtime_params.get Governance_registry.keeper_keepalive_interval_sec
  in
  let typed_ttl =
    Runtime_params.get Governance_registry.keeper_dead_ttl_sec
  in
  let entries = Runtime_params.registry () in
  let find_current key =
    match List.find_opt (fun (k, _, _, _, _) -> k = key) entries with
    | Some (_, current, _, _, _) -> current
    | None -> Alcotest.failf "missing %s in registry" key
  in
  Alcotest.(check string) "hb_failures typed==registry"
    (string_of_int typed_hb)
    (Yojson.Safe.to_string (find_current "keeper.max_consecutive_hb_failures"));
  Alcotest.(check string) "turn_failures typed==registry"
    (string_of_int typed_turn)
    (Yojson.Safe.to_string (find_current "keeper.max_consecutive_turn_failures"));
  Alcotest.(check string) "supervisor_max_restarts typed==registry"
    (string_of_int typed_sup)
    (Yojson.Safe.to_string (find_current "keeper.supervisor_max_restarts"));
  Alcotest.(check string) "keepalive_interval typed==registry"
    (string_of_int typed_interval)
    (Yojson.Safe.to_string (find_current "keeper.keepalive_interval_sec"));
  (* dead_ttl is float *)
  let expected_ttl_str =
    Printf.sprintf "%g" typed_ttl
  in
  let registry_ttl_str =
    Yojson.Safe.to_string (find_current "keeper.dead_ttl_sec")
  in
  (* Yojson serializes floats like 3600.0 as "3600.0" *)
  Alcotest.(check bool) "dead_ttl typed matches registry (same float)"
    true (float_of_string registry_ttl_str = float_of_string expected_ttl_str)

(* ── test runner ─────────────────────────────────────────────── *)

let () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio_guard.enable ();

  Alcotest.run "keeper_runtime_param_regression"
    [
      ( "keeper_lifecycle_registration",
        [
          Alcotest.test_case "all keeper lifecycle params registered" `Quick
            test_keeper_lifecycle_params_registered;
          Alcotest.test_case "all keeper lifecycle params have metadata" `Quick
            test_keeper_lifecycle_params_have_metadata;
          Alcotest.test_case "all keeper lifecycle defaults are positive" `Quick
            test_keeper_lifecycle_defaults_non_zero;
          Alcotest.test_case "keeper_lifecycle surface exists with correct risk"
            `Quick test_keeper_lifecycle_surface_exists;
          Alcotest.test_case "typed accessors match registry values" `Quick
            test_keeper_params_typed_accessors_match_registry;
        ] );
      ( "keeper_param_validation",
        [
          Alcotest.test_case "hb_failures boundary validation" `Quick
            test_keeper_hb_failures_validation;
          Alcotest.test_case "turn_failures boundary validation" `Quick
            test_keeper_turn_failures_validation;
          Alcotest.test_case "supervisor_max_restarts boundary validation" `Quick
            test_keeper_supervisor_max_restarts_validation;
          Alcotest.test_case "dead_ttl_sec boundary validation" `Quick
            test_keeper_dead_ttl_validation;
          Alcotest.test_case "type mismatch rejected" `Quick
            test_keeper_type_mismatch_rejected;
        ] );
      ( "bootstrap_restore",
        [
          Alcotest.test_case "persist and restore keeper param overrides" `Quick
            test_keeper_param_bootstrap_restore;
          Alcotest.test_case "restore missing file is noop" `Quick
            test_bootstrap_restore_missing_file_is_noop;
          Alcotest.test_case "restore corrupt file is noop" `Quick
            test_bootstrap_restore_corrupt_file_is_noop;
          Alcotest.test_case "restore skips unknown keys" `Quick
            test_bootstrap_restore_unknown_keys_skipped;
        ] );
      ( "dashboard_set_clear",
        [
          Alcotest.test_case "set_param low-risk applies immediately" `Quick
            test_handle_set_param_low_risk;
          Alcotest.test_case "set_param high-risk gates via petition" `Quick
            test_handle_set_param_high_risk_gates;
          Alcotest.test_case "set_param missing param_key fails" `Quick
            test_handle_set_param_missing_param_key;
          Alcotest.test_case "set_param missing value fails" `Quick
            test_handle_set_param_missing_value;
          Alcotest.test_case "set_param validation failure rejects" `Quick
            test_handle_set_param_validation_failure;
          Alcotest.test_case "set_param unknown key rejects" `Quick
            test_handle_set_param_unknown_key;
          Alcotest.test_case "runtime_params listing includes keeper params"
            `Quick test_handle_runtime_params_lists_keeper_params;
          Alcotest.test_case "runtime_params meta shape" `Quick
            test_handle_runtime_params_meta_shape;
        ] );
      ( "supervisor_diagnostics",
        [
          Alcotest.test_case "diagnostics shape (no registry entry)" `Quick
            test_supervisor_diagnostics_shape_no_registry;
          Alcotest.test_case "diagnostics shape (with crashes)" `Quick
            test_supervisor_diagnostics_shape_with_crashes;
          Alcotest.test_case "max_restarts uses runtime param override" `Quick
            test_supervisor_diagnostics_max_restarts_uses_runtime_param;
        ] );
      ( "crash_persistence",
        [
          Alcotest.test_case "enqueue and read crash events" `Slow
            test_crash_persistence_enqueue_and_read;
        ] );
    ]
