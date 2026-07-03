(** Tests for Tool_result — structured tool result type *)

module Tool_result = Tool_result
module Tool_dispatch = Tool_dispatch
module Time_compat = Time_compat
module Keeper_tools_oas_workflow = Masc.Keeper_tools_oas_workflow

let tool_ok ?(tool_name = "") message =
  Tool_result.make_ok ~tool_name ~start_time:0.0 ~data:(`String message) ()
;;

let str_contains haystack needle =
  let hlen = String.length haystack in
  let nlen = String.length needle in
  if nlen = 0
  then true
  else if nlen > hlen
  then false
  else (
    let rec loop i =
      i + nlen <= hlen
      && (String.sub haystack i nlen = needle || loop (i + 1))
    in
    loop 0)
;;

let test_ok_json_response () =
  let start = 1000.0 in
  let r =
    Tool_result.ok
      ~tool_name:"masc_status"
      ~start_time:start
      {|{"status":"ok","count":42}|}
  in
  Alcotest.(check bool) "success" true (Tool_result.is_success r);
  Alcotest.(check string) "tool_name" "masc_status" (Tool_result.tool_name r);
  (* data should be parsed JSON, not a string *)
  (match (Tool_result.data r) with
   | `Assoc fields ->
     Alcotest.(check bool)
       "has status field"
       true
       (List.exists (fun (k, _) -> k = "status") fields)
   | _ -> Alcotest.fail "expected Assoc");
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

let test_error_uses_structured_failure_class () =
  let r =
    Tool_result.error
      ~tool_name:"keeper_task_done"
      ~start_time:0.0
      {|{"ok":false,"error":"evidence is required","failure_class":"workflow_rejection"}|}
  in
  Alcotest.(check bool) "failure" false (Tool_result.is_success r);
  Alcotest.(check string)
    "failure class"
    "workflow_rejection"
    (match (Tool_result.failure_class r) with
     | Some cls -> Tool_result.tool_failure_class_to_string cls
     | None -> "none")
;;

let test_ok_prefixed_json_response () =
  let start = 1000.0 in
  let r =
    Tool_result.ok
      ~tool_name:"masc_board_post"
      ~start_time:start
      "✅ Post created:\n{\"id\":\"post-1\",\"content\":\"hello\",\"ok\":true}"
  in
  match (Tool_result.data r) with
  | `Assoc fields ->
    Alcotest.(check string)
      "id parsed"
      "post-1"
      Yojson.Safe.Util.(List.assoc "id" fields |> to_string);
    Alcotest.(check string)
      "content parsed"
      "hello"
      Yojson.Safe.Util.(List.assoc "content" fields |> to_string)
  | _ -> Alcotest.fail "expected parsed JSON from prefixed payload"
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
  (* JSON roundtrip may normalize formatting *)
  let reparsed = Yojson.Safe.from_string message in
  match reparsed with
  | `Assoc [ ("key", `String "value") ] -> ()
  | _ -> Alcotest.fail "JSON roundtrip lost data"
;;

let test_dispatch_structured () =
  (* Register a test handler *)
  Tool_dispatch.register ~tool_name:"__test_tool" ~handler:(fun ~name ~args:_ ->
    Some (tool_ok ~tool_name:name {|{"result":"ok"}|}));
  (* Register a schema (not just a tag) so the tool clears the input-schema
     validation pre-hook that Mcp_server_eio installs at module load. An
     empty-object schema dispatched with no args passes validation, keeping the
     test focused on structured dispatch while matching production, where every
     dispatchable tool carries a schema. *)
  Tool_dispatch.register_module_tag
    ~schemas:
      [ { Masc_domain.name = "__test_tool"
        ; description = "test dispatch tool"
        ; input_schema = `Assoc [ "type", `String "object" ]
        } ]
    ~tag:Mod_misc;
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
    Alcotest.(check bool) "duration_ms >= 0" true (s.duration_ms >= 0.0)
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

let test_keeper_done_schema_uses_result_only () =
  let schema = keeper_taskboard_schema "keeper_task_done" in
  let properties =
    match object_member "properties" schema with
    | Some (`Assoc fields) -> fields
    | _ -> Alcotest.fail "schema properties missing"
  in
  let has_property name = List.exists (fun (key, _) -> String.equal key name) properties in
  let required = string_list_member "required" schema in
  Alcotest.(check bool) "result property present" true (has_property "result");
  Alcotest.(check bool) "evidence_refs is not a keeper done field" false
    (has_property "evidence_refs");
  Alcotest.(check bool) "pr_url is not a keeper done field" false
    (has_property "pr_url");
  Alcotest.(check (list string))
    "only task_id and result are required"
    [ "task_id"; "result" ]
    required
;;

let test_workflow_marker_accepts_notes_as_evidence_message () =
  let input =
    `Assoc
      [ "task_id", `String "task-001"
      ; "notes", `String "changed files, ran tests, see receipt:turn-1"
      ]
  in
  Alcotest.(check string)
    "notes count as the evidence-bearing handoff message"
    "has_evidence"
    (Keeper_tools_oas_workflow.workflow_submit_evidence_marker input)
;;

let test_workflow_marker_accepts_top_level_evidence_refs () =
  let input =
    `Assoc
      [ "task_id", `String "task-001"
      ; "notes", `String "verification notes"
      ; "evidence_refs", `List [ `String "artifact:logs/test-output.txt" ]
      ]
  in
  Alcotest.(check string)
    "top-level evidence_refs count as evidence"
    "has_evidence"
    (Keeper_tools_oas_workflow.workflow_submit_evidence_marker input)
;;

let test_workflow_recovery_with_tool_suggestion_routes_next_tool () =
  let info : Keeper_tools_oas_workflow.workflow_rejection_info =
    { task_id = Some "task-944"
    ; rule_id = Some "task_done_requires_claimed_or_started"
    ; tool_suggestion = Some "keeper_task_claim"
    ; alternatives = [ "keeper_task_claim"; "keeper_tasks_list" ]
    ; hint = Some "Claim it first"
    ; scope_policy = Keeper_tools_oas_workflow.Observe_scope
    }
  in
  let instruction =
    Keeper_tools_oas_workflow.workflow_rejection_recovery_instruction
      ~tool_name:"keeper_task_done"
      ~count:1
      info
  in
  Alcotest.(check bool)
    "routes to suggested tool"
    true
    (str_contains instruction "Use keeper_task_claim next");
  Alcotest.(check bool)
    "does not invite same done retry"
    false
    (str_contains instruction "retry this keeper_task_done call")
;;

let test_workflow_recovery_fields_require_next_tool () =
  let raw =
    {|{"ok":false,"error":"[TaskError] Task task-944 is still todo. Claim/start it first, then mark it done.","failure_class":"workflow_rejection","error_class":"deterministic","recoverable":false,"hint":"Claim it first.","diagnosis":{"rule_id":"task_done_requires_claimed_or_started","tool_suggestion":"keeper_task_claim","scope_policy":"observe"}}|}
  in
  let fields =
    Keeper_tools_oas_workflow.workflow_rejection_recovery_fields
      ~tool_name:"keeper_task_done"
      ~count:1
      raw
  in
  let required_next_tool =
    match List.assoc_opt "required_next_tool" fields with
    | Some (`String value) -> value
    | _ -> Alcotest.fail "missing required_next_tool"
  in
  let instruction =
    match List.assoc_opt "workflow_rejection_recovery" fields with
    | Some (`Assoc recovery) ->
      (match List.assoc_opt "instruction" recovery with
       | Some (`String value) -> value
       | _ -> Alcotest.fail "missing recovery instruction")
    | _ -> Alcotest.fail "missing workflow_rejection_recovery"
  in
  Alcotest.(check string)
    "required next tool"
    "keeper_task_claim"
    required_next_tool;
  Alcotest.(check bool)
    "instruction names next tool"
    true
    (str_contains instruction "Use keeper_task_claim next");
  Alcotest.(check bool)
    "instruction avoids same-tool retry"
    false
    (str_contains instruction "retry this keeper_task_done call")
;;

let test_workflow_recovery_uses_alternatives_without_tool_suggestion () =
  let raw =
    {|{"ok":false,"error":"task_id is required","failure_class":"workflow_rejection","alternatives":["keeper_task_claim","keeper_tasks_list"],"diagnosis":{"rule_id":"keeper_task_argument_rejected","scope_policy":"observe"}}|}
  in
  let fields =
    Keeper_tools_oas_workflow.workflow_rejection_recovery_fields
      ~tool_name:"keeper_task_done"
      ~count:1
      raw
  in
  let suggested_next_tool =
    match List.assoc_opt "suggested_next_tool" fields with
    | Some (`String value) -> value
    | _ -> Alcotest.fail "missing suggested_next_tool"
  in
  let instruction =
    match List.assoc_opt "workflow_rejection_recovery" fields with
    | Some (`Assoc recovery) ->
      (match List.assoc_opt "instruction" recovery with
       | Some (`String value) -> value
       | _ -> Alcotest.fail "missing recovery instruction")
    | _ -> Alcotest.fail "missing workflow_rejection_recovery"
  in
  Alcotest.(check string)
    "suggested next tool"
    "keeper_task_claim"
    suggested_next_tool;
  Alcotest.(check bool)
    "instruction names alternative tool"
    true
    (str_contains instruction "Use keeper_task_claim");
  Alcotest.(check bool)
    "instruction avoids same-tool retry"
    false
    (str_contains instruction "retry this keeper_task_done call")
;;

let () =
  Alcotest.run
    "Tool_result"
    [ ( "ok/error"
      , [ Alcotest.test_case "json response" `Quick test_ok_json_response
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
            "structured failure_class is honored"
            `Quick
            test_error_uses_structured_failure_class
        ; Alcotest.test_case
            "prefixed json response"
            `Quick
            test_ok_prefixed_json_response
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
            "done schema uses result only"
            `Quick
            test_keeper_done_schema_uses_result_only
        ; Alcotest.test_case
            "workflow marker accepts notes"
            `Quick
            test_workflow_marker_accepts_notes_as_evidence_message
        ; Alcotest.test_case
            "workflow marker accepts top-level evidence_refs"
            `Quick
            test_workflow_marker_accepts_top_level_evidence_refs
        ] )
    ; ( "workflow rejection recovery"
      , [ Alcotest.test_case
            "tool suggestion routes next tool"
            `Quick
            test_workflow_recovery_with_tool_suggestion_routes_next_tool
        ; Alcotest.test_case
            "recovery fields require next tool"
            `Quick
            test_workflow_recovery_fields_require_next_tool
        ; Alcotest.test_case
            "recovery fields use alternatives"
            `Quick
            test_workflow_recovery_uses_alternatives_without_tool_suggestion
        ] )
    ]
;;
