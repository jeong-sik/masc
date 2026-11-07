open Alcotest

(* Fixtures are sanitized Vibe 3.1.0 captures; fixtures/vibe_headless/README.md
   names the evidence run each one comes from. *)

module Vibe = Runtime_vibe_headless

let read name =
  In_channel.with_open_bin ("fixtures/vibe_headless/" ^ name) In_channel.input_all
;;

let ok_or_fail = function
  | Ok value -> value
  | Error error -> fail (Vibe.error_to_string error)
;;

let export name = ok_or_fail (Vibe.decode_export (read name))

let entry_kind = function
  | Vibe.Message { role = Vibe.User; _ } -> "user message"
  | Vibe.Message { role = Vibe.Assistant; _ } -> "assistant message"
  | Vibe.Message { role = Vibe.Unrecognized_role role; _ } -> "message " ^ role
  | Vibe.Reasoning _ -> "reasoning"
  | Vibe.Effect _ -> "effect"
  | Vibe.Unrecognized_entry { kind; _ } -> "unrecognized " ^ kind
;;

let effects entries =
  List.filter_map
    (function
      | Vibe.Effect { status; error; _ } -> Some (status, error)
      | Vibe.Message _ | Vibe.Reasoning _ | Vibe.Unrecognized_entry _ -> None)
    entries
;;

let test_finished () =
  let e = export "export-finished.json" in
  check bool "finished" true (e.outcome = Vibe.Finished);
  check int "exit code" 0 e.exit_code;
  check bool "no error" true (Option.is_none e.error);
  check bool "session" true (Option.is_some e.session_id);
  check bool "usage" true (Option.is_some e.usage);
  check (option (float 0.)) "plan cost" (Some 0.0) e.cost_usd
;;

let test_usage_error () =
  let e = export "export-usage-error.json" in
  check bool "usage_error" true (e.outcome = Vibe.Usage_error);
  check int "exit code" 1 e.exit_code;
  check bool "no session before start" true (Option.is_none e.session_id);
  match e.error with
  | Some { code = None; _ } -> ()
  | Some { code = Some code; _ } -> fail ("unexpected error code " ^ code)
  | None -> fail "usage_error without an error"
;;

let test_infrastructure_failure () =
  let e = export "export-infrastructure-failure.json" in
  check bool "infrastructure_failure" true (e.outcome = Vibe.Infrastructure_failure);
  check int "exit code" 2 e.exit_code;
  check (option string) "provider refusal code" (Some "backend_error")
    (Option.bind e.error (fun (error : Vibe.run_error) -> error.code))
;;

let test_limits () =
  let deadline = export "export-deadline.json" in
  check bool "deadline" true (deadline.outcome = Vibe.Deadline);
  check int "deadline exit" 3 deadline.exit_code;
  check bool "deadline before a session" true (Option.is_none deadline.usage);
  let tokens = export "export-token-limit.json" in
  check bool "token_limit" true (tokens.outcome = Vibe.Token_limit);
  check bool "interrupted" true (tokens.stop_reason = Some Vibe.Interrupted);
  let turns = export "export-turn-limit.json" in
  check bool "turn_limit" true (turns.outcome = Vibe.Turn_limit);
  check bool "limit" true (turns.stop_reason = Some Vibe.Limit)
;;

let with_field name value text =
  match Yojson.Safe.from_string text with
  | `Assoc fields ->
    Yojson.Safe.to_string
      (`Assoc ((name, value) :: List.remove_assoc name fields))
  | _ -> fail "fixture is not an object"
;;

let without_field name text =
  match Yojson.Safe.from_string text with
  | `Assoc fields -> Yojson.Safe.to_string (`Assoc (List.remove_assoc name fields))
  | _ -> fail "fixture is not an object"
;;

let test_export_boundaries () =
  let finished = read "export-finished.json" in
  (match Vibe.decode_export (with_field "schema_version" (`Int 2) finished) with
   | Error _ -> ()
   | Ok _ -> fail "another schema_version decoded");
  (match Vibe.decode_export (without_field "session_id" finished) with
   | Error _ -> ()
   | Ok _ -> fail "a missing field decoded");
  match Vibe.decode_export (with_field "outcome" (`String "paused") finished) with
  | Ok { outcome = Vibe.Unrecognized_outcome "paused"; _ } -> ()
  | Ok _ -> fail "an unknown outcome became a known one"
  | Error error -> fail (Vibe.error_to_string error)
;;

let test_entries () =
  let entries = ok_or_fail (Vibe.decode_entries (read "entries-first-call.json")) in
  check (list string) "kinds"
    [ "user message"; "reasoning"; "assistant message" ]
    (List.map entry_kind entries);
  match List.rev entries with
  | Vibe.Message { role = Vibe.Assistant; content = [ Vibe.Text "ok" ]; _ } :: _ -> ()
  | _ -> fail "the last entry is not the assistant's text"
;;

let test_effects () =
  let completed = ok_or_fail (Vibe.decode_entries (read "entries-tool-completed.json")) in
  (match effects completed with
   | [ (Vibe.Completed, None) ] -> ()
   | _ -> fail "expected one completed effect without an error");
  let denied = ok_or_fail (Vibe.decode_entries (read "entries-tool-denied.json")) in
  match effects denied with
  | [ (Vibe.Failed, Some { code = Vibe.Tool_denied; _ }) ] -> ()
  | _ -> fail "expected one failed effect denied by the approval callback"
;;

let test_streaming () =
  let lines =
    read "streaming-first-call.ndjson"
    |> String.split_on_char '\n'
    |> List.filter (fun line -> String.trim line <> "")
  in
  let entries = List.map (fun line -> ok_or_fail (Vibe.decode_streaming_line line)) lines in
  check (list string) "kinds"
    [ "user message"; "reasoning"; "assistant message" ]
    (List.map entry_kind entries);
  let unknown =
    {|{"type":"todo","sessionId":"s","turnId":"t","items":[]}|}
  in
  match Vibe.decode_streaming_line unknown with
  | Ok (Vibe.Unrecognized_entry { kind = "todo"; _ }) -> ()
  | Ok _ -> fail "an unknown entry type became a known one"
  | Error error -> fail (Vibe.error_to_string error)
;;

let () =
  run "runtime_vibe_headless"
    [ ( "export.json"
      , [ test_case "finished" `Quick test_finished
        ; test_case "usage_error" `Quick test_usage_error
        ; test_case "infrastructure_failure" `Quick test_infrastructure_failure
        ; test_case "limits" `Quick test_limits
        ; test_case "boundaries" `Quick test_export_boundaries
        ] )
    ; ( "entries"
      , [ test_case "json" `Quick test_entries
        ; test_case "effects" `Quick test_effects
        ; test_case "streaming" `Quick test_streaming
        ] )
    ]
;;
