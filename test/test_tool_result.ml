(** Tests for Tool_result — structured tool result type *)

module Tool_result = Masc_mcp.Tool_result
module Tool_dispatch = Masc_mcp.Tool_dispatch
module Time_compat = Time_compat

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

let test_message_roundtrip () =
  let start = Time_compat.now () in
  let r = Tool_result.ok ~tool_name:"test" ~start_time:start "hello world" in
  let success = r.success in
  let message = Tool_result.message r in
  Alcotest.(check bool) "success preserved" true success;
  Alcotest.(check string) "message preserved" "hello world" message

let test_message_json_roundtrip () =
  let start = Time_compat.now () in
  let json_str = {|{"key":"value"}|} in
  let r = Tool_result.ok ~tool_name:"test" ~start_time:start json_str in
  let message = Tool_result.message r in
  (* JSON roundtrip may normalize formatting *)
  let reparsed = Yojson.Safe.from_string message in
  match reparsed with
  | `Assoc [("key", `String "value")] -> ()
  | _ -> Alcotest.fail "JSON roundtrip lost data"

let test_dispatch_structured () =
  (* Register a test handler *)
  Tool_dispatch.register
    ~tool_name:"__test_tool"
    ~handler:(fun ~name:_ ~args:_ -> Some (Tool_result.quick_ok {|{"result":"ok"}|}));
  Tool_dispatch.register_name_tag ~tool_name:"__test_tool" ~tag:Mod_misc;
  let token = match Tool_dispatch.mint_token ~name:"__test_tool" with Ok t -> t | Error e -> Alcotest.fail e in
  match Tool_dispatch.dispatch_structured ~token ~args:`Null with
  | Some r ->
    Alcotest.(check bool) "success" true r.success;
    Alcotest.(check string) "tool_name" "__test_tool" r.tool_name;
    Alcotest.(check bool) "duration >= 0" true (r.duration_ms >= 0.0)
  | None -> Alcotest.fail "dispatch_structured returned None for registered tool"

let test_dispatch_structured_unknown () =
  match Tool_dispatch.mint_token ~name:"__nonexistent" with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "mint_token should return Error for unknown tool"

let () =
  Alcotest.run "Tool_result" [
    "to_json", [
      Alcotest.test_case "fields present" `Quick test_to_json;
    ];
    "message", [
      Alcotest.test_case "roundtrip string" `Quick test_message_roundtrip;
      Alcotest.test_case "roundtrip json" `Quick test_message_json_roundtrip;
    ];
    "dispatch_structured", [
      Alcotest.test_case "registered tool" `Quick test_dispatch_structured;
      Alcotest.test_case "unknown tool" `Quick test_dispatch_structured_unknown;
    ];
  ]
