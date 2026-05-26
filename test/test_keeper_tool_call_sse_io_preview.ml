open Masc_mcp

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
           ; "api_key", `String "abcdefghijklmnopqrstuvwxyz123456"
           ])
      ~output:"result token abcdefghijklmnopqrstuvwxyz123456"
      ()
  in
  let json = `Assoc fields in
  let args_preview = Option.get (string_member "tool_args_preview" json) in
  let output_preview = Option.get (string_member "tool_output_preview" json) in
  Alcotest.(check bool)
    "sensitive input redacted"
    true
    (String_util.contains_substring args_preview "[REDACTED]");
  Alcotest.(check bool)
    "sensitive output redacted"
    true
    (String_util.contains_substring output_preview "[REDACTED]")
;;

let test_denied_tool_omits_io_previews () =
  let fields =
    Keeper_tools_oas_handler_telemetry.tool_io_preview_fields
      ~tool_name:"keeper_auth_token"
      ~input:(`Assoc [ "token", `String "abcdefghijklmnopqrstuvwxyz123456" ])
      ~output:"abcdefghijklmnopqrstuvwxyz123456"
      ()
  in
  let json = `Assoc fields in
  Alcotest.(check (option bool))
    "redacted flag"
    (Some true)
    (bool_member "tool_io_redacted" json);
  Alcotest.(check bool)
    "input preview omitted"
    true
    (Option.is_none (string_member "tool_args_preview" json));
  Alcotest.(check bool)
    "output preview omitted"
    true
    (Option.is_none (string_member "tool_output_preview" json))
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
            "omits denied tool io"
            `Quick
            test_denied_tool_omits_io_previews
        ] )
    ]
;;
