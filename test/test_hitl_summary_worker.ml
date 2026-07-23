open Alcotest

module Q = Masc.Keeper_approval_queue
module Worker = Masc.Hitl_summary_worker
module Schema = Masc.Keeper_structured_output_schema
module Runtime_resolved = Masc.Keeper_runtime_resolved

let yojson = testable Yojson.Safe.pretty_print Yojson.Safe.equal

let exact_runtime_id = "local.auto_judge"

let runtime_toml ~hitl_summary =
  "[providers.local]\n\
   display-name = \"Local\"\n\
   protocol = \"ollama-http\"\n\
   endpoint = \"http://localhost:11434\"\n\
   \n\
   [models.auto_judge]\n\
   api-name = \"auto-judge\"\n\
   max-context = 4096\n\
   \n\
   [models.auto_judge.capabilities]\n\
   supports-structured-output = true\n\
   \n\
   [local.auto_judge]\n\
   \n\
   [runtime]\n\
   default = \"local.auto_judge\"\n\
   structured_judge = \"local.auto_judge\"\n"
  ^ if hitl_summary then "hitl_summary = \"local.auto_judge\"\n" else ""
;;

let with_runtime_config content f =
  let path = Filename.temp_file "hitl-summary-runtime" ".toml" in
  let snapshot = Runtime.For_testing.snapshot () in
  Fun.protect
    ~finally:(fun () ->
      Runtime.For_testing.restore snapshot;
      try Sys.remove path with
      | Sys_error _ -> ())
    (fun () ->
       match Runtime.save_config_text ~runtime_config_path:path content with
       | Error detail -> failf "runtime config should load: %s" detail
       | Ok () -> f ())
;;

let sample_entry : Q.pending_approval =
  { id = "approval-1"
  ; keeper_name = "keeper"
  ; tool_name = "external-effect"
  ; input_hash = "exact-input-hash"
  ; input =
      `Assoc
        [ "target", `String "document"
        ; "body", `String "hello"
        ; "api_key", `String "sk-test-secret"
        ]
  ; sequence = 1
  ; requested_at = 1780587600.0
  ; turn_id = None
  ; request_context =
      Some
        (`Assoc
           [ ( "initial"
             , `Assoc
                 [ "history_messages", `List [ `String "older turn" ]
                 ; "base_system_prompt", `String "base policy"
                 ; "turn_system_prompt", `String "turn policy"
                 ; "user_message", `String "inspect the exact requested operation"
                 ; "dynamic_context", `String "current context"
                 ; "runtime_id", `String "runtime"
                 ] )
           ; "completed_tool_calls", `List []
           ])
  ; task_id = None
  ; goal_id = None
  ; goal_ids = []
  ; continuation_channel = Keeper_continuation_channel.unrouted "test"
  ; audit_base_path = Filename.get_temp_dir_name ()
  ; summary_status = Q.Summary_not_requested
  ; exact_attempt = Q.Exact_unbound
  }
;;

let judgment_json judgment =
  `Assoc
    [ "context_summary", `String "The exact action matches visible context."
    ; "key_questions", `List [ `String "Is the target current?" ]
    ; "judgment", `String judgment
    ; "rationale", `String "The visible evidence supports this judgment."
    ]
;;

let test_parse_typed_judgments () =
  List.iter
    (fun (wire, expected) ->
       let summary =
         match
           Worker.For_testing.parse_summary
             ~generated_at:1780587600.0
             ~model_run_id:"run"
             (judgment_json wire)
         with
         | Ok summary -> summary
         | Error reason -> fail reason
       in
       check bool wire true (summary.judgment = expected))
    [ "approve", Q.Approve; "deny", Q.Deny; "require_human", Q.Require_human ]
;;

let test_invalid_judgment_fails_loud () =
  match
    Worker.For_testing.parse_summary
      ~generated_at:1780587600.0
      ~model_run_id:"run"
      (judgment_json "maybe")
  with
  | Ok _ -> fail "unknown judgment unexpectedly parsed"
  | Error reason ->
    check bool "unknown judgment is explicit" true
      (Astring.String.is_infix ~affix:"maybe" reason)
;;

let test_judgment_parser_rejects_unknown_fields () =
  let json =
    match judgment_json "approve" with
    | `Assoc fields -> `Assoc (("unexpected", `String "retired") :: fields)
    | other -> other
  in
  match
    Worker.For_testing.parse_summary
      ~generated_at:1780587600.0
      ~model_run_id:"run"
      json
  with
  | Ok _ -> fail "unknown judgment field unexpectedly parsed"
  | Error reason ->
    check bool "unknown field is explicit" true
      (Astring.String.is_infix ~affix:"unexpected" reason)
;;

let test_schema_is_closed_nonhierarchical_contract () =
  let open Yojson.Safe.Util in
  let schema = Schema.hitl_context_summary_schema in
  let required = schema |> member "required" |> to_list |> List.map to_string in
  check
    (list string)
    "required fields"
    [ "context_summary"; "key_questions"; "judgment"; "rationale" ]
    required;
  check bool "additional properties disabled" false
    (schema |> member "additionalProperties" |> to_bool)
;;

let test_context_bundle_contains_exact_input_without_derived_classification () =
  let bundle =
    match Worker.For_testing.build_context_bundle ~entry:sample_entry with
    | Ok bundle -> bundle
    | Error error ->
      fail (Worker.For_testing.context_bundle_error_to_string error)
  in
  let open Yojson.Safe.Util in
  check yojson "exact input" sample_entry.input (bundle |> member "input");
  check yojson
    "exact outer-turn context"
    (Option.get sample_entry.request_context)
    (bundle |> member "request_context");
  let fields = bundle |> to_assoc in
  List.iter
    (fun field ->
       check bool ("does not reread " ^ field) false (List.mem_assoc field fields))
    [ "task"; "goals"; "chat_messages"; "partial_context"; "context_notes" ];
  check yojson "no derived classification" `Null (bundle |> member "classification");
  check yojson "no derived level" `Null (bundle |> member "level")
;;

let test_missing_request_context_is_terminal_before_provider () =
  match
    Worker.For_testing.build_context_bundle
      ~entry:{ sample_entry with request_context = None }
  with
  | Ok _ -> fail "missing exact request context produced a provider payload"
  | Error Worker.For_testing.Exact_request_context_unavailable ->
    check string
      "failure is stable and explicit"
      "HITL summary: exact outer-turn request context is unavailable"
      (Worker.For_testing.context_bundle_error_to_string
         Worker.For_testing.Exact_request_context_unavailable)
;;

let test_plain_json_requires_exact_object () =
  let expected = judgment_json "require_human" in
  match Worker.For_testing.extract_json_object (Yojson.Safe.to_string expected) with
  | Error reason -> fail reason
  | Ok actual ->
    check yojson "exact object" expected actual;
    check bool "fenced JSON rejected" true
      (Result.is_error
         (Worker.For_testing.extract_json_object
            ("```json\n" ^ Yojson.Safe.to_string expected ^ "\n```")))
;;

let test_typed_llm_retryability () =
  check bool "context overflow is terminal for the exact request" false
    (Worker.For_testing.summary_llm_error_retryable
       (Agent_sdk.Error.Api
          (ContextOverflow { message = "too large"; limit = Some 131072 })));
  check bool "network failure remains retryable" true
    (Worker.For_testing.summary_llm_error_retryable
       (Agent_sdk.Error.Api
          (NetworkError
             { message = "refused"
             ; kind = Llm_provider.Http_client.Connection_refused
             })))
;;

let test_http_error_mapping_preserves_typed_domain () =
  check bool "transport timeout stays typed" true
    (match
       Worker.For_testing.sdk_error_of_http_error
         (Llm_provider.Http_client.TimeoutError
            { message = "deadline"; phase = Non_streaming_body })
     with
     | Agent_sdk.Error.Provider (Llm_provider.Error.Timeout _) -> true
     | _ -> false);
  check bool "network failure stays typed" true
    (match
       Worker.For_testing.sdk_error_of_http_error
         (Llm_provider.Http_client.NetworkError
            { message = "refused"; kind = Connection_refused })
     with
     | Agent_sdk.Error.Api (NetworkError _) -> true
     | _ -> false)
;;

let test_gate_judgment_prompt_comes_from_registry () =
  Prompt_registry.set_markdown_dir
    (Masc_test_deps.source_path "config/prompts");
  match Worker.For_testing.system_prompt () with
  | Error detail -> fail ("Gate judgment prompt unavailable: " ^ detail)
  | Ok prompt ->
    check bool "prompt is non-empty" true (String.trim prompt <> "")
;;

let test_readiness_fails_when_gate_prompt_is_missing () =
  let original_dir = Masc_test_deps.source_path "config/prompts" in
  let empty_dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      ("masc-hitl-prompt-readiness-" ^ string_of_int (Random.bits ()))
  in
  Unix.mkdir empty_dir 0o700;
  Fun.protect
    ~finally:(fun () ->
      Prompt_registry.set_markdown_dir original_dir;
      Unix.rmdir empty_dir)
    (fun () ->
       Prompt_registry.set_markdown_dir empty_dir;
       match Worker.readiness () with
       | Ok () -> fail "missing Gate prompt reported ready"
       | Error detail ->
         check bool "missing prompt is explicit" true
           (Astring.String.is_infix ~affix:"keeper.gate_judgment" detail);
          let open Yojson.Safe.Util in
          let status = Masc.Keeper_gate_mode.status_json ~base_path:empty_dir in
          check string "dashboard status is unavailable" "unavailable"
            (status |> member "state" |> to_string);
          check bool "dashboard status carries readiness error" true
            (status |> member "read_error" |> to_string |> String.trim <> ""))
;;

let with_body_timeout_env value f =
  let name = "MASC_KEEPER_BODY_TIMEOUT_SEC" in
  let previous = Sys.getenv_opt name in
  Unix.putenv name value;
  Runtime_resolved.reset_for_tests ();
  Fun.protect
    ~finally:(fun () ->
      (match previous with
       | Some previous -> Unix.putenv name previous
       | None -> Unix.unsetenv name);
      Runtime_resolved.reset_for_tests ())
    f
;;

let with_root_eio_context f =
  Eio_main.run @@ fun env ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let mono_clock = Eio.Stdenv.mono_clock env in
  Eio.Switch.run @@ fun sw ->
  Eio_context.with_test_env ~net ~clock ~mono_clock ~sw (fun () -> f clock)
;;

let test_unset_body_timeout_does_not_forward_root_clock () =
  with_root_eio_context @@ fun _root_clock ->
  with_body_timeout_env "" @@ fun () ->
  check
    bool
    "unset body timeout keeps provider clock absent"
    true
    (Option.is_none (Worker.For_testing.body_timeout_clock ()))
;;

let test_explicit_body_timeout_forwards_root_clock () =
  with_root_eio_context @@ fun root_clock ->
  with_body_timeout_env "30" @@ fun () ->
  match Worker.For_testing.body_timeout_clock () with
  | Some actual ->
    check bool "explicit body timeout uses the exact root clock" true (actual == root_clock)
  | None -> fail "explicit body timeout dropped the root clock"
;;

let test_readiness_requires_explicit_dedicated_runtime () =
  Prompt_registry.set_markdown_dir
    (Masc_test_deps.source_path "config/prompts");
  with_runtime_config (runtime_toml ~hitl_summary:false) @@ fun () ->
  check (option string) "dedicated runtime is absent" None
    (Runtime.hitl_summary_runtime_id ());
  check bool "structured judge is not reused" true
    (Option.is_none (Worker.provider_config_for_summary ()));
  match Worker.readiness () with
  | Ok () -> fail "Auto Judge reported ready without [runtime].hitl_summary"
  | Error detail ->
    check string
      "missing dedicated runtime is explicit"
      "Auto Judge requires an explicit [runtime].hitl_summary runtime"
      detail
;;

let test_readiness_selects_exact_dedicated_runtime () =
  Prompt_registry.set_markdown_dir
    (Masc_test_deps.source_path "config/prompts");
  with_runtime_config (runtime_toml ~hitl_summary:true) @@ fun () ->
  (match Worker.readiness () with
   | Ok () -> ()
   | Error detail -> fail detail);
  match Worker.provider_config_for_summary () with
  | None -> fail "configured Auto Judge runtime did not resolve"
  | Some selected ->
    check string "exact dedicated runtime selected" exact_runtime_id selected.runtime_id
;;

let () =
  run
    "Hitl_summary_worker"
    [ ( "typed judgment"
      , [ test_case "parse variants" `Quick test_parse_typed_judgments
        ; test_case "invalid judgment fails loud" `Quick test_invalid_judgment_fails_loud
        ; test_case
            "unknown judgment fields fail loud"
            `Quick
            test_judgment_parser_rejects_unknown_fields
        ; test_case
            "schema has no hierarchy"
            `Quick
            test_schema_is_closed_nonhierarchical_contract
        ; test_case
            "context carries exact input"
            `Quick
            test_context_bundle_contains_exact_input_without_derived_classification
        ; test_case
            "missing request context is terminal before provider"
            `Quick
            test_missing_request_context_is_terminal_before_provider
        ; test_case
            "plain JSON requires exact object"
            `Quick
            test_plain_json_requires_exact_object
        ; test_case
            "LLM retryability uses typed SDK domain"
            `Quick
            test_typed_llm_retryability
        ; test_case
            "HTTP errors preserve typed SDK domains"
            `Quick
            test_http_error_mapping_preserves_typed_domain
        ; test_case
            "Gate judgment prompt is registry-owned"
            `Quick
            test_gate_judgment_prompt_comes_from_registry
        ; test_case
            "Gate judgment readiness fails when missing"
            `Quick
            test_readiness_fails_when_gate_prompt_is_missing
        ; test_case
            "unset body timeout does not forward root clock"
            `Quick
            test_unset_body_timeout_does_not_forward_root_clock
        ; test_case
            "explicit body timeout forwards root clock"
            `Quick
            test_explicit_body_timeout_forwards_root_clock
        ; test_case
            "readiness requires dedicated runtime"
            `Quick
            test_readiness_requires_explicit_dedicated_runtime
        ; test_case
            "readiness selects exact dedicated runtime"
            `Quick
            test_readiness_selects_exact_dedicated_runtime
        ] )
    ]
;;
