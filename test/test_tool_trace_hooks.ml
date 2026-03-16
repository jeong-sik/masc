(** Tests for Tool_trace_hooks — trace span correlation with tool dispatch *)

module Tool_dispatch = Masc_mcp.Tool_dispatch
module Tool_trace_hooks = Masc_mcp.Tool_trace_hooks
module Trace = Masc_mcp.Trace

let setup () =
  Tool_dispatch.clear_hooks ();
  Trace.clear ();
  Tool_trace_hooks.install ()

let test_span_created_on_dispatch () =
  setup ();
  Tool_dispatch.register
    ~tool_name:"__trace_test"
    ~handler:(fun ~name:_ ~args:_ -> Some (true, "ok"));
  let _ = Tool_dispatch.dispatch_structured ~name:"__trace_test" ~args:`Null in
  let recent = Trace.export_recent ~limit:10 () in
  match recent with
  | `List spans ->
    Alcotest.(check bool) "at least one span" true (List.length spans > 0);
    (* Find our span *)
    let has_tool_span = List.exists (fun span ->
      match span with
      | `Assoc fields ->
        List.exists (fun (k, v) ->
          k = "operation" && v = `String "tool:__trace_test"
        ) fields
      | _ -> false
    ) spans in
    Alcotest.(check bool) "tool span found" true has_tool_span
  | _ -> Alcotest.fail "export_recent should return List"

let test_span_has_attributes () =
  setup ();
  Tool_dispatch.register
    ~tool_name:"__trace_attrs"
    ~handler:(fun ~name:_ ~args:_ -> Some (true, "data"));
  let _ = Tool_dispatch.dispatch_structured ~name:"__trace_attrs" ~args:`Null in
  let recent = Trace.export_recent ~limit:10 () in
  match recent with
  | `List (span :: _) ->
    (match span with
     | `Assoc fields ->
       (* Check attributes contain tool_name and success *)
       let attrs = List.assoc_opt "attributes" fields in
       (match attrs with
        | Some (`Assoc attr_list) ->
          let has k = List.exists (fun (ak, _) -> ak = k) attr_list in
          Alcotest.(check bool) "has tool_name attr" true (has "tool_name");
          Alcotest.(check bool) "has success attr" true (has "success");
          Alcotest.(check bool) "has duration_ms attr" true (has "duration_ms")
        | _ -> Alcotest.fail "expected attributes Assoc")
     | _ -> Alcotest.fail "expected span Assoc")
  | _ -> Alcotest.fail "no spans"

let test_error_span_status () =
  setup ();
  Tool_dispatch.register
    ~tool_name:"__trace_err"
    ~handler:(fun ~name:_ ~args:_ -> Some (false, "something failed"));
  let _ = Tool_dispatch.dispatch_structured ~name:"__trace_err" ~args:`Null in
  let recent = Trace.export_recent ~limit:10 () in
  match recent with
  | `List (span :: _) ->
    (match span with
     | `Assoc fields ->
       let status = List.assoc_opt "status" fields in
       (match status with
        | Some (`Assoc [("error", `String msg)]) ->
          Alcotest.(check bool) "error message non-empty"
            true (String.length msg > 0)
        | _ -> Alcotest.fail "expected error status for failed tool")
     | _ -> Alcotest.fail "expected Assoc")
  | _ -> Alcotest.fail "no spans"

let test_success_span_status () =
  setup ();
  Tool_dispatch.register
    ~tool_name:"__trace_ok"
    ~handler:(fun ~name:_ ~args:_ -> Some (true, "fine"));
  let _ = Tool_dispatch.dispatch_structured ~name:"__trace_ok" ~args:`Null in
  let recent = Trace.export_recent ~limit:10 () in
  match recent with
  | `List (span :: _) ->
    (match span with
     | `Assoc fields ->
       let status = List.assoc_opt "status" fields in
       (match status with
        | Some (`String "ok") -> ()
        | _ -> Alcotest.fail "expected ok status for successful tool")
     | _ -> Alcotest.fail "expected Assoc")
  | _ -> Alcotest.fail "no spans"

let test_multiple_calls_multiple_spans () =
  setup ();
  Tool_dispatch.register
    ~tool_name:"__trace_multi"
    ~handler:(fun ~name:_ ~args:_ -> Some (true, "ok"));
  let _ = Tool_dispatch.dispatch_structured ~name:"__trace_multi" ~args:`Null in
  let _ = Tool_dispatch.dispatch_structured ~name:"__trace_multi" ~args:`Null in
  let _ = Tool_dispatch.dispatch_structured ~name:"__trace_multi" ~args:`Null in
  let recent = Trace.export_recent ~limit:10 () in
  match recent with
  | `List spans ->
    let tool_spans = List.filter (fun span ->
      match span with
      | `Assoc fields ->
        List.exists (fun (k, v) ->
          k = "operation" && v = `String "tool:__trace_multi"
        ) fields
      | _ -> false
    ) spans in
    Alcotest.(check bool) "3 spans created" true (List.length tool_spans >= 3)
  | _ -> Alcotest.fail "expected List"

let () =
  Alcotest.run "Tool_trace_hooks" [
    "span_creation", [
      Alcotest.test_case "span on dispatch" `Quick test_span_created_on_dispatch;
      Alcotest.test_case "span attributes" `Quick test_span_has_attributes;
      Alcotest.test_case "multiple calls" `Quick test_multiple_calls_multiple_spans;
    ];
    "span_status", [
      Alcotest.test_case "success status" `Quick test_success_span_status;
      Alcotest.test_case "error status" `Quick test_error_span_status;
    ];
  ]
