(** Tests for Trace module *)

module T = Masc_mcp.Trace

let setup () = T.clear ()

let test_start_and_end_span () =
  setup ();
  let span = T.start_span ~operation:"test_op" ~agent:"claude" () in
  Alcotest.(check string) "agent" "claude" span.agent;
  Alcotest.(check string) "operation" "test_op" span.operation;
  Alcotest.(check bool) "end_time none" true (span.end_time = None);
  T.end_span span;
  Alcotest.(check bool) "end_time set" true (span.end_time <> None);
  Alcotest.(check bool) "status ok" true
    (T.equal_span_status span.status T.Ok)

let test_parent_child () =
  setup ();
  let parent = T.start_span ~operation:"parent" ~agent:"claude" () in
  let child = T.start_span ~parent ~operation:"child" ~agent:"claude" () in
  Alcotest.(check string) "same trace" parent.trace_id child.trace_id;
  Alcotest.(check bool) "parent_id set" true
    (child.parent_id = Some parent.span_id);
  Alcotest.(check bool) "lamport ordering" true
    (child.lamport_start > parent.lamport_start)

let test_cross_agent_trace () =
  setup ();
  let span1 = T.start_span ~operation:"request" ~agent:"claude" () in
  T.end_span span1;
  (* Simulate receiving remote lamport time *)
  let _ = T.record_recv ~remote_time:span1.lamport_start in
  let span2 = T.start_span ~trace_id:span1.trace_id
      ~operation:"handle" ~agent:"codex" () in
  Alcotest.(check string) "same trace" span1.trace_id span2.trace_id;
  Alcotest.(check bool) "causal ordering" true
    (span2.lamport_start > span1.lamport_start)

let test_attributes () =
  setup ();
  let span = T.start_span ~operation:"test" ~agent:"claude" () in
  T.set_attribute span "task_id" "t-001";
  T.set_attribute span "room" "kidsnote";
  Alcotest.(check int) "two attributes" 2 (List.length span.attributes)

let test_span_to_json () =
  setup ();
  let span = T.start_span ~operation:"test" ~agent:"claude" () in
  T.set_attribute span "key" "value";
  T.end_span span;
  let json = T.span_to_json span in
  match json with
  | `Assoc fields ->
      Alcotest.(check bool) "has trace_id" true
        (List.mem_assoc "trace_id" fields);
      Alcotest.(check bool) "has span_id" true
        (List.mem_assoc "span_id" fields);
      Alcotest.(check bool) "has attributes" true
        (List.mem_assoc "attributes" fields)
  | _ -> Alcotest.fail "expected JSON object"

let test_export_trace () =
  setup ();
  let span1 = T.start_span ~operation:"a" ~agent:"claude" () in
  let _span2 = T.start_span ~trace_id:span1.trace_id ~operation:"b" ~agent:"codex" () in
  let _span3 = T.start_span ~operation:"c" ~agent:"gemini" () in
  let exported = T.export_trace span1.trace_id in
  Alcotest.(check int) "two spans in trace" 2 (List.length exported)

let test_export_recent () =
  setup ();
  for i = 1 to 5 do
    let _ = T.start_span ~operation:(Printf.sprintf "op_%d" i) ~agent:"claude" () in
    ()
  done;
  match T.export_recent ~limit:3 () with
  | `List l -> Alcotest.(check int) "limited to 3" 3 (List.length l)
  | _ -> Alcotest.fail "expected list"

let test_spans_by_agent () =
  setup ();
  let _ = T.start_span ~operation:"a" ~agent:"claude" () in
  let _ = T.start_span ~operation:"b" ~agent:"codex" () in
  let _ = T.start_span ~operation:"c" ~agent:"claude" () in
  let claude_spans = T.spans_by_agent "claude" in
  let codex_spans = T.spans_by_agent "codex" in
  Alcotest.(check int) "claude has 2" 2 (List.length claude_spans);
  Alcotest.(check int) "codex has 1" 1 (List.length codex_spans)

let test_error_status () =
  setup ();
  let span = T.start_span ~operation:"fail" ~agent:"claude" () in
  T.end_span ~status:(T.Error "something went wrong") span;
  Alcotest.(check bool) "error status" true
    (match span.status with T.Error _ -> true | _ -> false)

let test_lamport_monotonic () =
  setup ();
  let times = List.init 10 (fun _ ->
    let s = T.start_span ~operation:"x" ~agent:"a" () in
    s.lamport_start
  ) in
  let rec is_sorted = function
    | [] | [_] -> true
    | a :: b :: rest -> a < b && is_sorted (b :: rest)
  in
  Alcotest.(check bool) "monotonically increasing" true (is_sorted times)

let () =
  Alcotest.run "Trace" [
    "span", [
      Alcotest.test_case "start and end" `Quick test_start_and_end_span;
      Alcotest.test_case "parent-child" `Quick test_parent_child;
      Alcotest.test_case "cross-agent" `Quick test_cross_agent_trace;
      Alcotest.test_case "attributes" `Quick test_attributes;
      Alcotest.test_case "error status" `Quick test_error_status;
    ];
    "export", [
      Alcotest.test_case "span to json" `Quick test_span_to_json;
      Alcotest.test_case "export trace" `Quick test_export_trace;
      Alcotest.test_case "export recent" `Quick test_export_recent;
    ];
    "ordering", [
      Alcotest.test_case "by agent" `Quick test_spans_by_agent;
      Alcotest.test_case "lamport monotonic" `Quick test_lamport_monotonic;
    ];
  ]
