open Alcotest

module Q = Masc.Keeper_approval_queue
module Worker = Masc.Hitl_summary_worker
module Schema = Masc.Keeper_structured_output_schema

let yojson = testable Yojson.Safe.pretty_print Yojson.Safe.equal

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
  ; requested_at = 1780587600.0
  ; turn_id = None
  ; request_context =
      Some
        (`Assoc
           [ "user_message", `String "inspect the exact requested operation" ])
  ; task_id = None
  ; continuation_channel = Keeper_continuation_channel.unrouted "test"
  ; audit_base_path = Filename.get_temp_dir_name ()
  ; summary_status = Q.Summary_not_requested
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
  let bundle = Worker.For_testing.build_context_bundle ~entry:sample_entry in
  let open Yojson.Safe.Util in
  check yojson "exact input" sample_entry.input (bundle |> member "input");
  check yojson
    "exact outer-turn context"
    (Option.get sample_entry.request_context)
    (bundle |> member "request_context");
  check yojson "no derived classification" `Null (bundle |> member "classification");
  check yojson "no derived level" `Null (bundle |> member "level")
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

let test_gate_judgment_prompt_comes_from_registry () =
  Prompt_registry.set_markdown_dir
    (Filename.concat (Sys.getcwd ()) "config/prompts");
  match Worker.For_testing.system_prompt () with
  | Error detail -> fail ("Gate judgment prompt unavailable: " ^ detail)
  | Ok prompt ->
    check bool "prompt is non-empty" true (String.trim prompt <> "")
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
            "plain JSON requires exact object"
            `Quick
            test_plain_json_requires_exact_object
        ; test_case
            "Gate judgment prompt is registry-owned"
            `Quick
            test_gate_judgment_prompt_comes_from_registry
        ] )
    ]
;;
