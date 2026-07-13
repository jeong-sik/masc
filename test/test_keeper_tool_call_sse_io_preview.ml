open Masc

let member key json = Yojson.Safe.Util.member key json

let string_member key json =
  match member key json with
  | `String value -> Some value
  | _ -> None
;;

let bool_member key json =
  match member key json with
  | `Bool value -> Some value
  | _ -> None
;;

let test_tool_io_preview_fields_are_redacted () =
  let fields =
    Keeper_tools_oas_handler_telemetry.tool_io_preview_fields
      ~tool_name:"tool_execute"
      ~input:
        (`Assoc
           [ "cmd", `String "echo ok"
           ; "api_key", `String "sk-proj-abcdefghijklmnopqrstuvwxyz123456"
           ])
      ~output:"result token sk-proj-abcdefghijklmnopqrstuvwxyz123456"
      ()
  in
  let json = `Assoc fields in
  let args_preview = Option.get (string_member "tool_args_preview" json) in
  let output_preview = Option.get (string_member "tool_output_preview" json) in
  let tool_args = member "tool_args" json in
  let tool_result = member "tool_result" json in
  Alcotest.(check bool)
    "sensitive input redacted"
    true
    (String_util.contains_substring args_preview "[REDACTED]");
  Alcotest.(check bool)
    "sensitive output redacted"
    true
    (String_util.contains_substring output_preview "[REDACTED]");
  Alcotest.(check string)
    "structured input keeps safe field"
    "echo ok"
    (tool_args |> member "cmd" |> Yojson.Safe.Util.to_string);
  Alcotest.(check string)
    "structured input redacts sensitive field"
    "[REDACTED]"
    (tool_args |> member "api_key" |> Yojson.Safe.Util.to_string);
  Alcotest.(check string)
    "structured output redacts sensitive value"
    "result token [REDACTED]"
    (Yojson.Safe.Util.to_string tool_result)
;;

let test_sensitive_named_tool_preserves_redacted_io () =
  let fields =
    Keeper_tools_oas_handler_telemetry.tool_io_preview_fields
      ~tool_name:"keeper_auth_token"
      ~input:(`Assoc [ "token", `String "abcdefghijklmnopqrstuvwxyz123456" ])
      ~output:"abcdefghijklmnopqrstuvwxyz123456"
      ()
  in
  let json = `Assoc fields in
  Alcotest.(check bool)
    "input preview present"
    true
    (Option.is_some (string_member "tool_args_preview" json));
  Alcotest.(check bool)
    "output preview present"
    true
    (Option.is_some (string_member "tool_output_preview" json));
  Alcotest.(check bool)
    "structured input present"
    true
    (member "tool_args" json <> `Null);
  Alcotest.(check bool)
    "structured output present"
    true
    (member "tool_result" json <> `Null);
  Alcotest.(check string)
    "input secret redacted"
    "[REDACTED]"
    (member "tool_args" json |> member "token" |> Yojson.Safe.Util.to_string)
;;

let () =
  Alcotest.run
    "keeper_tool_call_sse_io_preview"
    [ ( "preview_fields"
      , [ Alcotest.test_case
            "redacts bounded previews"
            `Quick
            test_tool_io_preview_fields_are_redacted
        ; Alcotest.test_case
            "preserves redacted sensitive-named tool io"
            `Quick
            test_sensitive_named_tool_preserves_redacted_io
        ] )
    ]
;;
