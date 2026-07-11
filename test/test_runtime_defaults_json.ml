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
    ; librarian_runtime_id = Some "openai.gpt-4o"
    ; structured_judge_runtime_id = Some "openai.gpt-4o"
    ; hitl_summary_runtime_id = Some "anthropic.sonnet"
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
  Alcotest.(check string) "librarian routing" "openai.gpt-4o"
    (member "librarian_runtime_id" routing |> Yojson.Safe.Util.to_string);
  Alcotest.(check string) "structured judge routing" "openai.gpt-4o"
    (member "structured_judge_runtime_id" routing |> Yojson.Safe.Util.to_string);
  Alcotest.(check string) "hitl summary routing" "anthropic.sonnet"
    (member "hitl_summary_runtime_id" routing |> Yojson.Safe.Util.to_string)

let test_build_uninitialized_emits_null_not_fabricated_default () =
  (* No fabrication: an unresolved runtime config surfaces null/empty, never a
     fake default model or runtime. *)
  let resolved : J.resolved =
    { default_runtime_id = None
    ; default_model = None
    ; default_max_context = None
    ; runtimes = []
    ; librarian_runtime_id = None
    ; structured_judge_runtime_id = None
    ; hitl_summary_runtime_id = None
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
  Alcotest.(check bool) "cross_verifier null" true
    (member "cross_verifier_runtime_id" routing = `Null);
  Alcotest.(check bool) "structured_judge null" true
    (member "structured_judge_runtime_id" routing = `Null);
  Alcotest.(check bool) "hitl_summary null" true
    (member "hitl_summary_runtime_id" routing = `Null)

let () =
  Alcotest.run "runtime_defaults_json"
    [ ( "build",
        [ Alcotest.test_case "serializes resolved defaults and routing" `Quick
            test_build_resolved_serializes_defaults_and_routing;
          Alcotest.test_case "uninitialized emits null (no fabrication)" `Quick
            test_build_uninitialized_emits_null_not_fabricated_default;
        ] );
    ]
