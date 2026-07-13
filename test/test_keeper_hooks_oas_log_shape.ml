open Alcotest

module Under_test = Masc.Keeper_hooks_oas.For_testing

let test_empty_tool_args_are_explicit_object_shape () =
  check string "empty object shape" "object:0"
    (Under_test.tool_input_shape_for_log (`Assoc []));
  check string "empty object keys" "-"
    (Under_test.tool_input_keys_for_log (`Assoc []))

let test_tool_arg_shapes_keep_field_names () =
  let input =
    `Assoc
      [ "argv", `List [ `String "status"; `String "--short" ]
      ; "cwd", `String "repos/masc-mcp"
      ; "executable", `String "git"
      ]
  in
  check string "shape" "argv=array:2,cwd=string:14,executable=string:3"
    (Under_test.tool_input_shape_for_log input);
  check string "keys preserve input order" "argv,cwd,executable"
    (Under_test.tool_input_keys_for_log input)

let test_output_fingerprint_keeps_json_looking_text_opaque () =
  let digest output_text =
    match
      Masc.Keeper_tool_progress_identity.digest_tool_io
        ~tool_name:"opaque_tool"
        ~input:(`Assoc [ "value", `Int 1 ])
        ~output_text
    with
    | Some fingerprints -> fingerprints.output_fingerprint
    | None -> fail "expected fingerprints"
  in
  check bool
    "changing a formerly stripped key changes opaque bytes"
    false
    (String.equal
       (digest {|{"ts":1,"result":"same"}|})
       (digest {|{"ts":2,"result":"same"}|}))

let test_input_fingerprint_canonicalizes_typed_field_order () =
  let digest input =
    match
      Masc.Keeper_tool_progress_identity.digest_tool_io
        ~tool_name:"opaque_tool"
        ~input
        ~output_text:"opaque"
    with
    | Some fingerprints -> fingerprints.input_fingerprint
    | None -> fail "expected fingerprints"
  in
  check string
    "typed object order"
    (digest (`Assoc [ "a", `Int 1; "b", `Int 2 ]))
    (digest (`Assoc [ "b", `Int 2; "a", `Int 1 ]))

let task_scope_meta () =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [ "name", `String "task-scope-test"
        ; "agent_name", `String "task-scope-test"
        ; "trace_id", `String "trace-task-scope-test"
        ; "current_task_id", `String "task-meta"
        ])
  with
  | Ok meta -> meta
  | Error message -> fail message

let test_task_scope_uses_typed_input_or_meta () =
  let meta = task_scope_meta () in
  check (option string)
    "transition uses typed input"
    (Some "task-input")
    (Masc.Keeper_run_tools_task_scope.task_id_scope_of_tool_call
       ~tool_name:"masc_transition"
       ~input:(`Assoc [ "task_id", `String "task-input" ])
       ~meta);
  check (option string)
    "claim uses persisted current task"
    (Some "task-meta")
    (Masc.Keeper_run_tools_task_scope.task_id_scope_of_tool_call
       ~tool_name:"keeper_task_claim"
       ~input:(`Assoc [])
       ~meta)

(* F2 canonical projection consumption: block counting in
   [summarize_thinking_blocks] is delegated to OAS [Response_shape.summarize_blocks];
   MASC keeps the policy shaping (thinking_present + thinking_kind classifier).
   These pin that policy output across all classifier cases so the delegation
   stays behavior-preserving. *)

let thinking ?signature content =
  Agent_sdk.Types.Thinking { signature; content }

let check_thinking_summary ~msg ~present ~blocks ~chars ~redacted ~kind content =
  let { Keeper_hooks_oas_types.thinking_present
      ; thinking_blocks
      ; thinking_chars
      ; redacted_thinking_blocks
      ; thinking_kind
      } =
    Keeper_hooks_oas_types.summarize_thinking_blocks content
  in
  check bool (msg ^ ": present") present thinking_present;
  check int (msg ^ ": blocks") blocks thinking_blocks;
  check int (msg ^ ": chars") chars thinking_chars;
  check int (msg ^ ": redacted") redacted redacted_thinking_blocks;
  check string (msg ^ ": kind") kind thinking_kind

let test_thinking_summary_none_empty () =
  check_thinking_summary ~msg:"empty" ~present:false ~blocks:0 ~chars:0
    ~redacted:0 ~kind:"none" []

let test_thinking_summary_none_text_only () =
  check_thinking_summary ~msg:"text-only" ~present:false ~blocks:0 ~chars:0
    ~redacted:0 ~kind:"none" [ Agent_sdk.Types.Text "hello" ]

let test_thinking_summary_thinking_counts_chars () =
  check_thinking_summary ~msg:"thinking" ~present:true ~blocks:1 ~chars:5
    ~redacted:0 ~kind:"thinking" [ thinking "abcde" ]

let test_thinking_summary_redacted_only () =
  check_thinking_summary ~msg:"redacted" ~present:true ~blocks:0 ~chars:0
    ~redacted:1 ~kind:"redacted" [ Agent_sdk.Types.RedactedThinking "opaque" ]

let test_thinking_summary_mixed_sums () =
  check_thinking_summary ~msg:"mixed" ~present:true ~blocks:2 ~chars:7
    ~redacted:1 ~kind:"mixed"
    [ thinking "abcd"
    ; Agent_sdk.Types.RedactedThinking "x"
    ; thinking "efg"
    ; Agent_sdk.Types.Text "ignored"
    ]

let () =
  run "keeper_hooks_oas_log_shape"
    [ ( "tool-input-log-shape"
      , [ test_case "empty args are object:0" `Quick
            test_empty_tool_args_are_explicit_object_shape
        ; test_case "field shapes are explicit" `Quick
            test_tool_arg_shapes_keep_field_names
        ; test_case
            "output JSON-looking text remains opaque"
            `Quick
            test_output_fingerprint_keeps_json_looking_text_opaque
        ; test_case
            "typed input field order is canonical"
            `Quick
            test_input_fingerprint_canonicalizes_typed_field_order
        ; test_case
            "task scope uses typed input or meta"
            `Quick
            test_task_scope_uses_typed_input_or_meta
        ] )
    ; ( "thinking-summary-classifier"
      , [ test_case "empty -> none" `Quick test_thinking_summary_none_empty
        ; test_case "text-only -> none" `Quick
            test_thinking_summary_none_text_only
        ; test_case "thinking -> thinking, chars counted" `Quick
            test_thinking_summary_thinking_counts_chars
        ; test_case "redacted -> redacted" `Quick
            test_thinking_summary_redacted_only
        ; test_case "mixed -> mixed, chars sum, text ignored" `Quick
            test_thinking_summary_mixed_sums
        ] )
    ]
