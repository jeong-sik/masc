(** Tests for Typed_tool_masc — MASC typed tool bridge and broadcast PoC. *)

open Masc_mcp

let parse = Agent_sdk.Tool_schema_gen.parse Tool_broadcast_typed.broadcast_schema

let test_parse_valid () =
  let json = `Assoc [("message", `String "hello world")] in
  match parse json with
  | Ok (message, format) ->
    Alcotest.(check string) "message" "hello world" message;
    Alcotest.(check string) "format default" "" format
  | Error e -> Alcotest.fail ("parse failed: " ^ e)

let test_parse_with_format () =
  let json = `Assoc [("message", `String "hi"); ("format", `String "compact")] in
  match parse json with
  | Ok (message, format) ->
    Alcotest.(check string) "message" "hi" message;
    Alcotest.(check string) "format" "compact" format
  | Error e -> Alcotest.fail ("parse failed: " ^ e)

let test_parse_missing_message () =
  let json = `Assoc [("format", `String "compact")] in
  match parse json with
  | Ok _ -> Alcotest.fail "expected parse error"
  | Error _ -> ()

let test_parse_wrong_type () =
  let json = `Assoc [("message", `List [])] in
  match parse json with
  | Ok _ -> Alcotest.fail "expected parse error"
  | Error _ -> ()

let test_handler_success () =
  match Tool_broadcast_typed.handle_broadcast ("hello @claude", "") with
  | Ok output ->
    Alcotest.(check bool) "delivered" true output.delivered;
    Alcotest.(check string) "message" "hello @claude" output.room_message;
    Alcotest.(check (option string)) "mention" (Some "claude") output.mention
  | Error e -> Alcotest.fail ("handler failed: " ^ e)

let test_handler_empty () =
  match Tool_broadcast_typed.handle_broadcast ("   ", "") with
  | Ok _ -> Alcotest.fail "expected error"
  | Error _ -> ()

let test_handler_trim () =
  match Tool_broadcast_typed.handle_broadcast ("  trimmed  ", "") with
  | Ok output -> Alcotest.(check string) "trimmed" "trimmed" output.room_message
  | Error e -> Alcotest.fail e

let test_encode_mention () =
  let output : Tool_broadcast_typed.broadcast_output =
    { delivered = true; room_message = "hi"; mention = Some "alice" } in
  let json = Tool_broadcast_typed.encode_broadcast output in
  let open Yojson.Safe.Util in
  Alcotest.(check string) "mention" "alice" (json |> member "mention" |> to_string)

let test_encode_no_mention () =
  let output : Tool_broadcast_typed.broadcast_output =
    { delivered = true; room_message = "hi"; mention = None } in
  let json = Tool_broadcast_typed.encode_broadcast output in
  let open Yojson.Safe.Util in
  Alcotest.(check bool) "delivered" true (json |> member "delivered" |> to_bool)

let test_e2e_success () =
  let oas_tool = Typed_tool_masc.to_oas Tool_broadcast_typed.tool in
  let json = `Assoc [("message", `String "typed e2e")] in
  match Agent_sdk.Typed_tool.execute oas_tool json with
  | Ok { content } ->
    let result = Yojson.Safe.from_string content in
    let open Yojson.Safe.Util in
    Alcotest.(check bool) "delivered" true (result |> member "delivered" |> to_bool)
  | Error e -> Alcotest.fail e.message

let test_e2e_parse_error () =
  let oas_tool = Typed_tool_masc.to_oas Tool_broadcast_typed.tool in
  match Agent_sdk.Typed_tool.execute oas_tool (`Assoc [("message", `List [])]) with
  | Ok _ -> Alcotest.fail "expected error"
  | Error e -> Alcotest.(check bool) "recoverable" true e.recoverable

let test_e2e_handler_error () =
  let oas_tool = Typed_tool_masc.to_oas Tool_broadcast_typed.tool in
  match Agent_sdk.Typed_tool.execute oas_tool (`Assoc [("message", `String "")]) with
  | Ok _ -> Alcotest.fail "expected error"
  | Error e -> Alcotest.(check bool) "not recoverable" false e.recoverable

let test_to_spec () =
  let spec = Typed_tool_masc.to_spec Tool_broadcast_typed.tool in
  Alcotest.(check string) "name" "masc_broadcast_typed" spec.name;
  Alcotest.(check bool) "requires_join" true spec.requires_join

let test_params () =
  let schema = Typed_tool_masc.schema Tool_broadcast_typed.tool in
  Alcotest.(check int) "params" 2 (List.length schema.parameters)

let () =
  Alcotest.run "Typed_tool_masc" [
    ("parse", [
      Alcotest.test_case "valid" `Quick test_parse_valid;
      Alcotest.test_case "with format" `Quick test_parse_with_format;
      Alcotest.test_case "missing message" `Quick test_parse_missing_message;
      Alcotest.test_case "wrong type" `Quick test_parse_wrong_type;
    ]);
    ("handler", [
      Alcotest.test_case "success" `Quick test_handler_success;
      Alcotest.test_case "empty" `Quick test_handler_empty;
      Alcotest.test_case "trim" `Quick test_handler_trim;
    ]);
    ("encode", [
      Alcotest.test_case "mention" `Quick test_encode_mention;
      Alcotest.test_case "no mention" `Quick test_encode_no_mention;
    ]);
    ("e2e", [
      Alcotest.test_case "success" `Quick test_e2e_success;
      Alcotest.test_case "parse error" `Quick test_e2e_parse_error;
      Alcotest.test_case "handler error" `Quick test_e2e_handler_error;
    ]);
    ("registration", [
      Alcotest.test_case "to_spec" `Quick test_to_spec;
      Alcotest.test_case "params" `Quick test_params;
    ]);
  ]
