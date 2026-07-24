module J = Server_dashboard_runtime_defaults_json

let member k json = Yojson.Safe.Util.member k json

let test_build_resolved_serializes_defaults_and_routing () =
  let resolved : J.resolved =
    { default_runtime_id = Some "openai.gpt-4o"
    ; default_model = Some "gpt-4o"
    ; default_max_context = Some 128000
    ; runtimes =
        [ { id = "openai.gpt-4o"
          ; provider = "OpenAI"
          ; model = "gpt-4o"
          ; max_context = 128000
          ; is_default = true
          }
        ; { id = "anthropic.sonnet"
          ; provider = "Anthropic"
          ; model = "claude-sonnet-4"
          ; max_context = 200000
          ; is_default = false
          }
        ]
    ; memory_os_consolidation_runtime_id = Some "anthropic.sonnet"
    ; memory_os_consolidation = J.Consolidation_resolved "anthropic.sonnet"
    ; structured_judge_runtime_id = Some "openai.gpt-4o"
    ; cross_verifier_runtime_id = None
    ; media_failover = [ "openai.gpt-4o" ]
    ; config_path = Some "/cfg/runtime.toml"
    }
  in
  let json = J.build ~generated_at_iso:"2026-06-21T00:00:00Z" resolved in
  Alcotest.(check string)
    "default_runtime_id" "openai.gpt-4o"
    (member "default_runtime_id" json |> Yojson.Safe.Util.to_string);
  Alcotest.(check string)
    "default_model" "gpt-4o"
    (member "default_model" json |> Yojson.Safe.Util.to_string);
  Alcotest.(check int)
    "default_max_context" 128000
    (member "default_max_context" json |> Yojson.Safe.Util.to_int);
  Alcotest.(check string)
    "source" "runtime_config"
    (member "source" json |> Yojson.Safe.Util.to_string);
  let runtimes = member "runtimes" json |> Yojson.Safe.Util.to_list in
  Alcotest.(check int) "runtimes length" 2 (List.length runtimes);
  let first = List.hd runtimes in
  Alcotest.(check string) "runtime id" "openai.gpt-4o"
    (member "id" first |> Yojson.Safe.Util.to_string);
  Alcotest.(check bool) "runtime is_default" true
    (member "is_default" first |> Yojson.Safe.Util.to_bool);
  let routing = member "model_routing" json in
  Alcotest.(check string)
    "Memory OS consolidation status" "resolved"
    (member "memory_os_consolidation_status" routing
     |> Yojson.Safe.Util.to_string);
  Alcotest.(check string)
    "Memory OS consolidation configured selector" "anthropic.sonnet"
    (member "memory_os_consolidation_runtime_id" routing
     |> Yojson.Safe.Util.to_string);
  Alcotest.(check string)
    "Memory OS consolidation effective runtime" "anthropic.sonnet"
    (member "memory_os_consolidation_effective_runtime_id" routing
     |> Yojson.Safe.Util.to_string);
  Alcotest.(check bool)
    "Memory OS consolidation error is null"
    true
    (member "memory_os_consolidation_error" routing = `Null);
  Alcotest.(check string) "structured judge routing" "openai.gpt-4o"
    (member "structured_judge_runtime_id" routing |> Yojson.Safe.Util.to_string)
let test_build_uninitialized_emits_null_not_fabricated_default () =
  (* No fabrication: an unresolved runtime config surfaces null/empty, never a
     fake default model or runtime. *)
  let resolved : J.resolved =
    { default_runtime_id = None
    ; default_model = None
    ; default_max_context = None
    ; runtimes = []
    ; memory_os_consolidation_runtime_id = None
    ; memory_os_consolidation =
        J.Consolidation_error "runtime state is not initialized"
    ; structured_judge_runtime_id = None
    ; cross_verifier_runtime_id = None
    ; media_failover = []
    ; config_path = None
    }
  in
  let json = J.build ~generated_at_iso:"2026-06-21T00:00:00Z" resolved in
  Alcotest.(check bool) "default_runtime_id is null" true
    (member "default_runtime_id" json = `Null);
  Alcotest.(check bool) "default_model is null" true
    (member "default_model" json = `Null);
  Alcotest.(check int) "runtimes empty" 0
    (member "runtimes" json |> Yojson.Safe.Util.to_list |> List.length);
  let routing = member "model_routing" json in
  Alcotest.(check string)
    "Memory OS consolidation status" "error"
    (member "memory_os_consolidation_status" routing
     |> Yojson.Safe.Util.to_string);
  Alcotest.(check bool) "Memory OS consolidation runtime is null" true
    (member "memory_os_consolidation_runtime_id" routing = `Null);
  Alcotest.(check bool) "Memory OS consolidation effective runtime is null" true
    (member "memory_os_consolidation_effective_runtime_id" routing = `Null);
  Alcotest.(check string)
    "Memory OS consolidation error"
    "runtime state is not initialized"
    (member "memory_os_consolidation_error" routing
     |> Yojson.Safe.Util.to_string);
  Alcotest.(check bool) "cross_verifier null" true
    (member "cross_verifier_runtime_id" routing = `Null);
  Alcotest.(check bool) "structured_judge null" true
    (member "structured_judge_runtime_id" routing = `Null)

let test_build_inherited_consolidation_route () =
  let resolved : J.resolved =
    { default_runtime_id = Some "local.chat"
    ; default_model = Some "chat"
    ; default_max_context = Some 1024
    ; runtimes = []
    ; memory_os_consolidation_runtime_id = None
    ; memory_os_consolidation = J.Consolidation_inherited "local.chat"
    ; structured_judge_runtime_id = None
    ; cross_verifier_runtime_id = None
    ; media_failover = []
    ; config_path = Some "/cfg/runtime.toml"
    }
  in
  let routing =
    J.build ~generated_at_iso:"2026-07-24T00:00:00Z" resolved
    |> member "model_routing"
  in
  Alcotest.(check string)
    "inherited status"
    "inherited"
    (member "memory_os_consolidation_status" routing
     |> Yojson.Safe.Util.to_string);
  Alcotest.(check bool)
    "inherited selector remains null"
    true
    (member "memory_os_consolidation_runtime_id" routing = `Null);
  Alcotest.(check string)
    "inherited effective runtime"
    "local.chat"
    (member "memory_os_consolidation_effective_runtime_id" routing
     |> Yojson.Safe.Util.to_string);
  Alcotest.(check bool)
    "inherited error is null"
    true
    (member "memory_os_consolidation_error" routing = `Null)

let test_build_missing_configured_consolidation_route () =
  let error = "configured consolidation runtime is absent" in
  let resolved : J.resolved =
    { default_runtime_id = Some "local.chat"
    ; default_model = Some "chat"
    ; default_max_context = Some 1024
    ; runtimes = []
    ; memory_os_consolidation_runtime_id = Some "local.missing"
    ; memory_os_consolidation = J.Consolidation_error error
    ; structured_judge_runtime_id = None
    ; cross_verifier_runtime_id = None
    ; media_failover = []
    ; config_path = Some "/cfg/runtime.toml"
    }
  in
  let routing =
    J.build ~generated_at_iso:"2026-07-24T00:00:00Z" resolved
    |> member "model_routing"
  in
  Alcotest.(check string)
    "missing configured status"
    "error"
    (member "memory_os_consolidation_status" routing
     |> Yojson.Safe.Util.to_string);
  Alcotest.(check string)
    "missing configured selector preserved"
    "local.missing"
    (member "memory_os_consolidation_runtime_id" routing
     |> Yojson.Safe.Util.to_string);
  Alcotest.(check bool)
    "missing configured effective runtime is null"
    true
    (member "memory_os_consolidation_effective_runtime_id" routing = `Null);
  Alcotest.(check string)
    "missing configured error"
    error
    (member "memory_os_consolidation_error" routing
     |> Yojson.Safe.Util.to_string)

let test_uninitialized_runtime_snapshot_surfaces_error () =
  let snapshot = Runtime.dashboard_runtime_defaults_snapshot () in
  let resolved = J.resolved_of_snapshot snapshot in
  match snapshot.memory_os_consolidation, resolved.memory_os_consolidation with
  | Error expected, J.Consolidation_error actual ->
    Alcotest.(check string) "snapshot error preserved" expected actual;
    Alcotest.(check (option string))
      "uninitialized configured selector remains absent"
      None
      resolved.memory_os_consolidation_runtime_id
  | Ok _, _ -> Alcotest.fail "uninitialized Runtime snapshot unexpectedly resolved"
  | Error _, _ -> Alcotest.fail "dashboard projection discarded Runtime snapshot error"

let () =
  Alcotest.run "runtime_defaults_json"
    [ ( "build",
        [ Alcotest.test_case "serializes resolved defaults and routing" `Quick
            test_build_resolved_serializes_defaults_and_routing;
          Alcotest.test_case "uninitialized emits null (no fabrication)" `Quick
            test_build_uninitialized_emits_null_not_fabricated_default;
          Alcotest.test_case "serializes inherited consolidation route" `Quick
            test_build_inherited_consolidation_route;
          Alcotest.test_case "preserves missing configured selector" `Quick
            test_build_missing_configured_consolidation_route;
          Alcotest.test_case "preserves uninitialized snapshot error" `Quick
            test_uninitialized_runtime_snapshot_surfaces_error;
        ] );
    ]
