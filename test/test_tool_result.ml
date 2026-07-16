(** Tests for Tool_result — structured tool result type *)

module Tool_result = Tool_result
module Tool_dispatch = Tool_dispatch
module Time_compat = Time_compat
module Keeper_tool_execution = Masc.Keeper_tool_execution
module Keeper_tools_oas = Masc.Keeper_tools_oas

let tool_ok ?(tool_name = "") message =
  Tool_result.make_ok ~tool_name ~start_time:0.0 ~data:(`String message) ()
;;

let test_schema tool =
  { Masc_domain.name = tool
  ; description = "test tool " ^ tool
  ; input_schema =
      `Assoc
        [ "type", `String "object"; "properties", `Assoc []; "required", `List [] ]
  }
;;

let register_test_tool ~tool_name ~handler =
  Tool_dispatch.register ~tool_name ~handler;
  Tool_dispatch.register_module_tag ~schemas:[ test_schema tool_name ] ~tag:Mod_misc
;;

let test_ok_json_looking_text_is_opaque () =
  let start = 1000.0 in
  let r =
    Tool_result.ok
      ~tool_name:"masc_status"
      ~start_time:start
      {|{"status":"ok","count":42}|}
  in
  Alcotest.(check bool) "success" true (Tool_result.is_success r);
  Alcotest.(check string) "tool_name" "masc_status" (Tool_result.tool_name r);
  (match Tool_result.data r with
   | `String text ->
     Alcotest.(check string)
       "JSON-looking text preserved"
       {|{"status":"ok","count":42}|}
       text
   | _ -> Alcotest.fail "expected opaque String");
  Alcotest.(check bool) "duration >= 0" true (Tool_result.duration_ms r >= 0.0)
;;

let test_error_plain_string () =
  let start = Time_compat.now () in
  let r =
    Tool_result.error
      ~tool_name:"masc_transition"
      ~start_time:start
      "Something went wrong"
  in
  Alcotest.(check bool) "failure" false (Tool_result.is_success r);
  Alcotest.(check string) "tool_name" "masc_transition" (Tool_result.tool_name r);
  (* Non-JSON string should be wrapped as `String *)
  match (Tool_result.data r) with
  | `String s -> Alcotest.(check string) "plain string preserved" "Something went wrong" s
  | _ -> Alcotest.fail "expected String for non-JSON input"
;;

let test_plain_dispatch_failure_does_not_infer_from_message () =
  let r =
    Tool_result.error
      ~tool_name:"masc_transition"
      ~start_time:0.0
      "[SystemError] IO error: Failed to acquire distributed lock for key: tasks:.backlog (50 attempts exhausted)"
  in
  Alcotest.(check bool) "failure" false (Tool_result.is_success r);
  Alcotest.(check string)
    "failure class"
    "runtime_failure"
    (match (Tool_result.failure_class r) with
     | Some cls -> Tool_result.tool_failure_class_to_string cls
     | None -> "none")
;;

let test_plain_dispatch_failure_honors_explicit_failure_class () =
  let r =
    Tool_result.error
      ~failure_class:(Some Tool_result.Transient_error)
      ~tool_name:"masc_transition"
      ~start_time:0.0
      "[SystemError] IO error: Failed to acquire distributed lock for key: tasks:.backlog"
  in
  Alcotest.(check bool) "failure" false (Tool_result.is_success r);
  Alcotest.(check string)
    "failure class"
    "transient_error"
    (match (Tool_result.failure_class r) with
     | Some cls -> Tool_result.tool_failure_class_to_string cls
     | None -> "none")
;;

let test_exception_message_does_not_infer_failure_class () =
  let r =
    Tool_result.of_exn
      ~tool_name:"masc_transition"
      ~start_time:0.0
      (Invalid_argument
         "Failed to acquire distributed lock for key: tasks:.backlog (50 attempts exhausted)")
  in
  Alcotest.(check bool) "failure" false (Tool_result.is_success r);
  Alcotest.(check string)
    "failure class"
    "runtime_failure"
    (match (Tool_result.failure_class r) with
     | Some cls -> Tool_result.tool_failure_class_to_string cls
     | None -> "none")
;;

let test_exception_boundary_honors_explicit_failure_class () =
  let r =
    Tool_result.of_exn
      ~failure_class:Tool_result.Transient_error
      ~tool_name:"masc_transition"
      ~start_time:0.0
      (Invalid_argument
         "Failed to acquire distributed lock for key: tasks:.backlog (50 attempts exhausted)")
  in
  Alcotest.(check bool) "failure" false (Tool_result.is_success r);
  Alcotest.(check string)
    "failure class"
    "transient_error"
    (match (Tool_result.failure_class r) with
     | Some cls -> Tool_result.tool_failure_class_to_string cls
     | None -> "none")
;;

let test_error_message_cannot_override_failure_class () =
  let message =
    {|{"ok":false,"error":"evidence is required","failure_class":"workflow_rejection"}|}
  in
  let r =
    Tool_result.error
      ~tool_name:"keeper_task_done"
      ~start_time:0.0
      message
  in
  Alcotest.(check bool) "failure" false (Tool_result.is_success r);
  Alcotest.(check string)
    "failure class"
    "runtime_failure"
    (match (Tool_result.failure_class r) with
     | Some cls -> Tool_result.tool_failure_class_to_string cls
     | None -> "none");
  match Tool_result.data r with
  | `String text -> Alcotest.(check string) "message remains opaque" message text
  | _ -> Alcotest.fail "expected opaque String"
;;

let test_ok_newline_json_suffix_is_opaque () =
  let start = 1000.0 in
  let message =
    "✅ Post created:\n{\"id\":\"post-1\",\"content\":\"hello\",\"ok\":true}"
  in
  let r =
    Tool_result.ok
      ~tool_name:"masc_board_post"
      ~start_time:start
      message
  in
  match Tool_result.data r with
  | `String text -> Alcotest.(check string) "suffix preserved" message text
  | _ -> Alcotest.fail "expected opaque String"
;;

let test_keeper_execution_json_looking_string_is_opaque () =
  let raw = {|{"ok":true,"result":{"secret":"not typed"}}|} in
  let execution =
    Tool_result.ok ~tool_name:"probe" ~start_time:0.0 raw
    |> Keeper_tool_execution.of_tool_result
  in
  Alcotest.(check string) "raw text preserved" raw execution.raw_output;
  Alcotest.(check bool)
    "opaque string preserved as producer data"
    true
    (match execution.data with
     | Some (`String actual) -> String.equal raw actual
     | Some _ | None -> false)
;;

let test_keeper_execution_preserves_explicit_typed_data () =
  let data = `Assoc [ "result", `Assoc [ "typed", `Bool true ] ] in
  let execution =
    Tool_result.make_ok ~tool_name:"probe" ~start_time:0.0 ~data ()
    |> Keeper_tool_execution.of_tool_result
  in
  Alcotest.(check bool)
    "typed data preserved"
    true
    (match execution.data with
     | Some actual -> Yojson.Safe.equal data actual
     | None -> false)
;;

let test_to_json () =
  let start = Time_compat.now () in
  let r = Tool_result.ok ~tool_name:"masc_transition" ~start_time:start "done" in
  let json = Tool_result.to_json r in
  match json with
  | `Assoc fields ->
    let has key = List.exists (fun (k, _) -> k = key) fields in
    Alcotest.(check bool) "has disposition" true (has "disposition");
    Alcotest.(check bool) "has no legacy success bool" false (has "success");
    Alcotest.(check bool) "has data" true (has "data");
    Alcotest.(check bool) "has tool_name" true (has "tool_name");
    Alcotest.(check bool) "has duration_ms" true (has "duration_ms")
  | _ -> Alcotest.fail "to_json should return Assoc"
;;

let test_message_roundtrip () =
  let start = Time_compat.now () in
  let r = Tool_result.ok ~tool_name:"test" ~start_time:start "hello world" in
  let success = (Tool_result.is_success r) in
  let message = (Tool_result.message r) in
  Alcotest.(check bool) "success preserved" true success;
  Alcotest.(check string) "message preserved" "hello world" message
;;

let test_message_json_roundtrip () =
  let start = Time_compat.now () in
  let json_str = {|{"key":"value"}|} in
  let r = Tool_result.ok ~tool_name:"test" ~start_time:start json_str in
  let message = (Tool_result.message r) in
  Alcotest.(check string) "JSON-looking message is unchanged" json_str message;
  match Tool_result.data r with
  | `String text -> Alcotest.(check string) "data remains text" json_str text
  | _ -> Alcotest.fail "expected opaque String"
;;

let test_dispatch_structured () =
  (* Register a test handler *)
  register_test_tool ~tool_name:"__test_tool" ~handler:(fun ~name ~args:_ ->
    Some (tool_ok ~tool_name:name {|{"result":"ok"}|}));
  let token =
    match Tool_dispatch.mint_token ~name:"__test_tool" with
    | Ok t -> t
    | Error e -> Alcotest.fail e
  in
  match Tool_dispatch.guarded_dispatch ~token ~args:`Null () with
  | Some r ->
    Alcotest.(check bool) "success" true (Tool_result.is_success r);
    Alcotest.(check string) "tool_name" "__test_tool" (Tool_result.tool_name r);
    Alcotest.(check bool) "duration >= 0" true (Tool_result.duration_ms r >= 0.0)
  | None -> Alcotest.fail "dispatch_structured returned None for registered tool"
;;

let test_dispatch_structured_unknown () =
  match Tool_dispatch.mint_token ~name:"__nonexistent" with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "mint_token should return Error for unknown tool"
;;

(* ─── RFC-0189 — typed result variant ──────────────────────────────────── *)

let test_make_ok_roundtrip () =
  let r =
    Tool_result.make_ok
      ~tool_name:"masc_test"
      ~start_time:0.0
      ~data:(`Assoc [ "k", `String "v" ])
      ()
  in
  match r with
  | Tool_result.Completed s ->
    Alcotest.(check string) "tool_name preserved" "masc_test" s.tool_name;
    Alcotest.(check bool) "duration_ms >= 0" true (s.duration_ms >= 0.0);
    Alcotest.(check (option string))
      "typed Assoc remains structured"
      (Some "v")
      Yojson.Safe.Util.(s.data |> member "k" |> to_string_option)
  | Tool_result.Deferred _ -> Alcotest.fail "make_ok produced Deferred"
  | Tool_result.Failed _ -> Alcotest.fail "make_ok produced Failed"
;;

let test_make_err_required_class () =
  (* This test exists to document the API: ~class_ is required, not optional.
     The compiler enforces this at every call site of make_err — there's no
     [?class_:tool_failure_class option] pattern to defer to. *)
  let r =
    Tool_result.make_err
      ~tool_name:"masc_test"
      ~class_:Tool_result.Policy_rejection
      ~start_time:0.0
      "rejected"
  in
  match r with
  | Tool_result.Failed f ->
    Alcotest.(check string) "tool_name" "masc_test" f.tool_name;
    Alcotest.(check string) "message" "rejected" f.message;
    Alcotest.(check string)
      "class_"
      "policy_rejection"
      (Tool_result.tool_failure_class_to_string f.class_)
  | Tool_result.Completed _ -> Alcotest.fail "make_err produced Completed"
  | Tool_result.Deferred _ -> Alcotest.fail "make_err produced Deferred"
;;

let test_make_err_of_exn_classifies_constructor () =
  let r =
    Tool_result.make_err_of_exn
      ~tool_name:"test_tool"
      ~start_time:0.0
      Eio.Time.Timeout
  in
  match r with
  | Tool_result.Failed f ->
    Alcotest.(check string)
      "Timeout classified as transient"
      "transient_error"
      (Tool_result.tool_failure_class_to_string f.class_)
  | Tool_result.Completed _ -> Alcotest.fail "make_err_of_exn returned Completed"
  | Tool_result.Deferred _ -> Alcotest.fail "make_err_of_exn returned Deferred"
;;

let test_disposition_preserves_typed_payload () =
  let r =
    Tool_result.make_ok ~tool_name:"x" ~start_time:0.0 ~data:(`Int 1) ()
  in
  let mapped =
    match r with
    | Tool_result.Completed output ->
      Tool_result.Completed { output with tool_name = "y" }
    | Tool_result.Deferred output -> Tool_result.Deferred output
    | Tool_result.Failed failure -> Tool_result.Failed failure
  in
  match mapped with
  | Tool_result.Completed output ->
    Alcotest.(check string) "payload update composes" "y" output.tool_name
  | Tool_result.Deferred _ | Tool_result.Failed _ ->
    Alcotest.fail "completed disposition was not preserved"
;;

let test_deferred_is_distinct_and_projects_one_way () =
  let data = `Assoc [ "approval_id", `String "approval-1" ] in
  let metadata = `Assoc [ "receipt", data ] in
  let result =
    Tool_result.make_deferred
      ~tool_name:"keeper_file_write"
      ~start_time:0.0
      ~data
      ~metadata
      ()
  in
  Alcotest.(check bool) "not completed" false (Tool_result.is_success result);
  Alcotest.(check bool) "deferred" true (Tool_result.is_deferred result);
  Alcotest.(check bool) "not failed" false (Tool_result.is_failed result);
  match Masc.Tool_bridge.to_oas_typed_result result with
  | Ok { Agent_sdk.Types._meta = Some (`Assoc fields); _ } ->
    Alcotest.(check (option string))
      "opaque OAS marker"
      (Some "deferred")
      (match List.assoc_opt "masc.tool_disposition" fields with
       | Some (`String value) -> Some value
       | Some _ | None -> None)
  | Ok _ -> Alcotest.fail "deferred OAS projection omitted metadata"
  | Error _ -> Alcotest.fail "deferred OAS projection became an error"
;;

let test_disposition_wire_decoder_is_strict () =
  let expect label expected =
    match Tool_result.unit_disposition_of_string label with
    | Ok actual ->
      Alcotest.(check string)
        label
        expected
        (Tool_result.string_of_disposition actual)
    | Error error -> Alcotest.fail error
  in
  expect "completed" "completed";
  expect "deferred" "deferred";
  expect "failed" "failed";
  match Tool_result.unit_disposition_of_string "success" with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "legacy success label must not be migrated"
;;

let test_gate_causal_context_preserves_deferred () =
  let context =
    Masc.Keeper_gate_causal_context.create
      ~turn_id:(Some 7)
      ~initial:(`Assoc [])
  in
  let result =
    Tool_result.make_deferred
      ~tool_name:"keeper_file_write"
      ~start_time:0.0
      ~data:(`Assoc [ "approval_id", `String "approval-1" ])
      ()
  in
  Masc.Keeper_gate_causal_context.record_tool_result
    context
    ~operation:"keeper_file_write"
    ~input:(`Assoc [])
    result;
  let call =
    (Masc.Keeper_gate_causal_context.snapshot context).snapshot
    |> Yojson.Safe.Util.member "completed_tool_calls"
    |> Yojson.Safe.Util.index 0
  in
  Alcotest.(check string)
    "deferred stays distinct"
    "deferred"
    Yojson.Safe.Util.(call |> member "disposition" |> to_string);
  Alcotest.(check bool)
    "legacy succeeded bool is absent"
    true
    Yojson.Safe.Util.(call |> member "succeeded" = `Null)
;;

let keeper_taskboard_schema name =
  match
    List.find_opt
      (fun (schema : Masc_domain.tool_schema) ->
         String.equal schema.name name)
      Tool_shard_types.taskboard_tools
  with
  | Some schema -> schema.input_schema
  | None -> Alcotest.failf "%s schema missing" name
;;

let object_member name = function
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> None
;;

let string_list_member name json =
  match object_member name json with
  | Some (`List items) ->
    List.filter_map
      (function
        | `String value -> Some value
        | _ -> None)
      items
  | _ -> []
;;

let test_keeper_done_schema_uses_result_and_evidence_refs () =
  let schema = keeper_taskboard_schema "keeper_task_done" in
  let properties =
    match object_member "properties" schema with
    | Some (`Assoc fields) -> fields
    | _ -> Alcotest.fail "schema properties missing"
  in
  let has_property name = List.exists (fun (key, _) -> String.equal key name) properties in
  let required = string_list_member "required" schema in
  Alcotest.(check bool) "result property present" true (has_property "result");
  Alcotest.(check bool) "evidence_refs is a keeper done field" true
    (has_property "evidence_refs");
  Alcotest.(check bool) "pr_url is not a keeper done field" false
    (has_property "pr_url");
  Alcotest.(check (list string))
    "task_id, result, and evidence_refs are required"
    [ "task_id"; "result"; "evidence_refs" ]
    required
;;

let () =
  Alcotest.run
    "Tool_result"
    [ ( "ok/error"
      , [ Alcotest.test_case
            "JSON-looking success text stays opaque"
            `Quick
            test_ok_json_looking_text_is_opaque
        ; Alcotest.test_case "plain string" `Quick test_error_plain_string
        ; Alcotest.test_case
            "plain dispatch failure does not infer from message"
            `Quick
            test_plain_dispatch_failure_does_not_infer_from_message
        ; Alcotest.test_case
            "plain dispatch failure honors explicit failure_class"
            `Quick
            test_plain_dispatch_failure_honors_explicit_failure_class
        ; Alcotest.test_case
            "exception message does not infer failure_class"
            `Quick
            test_exception_message_does_not_infer_failure_class
        ; Alcotest.test_case
            "exception boundary honors explicit failure_class"
            `Quick
            test_exception_boundary_honors_explicit_failure_class
        ; Alcotest.test_case
            "failure message cannot override class"
            `Quick
            test_error_message_cannot_override_failure_class
        ; Alcotest.test_case
            "newline JSON suffix stays opaque"
            `Quick
            test_ok_newline_json_suffix_is_opaque
        ; Alcotest.test_case
            "keeper execution keeps JSON-looking string opaque"
            `Quick
            test_keeper_execution_json_looking_string_is_opaque
        ; Alcotest.test_case
            "keeper execution preserves typed data"
            `Quick
            test_keeper_execution_preserves_explicit_typed_data
        ] )
    ; "to_json", [ Alcotest.test_case "fields present" `Quick test_to_json ]
    ; ( "message"
      , [ Alcotest.test_case "roundtrip string" `Quick test_message_roundtrip
        ; Alcotest.test_case "roundtrip json" `Quick test_message_json_roundtrip
        ] )
    ; ( "dispatch_structured"
      , [ Alcotest.test_case "registered tool" `Quick test_dispatch_structured
        ; Alcotest.test_case "unknown tool" `Quick test_dispatch_structured_unknown
        ] )
    ; ( "rfc-0189 typed result"
      , [ Alcotest.test_case "make_ok round-trip" `Quick test_make_ok_roundtrip
        ; Alcotest.test_case "make_err required class" `Quick test_make_err_required_class
        ; Alcotest.test_case
            "make_err_of_exn classifies by constructor"
            `Quick
            test_make_err_of_exn_classifies_constructor
        ; Alcotest.test_case
            "disposition preserves typed payload"
            `Quick
            test_disposition_preserves_typed_payload
        ; Alcotest.test_case
            "deferred is distinct and projects one-way"
            `Quick
            test_deferred_is_distinct_and_projects_one_way
        ; Alcotest.test_case
            "disposition wire decoder is strict"
            `Quick
            test_disposition_wire_decoder_is_strict
        ; Alcotest.test_case
            "Gate causal context preserves deferred"
            `Quick
            test_gate_causal_context_preserves_deferred
        ] )
    ; ( "keeper verification evidence schema"
      , [ Alcotest.test_case
            "done schema uses result and evidence refs"
            `Quick
            test_keeper_done_schema_uses_result_and_evidence_refs
        ] )
    ]
;;
