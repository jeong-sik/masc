(** #10358: Tool_called events had success=true|false but no error
    discriminator — 142/679 (17.3%) failures landed in
    [telemetry/YYYY-MM/DD.jsonl] with no diagnostic field, forcing
    operators to cross-reference audit_log to know why. These tests
    pin the new optional [error_kind] and [error_message] payload
    fields and the lenient parser's tolerance for missing keys (older
    rows pre-dating this PR). *)

open Alcotest
module T = Masc_mcp.Telemetry_eio

let optional_string_eq = option string

let make ~success ~error_kind ~error_message =
  T.Tool_called
    {
      tool_name = "test_tool";
      success;
      duration_ms = 12;
      agent_id = Some "test-agent";
      source = Some "external_mcp";
      session_id = Some "sess-1";
      operation_id = Some "op-1";
      worker_run_id = Some "run-1";
      error_kind;
      error_message;
    }

let test_payload_round_trip_with_error () =
  let event = make ~success:false
                ~error_kind:(Some "timeout")
                ~error_message:(Some "deadline 200ms hit") in
  let json = T.event_to_yojson event in
  let str = Yojson.Safe.to_string json in
  check bool "error_kind serialised" true
    (Astring.String.is_infix ~affix:"\"error_kind\"" str);
  check bool "timeout literal present" true
    (Astring.String.is_infix ~affix:"\"timeout\"" str);
  check bool "error_message literal present" true
    (Astring.String.is_infix ~affix:"deadline 200ms" str)

let test_payload_round_trip_no_error () =
  let event = make ~success:true ~error_kind:None ~error_message:None in
  match T.event_of_yojson (T.event_to_yojson event) with
  | Ok (T.Tool_called r) ->
      check bool "success preserved" true r.success;
      check optional_string_eq "error_kind None" None r.error_kind;
      check optional_string_eq "error_message None" None r.error_message
  | Ok _ | Error _ -> fail "expected Tool_called round-trip"

(* The lenient parser is what dashboards/diagnostics actually use to
   read existing telemetry day-files.  Rows written before this PR
   omit [error_kind] / [error_message] entirely; they must continue
   to parse with [None] for the new fields rather than failing. *)
let test_lenient_parser_accepts_legacy_rows () =
  let legacy_json =
    `Assoc [
      "timestamp", `Float 1700000000.0;
      "event", `List [
        `String "Tool_called";
        `Assoc [
          "tool_name", `String "legacy_tool";
          "success", `Bool false;
          "duration_ms", `Int 50;
          "agent_id", `String "agent-x";
          "source", `String "external_mcp";
          "session_id", `Null;
          "operation_id", `Null;
          "worker_run_id", `Null;
          (* error_kind and error_message keys absent on purpose *)
        ];
      ];
    ]
  in
  match T.event_record_of_yojson_lenient legacy_json with
  | Ok { event = T.Tool_called r; _ } ->
      check string "tool_name parsed" "legacy_tool" r.tool_name;
      check bool "success parsed" false r.success;
      check optional_string_eq "missing error_kind defaults None" None r.error_kind;
      check optional_string_eq "missing error_message defaults None" None r.error_message
  | Ok _ | Error _ ->
      fail "lenient parser must accept legacy Tool_called rows without error fields"

let () =
  run "tool_called_error_field_10358" [
    ("error_payload", [
        test_case "Some error_kind / error_message survives serialise" `Quick
          test_payload_round_trip_with_error;
        test_case "None payload round-trips through yojson" `Quick
          test_payload_round_trip_no_error;
        test_case "lenient parser accepts pre-#10358 rows" `Quick
          test_lenient_parser_accepts_legacy_rows;
      ]);
  ]
