(** Tests for Runtime_params — typed parameter store with governance override. *)

open Masc_mcp

let () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);

  let test_register_and_get () =
    (* Registration creates a param with default *)
    let p =
      Runtime_params.register
        ~key:"test.float_param"
        ~default:(fun () -> 42.0)
        ~validate:(fun v ->
          if v >= 0.0 && v <= 100.0 then Ok ()
          else Error "out of range")
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
        ~validate:(fun v ->
          if v >= 1 && v <= 50 then Ok ()
          else Error "out of range")
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
        ~validate:(fun v ->
          if v >= 1 && v <= 10 then Ok ()
          else Error "must be 1-10")
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
        ~validate:(fun v ->
          if String.length v <= 20 then Ok ()
          else Error "too long")
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
    let entry =
      List.find_opt (fun (k, _, _, _, _) -> k = "test.keyed_param") entries
    in
    (match entry with
     | Some (_, current, _, has_override, _meta) ->
         Alcotest.(check bool) "has override" true has_override;
         Alcotest.(check string) "current value"
           "\"world\"" (Yojson.Safe.to_string current)
     | None -> Alcotest.fail "keyed param not in registry")
  in

  let test_set_by_key_unknown () =
    match Runtime_params.set_by_key "nonexistent.param" (`Int 1) with
    | Error msg ->
        Alcotest.(check bool) "error mentions unknown"
          true (String.length msg > 0)
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
    let masc_dir = Filename.concat tmp_dir ".masc" in
    (try Sys.mkdir masc_dir 0o755 with Sys_error _ -> ());
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
    (try
       Sys.remove (Filename.concat masc_dir "runtime_params.json");
       Sys.rmdir masc_dir;
       Sys.rmdir tmp_dir
     with Sys_error _ -> ())
  in

  let test_audit () =
    let tmp_dir = Filename.temp_dir "masc_audit_" "" in
    let masc_dir = Filename.concat tmp_dir ".masc" in
    (try Sys.mkdir masc_dir 0o755 with Sys_error _ -> ());
    Runtime_params.record_audit ~base_path:tmp_dir
      ~key:"test.key" ~old_value:(`Int 1) ~new_value:(`Int 2)
      ~case_id:"case-001" ~actor:"system" ();
    Runtime_params.record_audit ~base_path:tmp_dir
      ~key:"test.key2" ~old_value:(`String "a") ~new_value:(`String "b")
      ~actor:"human" ();
    let entries = Runtime_params.recent_audit ~base_path:tmp_dir 10 in
    Alcotest.(check int) "audit entry count" 2 (List.length entries);
    (* Cleanup *)
    (try
       Sys.remove (Filename.concat masc_dir "param_audit.jsonl");
       Sys.rmdir masc_dir;
       Sys.rmdir tmp_dir
     with Sys_error _ -> ())
  in

  let test_governance_registry () =
    (* Verify that governance_registry registered params *)
    let entries = Runtime_params.registry () in
    let has key =
      List.exists (fun (k, _, _, _, _) -> k = key) entries
    in
    Alcotest.(check bool) "inference.default_model registered"
      true (has "inference.default_model");
    (* Validate surfaces *)
    let surfaces = Governance_registry.surfaces in
    Alcotest.(check bool) "has surfaces" true (List.length surfaces > 0);
    let surface_ids =
      List.map (fun (s : Governance_registry.surface) -> s.id) surfaces
    in
    Alcotest.(check bool) "inference_config surface"
      true (List.mem "inference_config" surface_ids)
  in

  let test_governance_registry_validation () =
    (* Default inference model should reject empty string *)
    (match Runtime_params.set Governance_registry.inference_default_model "" with
     | Error _ -> ()
     | Ok () -> Alcotest.fail "should reject empty model name")
  in

  Alcotest.run "runtime_params"
    [
      ( "core",
        [
          Alcotest.test_case "register_and_get" `Quick test_register_and_get;
          Alcotest.test_case "set_and_get" `Quick test_set_and_get;
          Alcotest.test_case "validation_rejects" `Quick test_validation_rejects;
          Alcotest.test_case "set_by_key" `Quick test_set_by_key;
          Alcotest.test_case "set_by_key_unknown" `Quick test_set_by_key_unknown;
          Alcotest.test_case "clear" `Quick test_clear;
        ] );
      ( "persistence",
        [
          Alcotest.test_case "persist_restore" `Quick test_persist_restore;
          Alcotest.test_case "audit" `Quick test_audit;
        ] );
      ( "governance_registry",
        [
          Alcotest.test_case "registration" `Quick test_governance_registry;
          Alcotest.test_case "validation" `Quick test_governance_registry_validation;
        ] );
    ]
