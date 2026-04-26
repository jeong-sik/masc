(** Tests for Tool_result — structured tool result type *)

module Tool_result = Masc_mcp.Tool_result
module Tool_dispatch = Masc_mcp.Tool_dispatch
module Time_compat = Time_compat

let test_wrap_json_response () =
  let start = 1000.0 in
  let raw = true, {|{"status":"ok","count":42}|} in
  let r = Tool_result.wrap ~tool_name:"masc_status" ~start_time:start raw in
  Alcotest.(check bool) "success" true r.success;
  Alcotest.(check string) "tool_name" "masc_status" r.tool_name;
  (* data should be parsed JSON, not a string *)
  (match r.data with
   | `Assoc fields ->
     Alcotest.(check bool)
       "has status field"
       true
       (List.exists (fun (k, _) -> k = "status") fields)
   | _ -> Alcotest.fail "expected Assoc");
  Alcotest.(check bool) "duration >= 0" true (r.duration_ms >= 0.0)
;;

let test_wrap_plain_string () =
  let start = Time_compat.now () in
  let raw = false, "Something went wrong" in
  let r = Tool_result.wrap ~tool_name:"masc_transition" ~start_time:start raw in
  Alcotest.(check bool) "failure" false r.success;
  Alcotest.(check string) "tool_name" "masc_transition" r.tool_name;
  (* Non-JSON string should be wrapped as `String *)
  match r.data with
  | `String s -> Alcotest.(check string) "plain string preserved" "Something went wrong" s
  | _ -> Alcotest.fail "expected String for non-JSON input"
;;

let test_wrap_prefixed_json_response () =
  let start = 1000.0 in
  let raw =
    true, "✅ Post created:\n{\"id\":\"post-1\",\"content\":\"hello\",\"ok\":true}"
  in
  let r = Tool_result.wrap ~tool_name:"masc_board_post" ~start_time:start raw in
  match r.data with
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
  let raw = true, "done" in
  let r = Tool_result.wrap ~tool_name:"masc_transition" ~start_time:start raw in
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

let test_to_legacy_roundtrip () =
  let start = Time_compat.now () in
  let original = true, "hello world" in
  let r = Tool_result.wrap ~tool_name:"test" ~start_time:start original in
  let success, message = Tool_result.to_legacy r in
  Alcotest.(check bool) "success preserved" true success;
  Alcotest.(check string) "message preserved" "hello world" message
;;

let test_to_legacy_json_roundtrip () =
  let start = Time_compat.now () in
  let json_str = {|{"key":"value"}|} in
  let original = true, json_str in
  let r = Tool_result.wrap ~tool_name:"test" ~start_time:start original in
  let _success, message = Tool_result.to_legacy r in
  (* JSON roundtrip may normalize formatting *)
  let reparsed = Yojson.Safe.from_string message in
  match reparsed with
  | `Assoc [ ("key", `String "value") ] -> ()
  | _ -> Alcotest.fail "JSON roundtrip lost data"
;;

let test_dispatch_structured () =
  (* Register a test handler *)
  Tool_dispatch.register ~tool_name:"__test_tool" ~handler:(fun ~name:_ ~args:_ ->
    Some (true, {|{"result":"ok"}|}));
  Tool_dispatch.register_name_tag ~tool_name:"__test_tool" ~tag:Mod_misc;
  let token =
    match Tool_dispatch.mint_token ~name:"__test_tool" with
    | Ok t -> t
    | Error e -> Alcotest.fail e
  in
  match Tool_dispatch.dispatch_structured ~token ~args:`Null with
  | Some r ->
    Alcotest.(check bool) "success" true r.success;
    Alcotest.(check string) "tool_name" "__test_tool" r.tool_name;
    Alcotest.(check bool) "duration >= 0" true (r.duration_ms >= 0.0)
  | None -> Alcotest.fail "dispatch_structured returned None for registered tool"
;;

let test_dispatch_structured_unknown () =
  match Tool_dispatch.mint_token ~name:"__nonexistent" with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "mint_token should return Error for unknown tool"
;;

let () =
  Alcotest.run
    "Tool_result"
    [ ( "wrap"
      , [ Alcotest.test_case "json response" `Quick test_wrap_json_response
        ; Alcotest.test_case "plain string" `Quick test_wrap_plain_string
        ; Alcotest.test_case
            "prefixed json response"
            `Quick
            test_wrap_prefixed_json_response
        ] )
    ; "to_json", [ Alcotest.test_case "fields present" `Quick test_to_json ]
    ; ( "to_legacy"
      , [ Alcotest.test_case "roundtrip string" `Quick test_to_legacy_roundtrip
        ; Alcotest.test_case "roundtrip json" `Quick test_to_legacy_json_roundtrip
        ] )
    ; ( "dispatch_structured"
      , [ Alcotest.test_case "registered tool" `Quick test_dispatch_structured
        ; Alcotest.test_case "unknown tool" `Quick test_dispatch_structured_unknown
        ] )
    ]
;;
