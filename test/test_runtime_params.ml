(** Tests for Runtime_params — typed parameter store with governance override. *)

open Masc_mcp

let rec rm_rf path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Sys.readdir path |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      try Unix.rmdir path with
      | Unix.Unix_error _ -> ())
    else (
      try Sys.remove path with
      | Sys_error _ -> ())
;;

let () =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let test_register_and_get () =
    (* Registration creates a param with default *)
    let p =
      Runtime_params.register
        ~key:"test.float_param"
        ~default:(fun () -> 42.0)
        ~validate:(fun v ->
          if v >= 0.0 && v <= 100.0 then Ok () else Error "out of range")
        ~serialize:(fun v -> `Float v)
        ~deserialize:(fun json ->
          match json with
          | `Float f -> Ok f
          | `Int i -> Ok (float_of_int i)
          | _ -> Error "expected number")
        ()
    in
    let v = Runtime_params.get p in
    Alcotest.(check (float 0.01)) "default value" 42.0 v
  in
  let test_set_and_get () =
    let p =
      Runtime_params.register
        ~key:"test.int_param"
        ~default:(fun () -> 10)
        ~validate:(fun v -> if v >= 1 && v <= 50 then Ok () else Error "out of range")
        ~serialize:(fun v -> `Int v)
        ~deserialize:(fun json ->
          match json with
          | `Int i -> Ok i
          | _ -> Error "expected int")
        ()
    in
    (match Runtime_params.set p 25 with
     | Ok () -> ()
     | Error msg -> Alcotest.fail msg);
    let v = Runtime_params.get p in
    Alcotest.(check int) "override value" 25 v
  in
  let test_validation_rejects () =
    let p =
      Runtime_params.register
        ~key:"test.validated_param"
        ~default:(fun () -> 5)
        ~validate:(fun v -> if v >= 1 && v <= 10 then Ok () else Error "must be 1-10")
        ~serialize:(fun v -> `Int v)
        ~deserialize:(fun json ->
          match json with
          | `Int i -> Ok i
          | _ -> Error "expected int")
        ()
    in
    (match Runtime_params.set p 99 with
     | Error _ -> ()
     | Ok () -> Alcotest.fail "should have rejected out-of-range value");
    let v = Runtime_params.get p in
    Alcotest.(check int) "unchanged after rejection" 5 v
  in
  let test_set_by_key () =
    let _p =
      Runtime_params.register
        ~key:"test.keyed_param"
        ~default:(fun () -> "hello")
        ~validate:(fun v -> if String.length v <= 20 then Ok () else Error "too long")
        ~serialize:(fun v -> `String v)
        ~deserialize:(fun json ->
          match json with
          | `String s -> Ok s
          | _ -> Error "expected string")
        ()
    in
    (match Runtime_params.set_by_key "test.keyed_param" (`String "world") with
     | Ok () -> ()
     | Error msg -> Alcotest.fail msg);
    (* Verify via registry *)
    let entries = Runtime_params.registry () in
    let entry = List.find_opt (fun (k, _, _, _, _) -> k = "test.keyed_param") entries in
    match entry with
    | Some (_, current, _, has_override, _meta) ->
      Alcotest.(check bool) "has override" true has_override;
      Alcotest.(check string) "current value" "\"world\"" (Yojson.Safe.to_string current)
    | None -> Alcotest.fail "keyed param not in registry"
  in
  let test_set_by_key_unknown () =
    match Runtime_params.set_by_key "nonexistent.param" (`Int 1) with
    | Error msg ->
      Alcotest.(check bool) "error mentions unknown" true (String.length msg > 0)
    | Ok () -> Alcotest.fail "should have rejected unknown key"
  in
  let test_clear () =
    let p =
      Runtime_params.register
        ~key:"test.clearable_param"
        ~default:(fun () -> 100)
        ~validate:(fun _ -> Ok ())
        ~serialize:(fun v -> `Int v)
        ~deserialize:(fun json ->
          match json with
          | `Int i -> Ok i
          | _ -> Error "expected int")
        ()
    in
    ignore (Runtime_params.set p 200);
    Alcotest.(check int) "overridden" 200 (Runtime_params.get p);
    Runtime_params.clear p;
    Alcotest.(check int) "cleared to default" 100 (Runtime_params.get p)
  in
  let test_persist_restore () =
    let tmp_dir = Filename.temp_dir "masc_test_" "" in
    let masc_dir = Filename.concat tmp_dir Common.masc_dirname in
    (try Sys.mkdir masc_dir 0o755 with
     | Sys_error _ -> ());
    let p =
      Runtime_params.register
        ~key:"test.persist_param"
        ~default:(fun () -> 1)
        ~validate:(fun _ -> Ok ())
        ~serialize:(fun v -> `Int v)
        ~deserialize:(fun json ->
          match json with
          | `Int i -> Ok i
          | _ -> Error "expected int")
        ()
    in
    ignore (Runtime_params.set p 42);
    Runtime_params.persist ~base_path:tmp_dir;
    (* Clear and restore *)
    Runtime_params.clear p;
    Alcotest.(check int) "after clear" 1 (Runtime_params.get p);
    Runtime_params.restore ~base_path:tmp_dir;
    Alcotest.(check int) "after restore" 42 (Runtime_params.get p);
    (* Cleanup *)
    try
      Sys.remove (Filename.concat masc_dir "runtime_params.json");
      Sys.rmdir masc_dir;
      Sys.rmdir tmp_dir
    with
    | Sys_error _ -> ()
  in
  let test_audit () =
    let tmp_dir = Filename.temp_dir "masc_audit_" "" in
    let masc_dir = Filename.concat tmp_dir Common.masc_dirname in
    (try Sys.mkdir masc_dir 0o755 with
     | Sys_error _ -> ());
    Runtime_params.record_audit
      ~base_path:tmp_dir
      ~key:"test.key"
      ~old_value:(`Int 1)
      ~new_value:(`Int 2)
      ~case_id:"case-001"
      ~actor:"system"
      ();
    Runtime_params.record_audit
      ~base_path:tmp_dir
      ~key:"test.key2"
      ~old_value:(`String "a")
      ~new_value:(`String "b")
      ~actor:"human"
      ();
    let entries = Runtime_params.recent_audit ~base_path:tmp_dir 10 in
    Alcotest.(check int) "audit entry count" 2 (List.length entries);
    (* Cleanup *)
    try
      Sys.remove (Filename.concat masc_dir "param_audit.jsonl");
      Sys.rmdir masc_dir;
      Sys.rmdir tmp_dir
    with
    | Sys_error _ -> ()
  in
  let test_governance_registry () =
    (* Verify that governance_registry registered params *)
    let entries = Runtime_params.registry () in
    let has key = List.exists (fun (k, _, _, _, _) -> k = key) entries in
    Alcotest.(check bool)
      "inference.default_model registered"
      true
      (has "inference.default_model");
    (* Validate surfaces *)
    let surfaces = Governance_registry.surfaces in
    Alcotest.(check bool) "has surfaces" true (List.length surfaces > 0);
    let surface_ids = List.map (fun (s : Governance_registry.surface) -> s.id) surfaces in
    Alcotest.(check bool)
      "inference_config surface"
      true
      (List.mem "inference_config" surface_ids)
  in
  let test_governance_registry_validation () =
    (* Default inference model should reject empty string *)
    match Runtime_params.set Governance_registry.inference_default_model "" with
    | Error _ -> ()
    | Ok () -> Alcotest.fail "should reject empty model name"
  in
  let test_dashboard_params_registered () =
    Governance_registry.ensure_init ();
    let entries = Runtime_params.registry () in
    let has key = List.exists (fun (k, _, _, _, _) -> k = key) entries in
    Alcotest.(check bool)
      "dashboard.agent_quiet_threshold_sec"
      true
      (has "dashboard.agent_quiet_threshold_sec");
    Alcotest.(check bool)
      "dashboard.agent_stuck_threshold_sec"
      true
      (has "dashboard.agent_stuck_threshold_sec")
  in
  let test_dashboard_surface () =
    let surfaces = Governance_registry.surfaces in
    let dashboard_surface =
      List.find_opt (fun (s : Governance_registry.surface) -> s.id = "dashboard") surfaces
    in
    match dashboard_surface with
    | None -> Alcotest.fail "dashboard surface not found"
    | Some s ->
      Alcotest.(check string) "risk" "low" s.risk;
      Alcotest.(check int) "param count" 7 (List.length s.param_keys);
      Alcotest.(check bool)
        "has quiet threshold"
        true
        (List.mem "dashboard.agent_quiet_threshold_sec" s.param_keys);
      Alcotest.(check bool)
        "has stuck threshold"
        true
        (List.mem "dashboard.agent_stuck_threshold_sec" s.param_keys)
  in
  (* ── clear_by_key ────────────────────────────────────────── *)
  let test_clear_by_key () =
    let _p =
      Runtime_params.register
        ~key:"test.clear_by_key_param"
        ~default:(fun () -> 50)
        ~validate:(fun _ -> Ok ())
        ~serialize:(fun v -> `Int v)
        ~deserialize:(fun json ->
          match json with
          | `Int i -> Ok i
          | _ -> Error "expected int")
        ()
    in
    (match Runtime_params.set_by_key "test.clear_by_key_param" (`Int 99) with
     | Ok () -> ()
     | Error msg -> Alcotest.fail ("set_by_key failed: " ^ msg));
    (match Runtime_params.clear_by_key "test.clear_by_key_param" with
     | Ok () -> ()
     | Error msg -> Alcotest.fail msg);
    let entries = Runtime_params.registry () in
    let entry =
      List.find_opt (fun (k, _, _, _, _) -> k = "test.clear_by_key_param") entries
    in
    match entry with
    | Some (_, current, _, has_override, _) ->
      Alcotest.(check bool) "no override after clear" false has_override;
      Alcotest.(check string) "back to default" "50" (Yojson.Safe.to_string current)
    | None -> Alcotest.fail "param not in registry"
  in
  let test_clear_by_key_unknown () =
    match Runtime_params.clear_by_key "nonexistent.clear" with
    | Error _ -> ()
    | Ok () -> Alcotest.fail "should reject unknown key"
  in
  (* ── keeper lifecycle params ─────────────────────────────── *)
  let test_keeper_params_registered () =
    Governance_registry.ensure_init ();
    let entries = Runtime_params.registry () in
    let has key = List.exists (fun (k, _, _, _, _) -> k = key) entries in
    Alcotest.(check bool)
      "keeper.max_consecutive_hb_failures"
      true
      (has "keeper.max_consecutive_hb_failures");
    Alcotest.(check bool)
      "keeper.max_consecutive_turn_failures"
      true
      (has "keeper.max_consecutive_turn_failures");
    Alcotest.(check bool)
      "keeper.supervisor_max_restarts"
      true
      (has "keeper.supervisor_max_restarts");
    Alcotest.(check bool)
      "keeper.keepalive_interval_sec"
      true
      (has "keeper.keepalive_interval_sec");
    Alcotest.(check bool) "keeper.dead_ttl_sec" true (has "keeper.dead_ttl_sec")
  in
  let test_keeper_lifecycle_surface () =
    let surfaces = Governance_registry.surfaces in
    let keeper_surface =
      List.find_opt
        (fun (s : Governance_registry.surface) -> s.id = "keeper_lifecycle")
        surfaces
    in
    match keeper_surface with
    | None -> Alcotest.fail "keeper_lifecycle surface not found"
    | Some s ->
      Alcotest.(check string) "risk" "medium" s.risk;
      Alcotest.(check int) "param count" 6 (List.length s.param_keys);
      Alcotest.(check bool)
        "has hb_failures"
        true
        (List.mem "keeper.max_consecutive_hb_failures" s.param_keys);
      Alcotest.(check bool)
        "has supervisor_max_restarts"
        true
        (List.mem "keeper.supervisor_max_restarts" s.param_keys);
      Alcotest.(check bool)
        "has supervisor_sweep_sec"
        true
        (List.mem "keeper.supervisor_sweep_sec" s.param_keys)
  in
  let test_keeper_diagnostics_surface () =
    Governance_registry.ensure_init ();
    let surfaces = Governance_registry.surfaces in
    let diag_surface =
      List.find_opt
        (fun (s : Governance_registry.surface) -> s.id = "keeper_diagnostics")
        surfaces
    in
    match diag_surface with
    | None -> Alcotest.fail "keeper_diagnostics surface not found"
    | Some s ->
      Alcotest.(check string) "risk" "medium" s.risk;
      Alcotest.(check int) "param count" 5 (List.length s.param_keys);
      Alcotest.(check bool)
        "has snapshot_sec"
        true
        (List.mem "keeper.snapshot_sec" s.param_keys);
      Alcotest.(check bool)
        "has work_as_hb_enabled"
        true
        (List.mem "keeper.work_as_hb_enabled" s.param_keys);
      Alcotest.(check bool)
        "has work_as_hb_max_silence_sec"
        true
        (List.mem "keeper.work_as_hb_max_silence_sec" s.param_keys);
      Alcotest.(check bool)
        "has smart_hb_enabled"
        true
        (List.mem "keeper.smart_hb_enabled" s.param_keys);
      Alcotest.(check bool)
        "has stage_timing_ring_size"
        true
        (List.mem "keeper.stage_timing_ring_size" s.param_keys)
  in
  let test_keeper_params_meta_shape () =
    Governance_registry.ensure_init ();
    let entries = Runtime_params.registry () in
    let hb_entry =
      List.find_opt
        (fun (k, _, _, _, _) -> k = "keeper.max_consecutive_hb_failures")
        entries
    in
    match hb_entry with
    | Some (_, _, _, _, Some meta) ->
      Alcotest.(check bool)
        "has description"
        true
        (String.length meta.Runtime_params.description > 0);
      Alcotest.(check string) "value_type" "int" meta.value_type;
      Alcotest.(check bool) "has min_value" true (meta.min_value <> None);
      Alcotest.(check bool) "has max_value" true (meta.max_value <> None)
    | Some (_, _, _, _, None) -> Alcotest.fail "meta is None"
    | None -> Alcotest.fail "keeper hb param not found"
  in
  let test_keeper_param_override_persist_restore () =
    let tmp_dir = Filename.temp_dir "masc_keeper_restore_" "" in
    let masc_dir = Filename.concat tmp_dir Common.masc_dirname in
    (try Sys.mkdir masc_dir 0o755 with
     | Sys_error _ -> ());
    (* Override a keeper param *)
    (match Runtime_params.set Governance_registry.keeper_max_hb_failures 7 with
     | Ok () -> ()
     | Error msg -> Alcotest.fail msg);
    Alcotest.(check int)
      "overridden"
      7
      (Runtime_params.get Governance_registry.keeper_max_hb_failures);
    (* Persist, clear, restore *)
    Runtime_params.persist ~base_path:tmp_dir;
    Runtime_params.clear Governance_registry.keeper_max_hb_failures;
    Alcotest.(check bool)
      "cleared to default"
      true
      (Runtime_params.get Governance_registry.keeper_max_hb_failures <> 7);
    Runtime_params.restore ~base_path:tmp_dir;
    Alcotest.(check int)
      "restored from disk"
      7
      (Runtime_params.get Governance_registry.keeper_max_hb_failures);
    (* Restore default for other tests *)
    Runtime_params.clear Governance_registry.keeper_max_hb_failures;
    try
      Sys.remove (Filename.concat masc_dir "runtime_params.json");
      Sys.rmdir masc_dir;
      Sys.rmdir tmp_dir
    with
    | Sys_error _ -> ()
  in
  (* Governance tool retirement — handle_set_param/clear_param/prompt_override
     tests are no longer applicable *)
  (* ── crash persistence ───────────────────────────────────── *)
  let test_crash_persistence_enqueue_read () =
    let tmp_dir = Filename.temp_dir "masc_crash_" "" in
    let clock = Eio.Stdenv.clock env in
    Eio.Switch.run
    @@ fun sw ->
    Keeper_crash_persistence.start_drain_fiber ~sw ~clock;
    let keepers_dir = Filename.concat tmp_dir "keepers" in
    Keeper_crash_persistence.enqueue_record
      ~keepers_dir
      ~name:"test-keeper"
      ~ts:1000.0
      ~reason:"heartbeat_failures"
      ~restart_count:1;
    Keeper_crash_persistence.enqueue_record
      ~keepers_dir
      ~name:"test-keeper"
      ~ts:1010.0
      ~reason:"exception"
      ~restart_count:2;
    (* Wait for drain fiber to flush (drain interval = 2s) *)
    Eio.Time.sleep clock 3.0;
    let crashes =
      Keeper_crash_persistence.recent_crashes
        ~keepers_dir
        ~name:"test-keeper"
        ~max_entries:10
    in
    Alcotest.(check bool) "has crash events" true (List.length crashes >= 2);
    (match crashes with
     | first :: _ ->
       let open Yojson.Safe.Util in
       let reason = member "reason" first |> to_string in
       Alcotest.(check bool) "reason is string" true (String.length reason > 0);
       let rc = member "restart_count" first |> to_int in
       Alcotest.(check bool) "restart_count >= 1" true (rc >= 1)
     | [] -> Alcotest.fail "no crashes read back");
    rm_rf tmp_dir
  in
  Alcotest.run
    "runtime_params"
    [ ( "core"
      , [ Alcotest.test_case "register_and_get" `Quick test_register_and_get
        ; Alcotest.test_case "set_and_get" `Quick test_set_and_get
        ; Alcotest.test_case "validation_rejects" `Quick test_validation_rejects
        ; Alcotest.test_case "set_by_key" `Quick test_set_by_key
        ; Alcotest.test_case "set_by_key_unknown" `Quick test_set_by_key_unknown
        ; Alcotest.test_case "clear" `Quick test_clear
        ; Alcotest.test_case "clear_by_key" `Quick test_clear_by_key
        ; Alcotest.test_case "clear_by_key_unknown" `Quick test_clear_by_key_unknown
        ] )
    ; ( "persistence"
      , [ Alcotest.test_case "persist_restore" `Quick test_persist_restore
        ; Alcotest.test_case "audit" `Quick test_audit
        ] )
    ; ( "governance_registry"
      , [ Alcotest.test_case "registration" `Quick test_governance_registry
        ; Alcotest.test_case "validation" `Quick test_governance_registry_validation
        ; Alcotest.test_case
            "dashboard params registered"
            `Quick
            test_dashboard_params_registered
        ; Alcotest.test_case "dashboard surface" `Quick test_dashboard_surface
        ] )
    ; ( "keeper_lifecycle"
      , [ Alcotest.test_case
            "keeper params registered"
            `Quick
            test_keeper_params_registered
        ; Alcotest.test_case
            "keeper_lifecycle surface"
            `Quick
            test_keeper_lifecycle_surface
        ; Alcotest.test_case
            "keeper params meta shape"
            `Quick
            test_keeper_params_meta_shape
        ; Alcotest.test_case
            "keeper param override persist/restore"
            `Quick
            test_keeper_param_override_persist_restore
        ; Alcotest.test_case
            "keeper_diagnostics surface"
            `Quick
            test_keeper_diagnostics_surface
        ] )
    ; ( "crash_persistence"
      , [ Alcotest.test_case "enqueue and read" `Slow test_crash_persistence_enqueue_read
        ] )
    ]
;;
