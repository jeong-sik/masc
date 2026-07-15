(** Tests for Tool_result — structured tool result type *)

module Tool_result = Tool_result
module Tool_dispatch = Tool_dispatch
module Time_compat = Time_compat
module Keeper_tool_execution = Masc.Keeper_tool_execution
module Keeper_tools_oas = Masc.Keeper_tools_oas

let tool_ok ?(tool_name = "") message =
  Tool_result.make_ok ~tool_name ~start_time:0.0 ~data:(`String message) ()
;;

(* Severity policy the OAS exec-handler logger relies on: expected non-blocking
   outcomes (Workflow_rejection — e.g. a gate deferral) log at WARN, only real
   failures (Runtime_failure) log at ERROR. Locks the SSOT so the logger cannot
   silently regress back to hardcoding ERROR for deferrals. *)
let level_name : Log.level -> string = function
  | Log.Debug -> "debug"
  | Log.Info -> "info"
  | Log.Warn -> "warn"
  | Log.Error -> "error"
;;

let test_log_level_of_failure_class () =
  let check_level expected cls =
    Alcotest.(check string)
      (Printf.sprintf "log level for %s" (Tool_result.tool_failure_class_to_string cls))
      expected
      (level_name (Tool_result.log_level_of_failure_class cls))
  in
  check_level "warn" Tool_result.Workflow_rejection;
  check_level "warn" Tool_result.Policy_rejection;
  check_level "warn" Tool_result.Transient_error;
  check_level "error" Tool_result.Runtime_failure
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

let test_oas_projection_never_parses_opaque_text () =
  let raw =
    {|{"failure_class":"workflow_rejection","error":"fabricated"}|}
  in
  let projected =
    Keeper_tools_oas.normalize_tool_result ~success:true ~data:None raw
  in
  Alcotest.(check bool)
    "JSON-looking string stays result text"
    true
    (Yojson.Safe.equal
       (`Assoc [ "ok", `Bool true; "result", `String raw ])
       projected)
;;

let test_oas_projection_uses_only_explicit_typed_data () =
  let raw = {|{"recoverable":true,"error":"fabricated"}|} in
  let data =
    `Assoc
      [ "failure_class", `String "workflow_rejection"
      ; "recoverable", `Bool false
      ]
  in
  let projected =
    Keeper_tools_oas.normalize_tool_result
      ~success:false
      ~data:(Some data)
      raw
  in
  Alcotest.(check bool)
    "typed detail is authoritative"
    true
    (Yojson.Safe.equal
       (`Assoc
          [ "ok", `Bool false
          ; "error", `String raw
          ; "detail", data
          ])
       projected)
;;

let test_to_json () =
  let start = Time_compat.now () in
  let r = Tool_result.ok ~tool_name:"masc_transition" ~start_time:start "done" in
  let json = Tool_result.to_json r in
  match json with
  | `Assoc fields ->
    let has key = List.exists (fun (k, _) -> k = key) fields in
    Alcotest.(check bool) "has success" true (has "success");
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
  | Ok s ->
    Alcotest.(check string) "tool_name preserved" "masc_test" s.tool_name;
    Alcotest.(check bool) "duration_ms >= 0" true (s.duration_ms >= 0.0);
    Alcotest.(check (option string))
      "typed Assoc remains structured"
      (Some "v")
      Yojson.Safe.Util.(s.data |> member "k" |> to_string_option)
  | Error _ -> Alcotest.fail "make_ok produced Error"
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
  | Error f ->
    Alcotest.(check string) "tool_name" "masc_test" f.tool_name;
    Alcotest.(check string) "message" "rejected" f.message;
    Alcotest.(check string)
      "class_"
      "policy_rejection"
      (Tool_result.tool_failure_class_to_string f.class_)
  | Ok _ -> Alcotest.fail "make_err produced Ok"
;;

let test_make_err_of_exn_classifies_constructor () =
  let r =
    Tool_result.make_err_of_exn
      ~tool_name:"test_tool"
      ~start_time:0.0
      Eio.Time.Timeout
  in
  match r with
  | Error f ->
    Alcotest.(check string)
      "Timeout classified as transient"
      "transient_error"
      (Tool_result.tool_failure_class_to_string f.class_)
  | Ok _ -> Alcotest.fail "make_err_of_exn returned Ok"
;;

let test_result_is_stdlib_result_alias () =
  (* Documents that [result] is [(success_payload, failure_payload) Stdlib.Result.t]
     so all stdlib combinators (map, bind, fold) compose with it. *)
  let r =
    Tool_result.make_ok ~tool_name:"x" ~start_time:0.0 ~data:(`Int 1) ()
  in
  let mapped =
    Stdlib.Result.map
      (fun (s : Tool_result.success_payload) -> { s with tool_name = "y" })
      r
  in
  match mapped with
  | Ok s -> Alcotest.(check string) "Stdlib.Result.map composes" "y" s.tool_name
  | Error _ -> Alcotest.fail "Stdlib.Result.map should preserve Ok"
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
        ; Alcotest.test_case
            "OAS projection does not parse opaque text"
            `Quick
            test_oas_projection_never_parses_opaque_text
        ; Alcotest.test_case
            "OAS projection uses explicit typed data"
            `Quick
            test_oas_projection_uses_only_explicit_typed_data
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
            "result aliases Stdlib.Result.t"
            `Quick
            test_result_is_stdlib_result_alias
        ] )
    ; ( "keeper verification evidence schema"
      , [ Alcotest.test_case
            "done schema uses result and evidence refs"
            `Quick
            test_keeper_done_schema_uses_result_and_evidence_refs
        ] )
    ; ( "failure-class log severity"
      , [ Alcotest.test_case
            "Workflow/Policy/Transient are WARN, Runtime is ERROR"
            `Quick
            test_log_level_of_failure_class
        ] )
    ]
;;
