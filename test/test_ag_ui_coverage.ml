(** AG-UI Protocol Event Bridge Tests *)

open Ag_ui

let () = Printexc.record_backtrace true

(* ---------- Helpers ---------- *)

let check_json_field json key expected_value =
  let open Yojson.Safe.Util in
  let actual = json |> member key |> to_string in
  if actual <> expected_value then
    failwith (Printf.sprintf "Expected %s=%s, got %s" key expected_value actual)

let check_json_has_field json key =
  let open Yojson.Safe.Util in
  match json |> member key with
  | `Null -> failwith (Printf.sprintf "Missing field: %s" key)
  | _ -> ()

(* ---------- Event Type Tests ---------- *)

let test_event_type_to_string () =
  assert (event_type_to_string Run_started = "RUN_STARTED");
  assert (event_type_to_string Run_finished = "RUN_FINISHED");
  assert (event_type_to_string Run_error = "RUN_ERROR");
  assert (event_type_to_string Step_started = "STEP_STARTED");
  assert (event_type_to_string Step_finished = "STEP_FINISHED");
  assert (event_type_to_string Text_message_start = "TEXT_MESSAGE_START");
  assert (event_type_to_string Text_message_content = "TEXT_MESSAGE_CONTENT");
  assert (event_type_to_string Text_message_end = "TEXT_MESSAGE_END");
  assert (event_type_to_string Tool_call_start = "TOOL_CALL_START");
  assert (event_type_to_string Tool_call_args = "TOOL_CALL_ARGS");
  assert (event_type_to_string Tool_call_end = "TOOL_CALL_END");
  assert (event_type_to_string State_snapshot = "STATE_SNAPSHOT");
  assert (event_type_to_string State_delta = "STATE_DELTA");
  assert (event_type_to_string Custom = "CUSTOM")

let test_role_to_string () =
  assert (role_to_string User = "user");
  assert (role_to_string Assistant = "assistant");
  assert (role_to_string System = "system");
  assert (role_to_string Tool = "tool")

(* ---------- Event Serialization Tests ---------- *)

let test_event_to_json_basic () =
  let e = make_event ~thread_id:"workspace-1" Run_started in
  let json = event_to_json e in
  check_json_field json "type" "RUN_STARTED";
  check_json_field json "threadId" "workspace-1";
  check_json_has_field json "timestamp"

let test_event_to_json_with_optional_fields () =
  let e = make_event ~thread_id:"workspace-1"
    ~run_id:(Some "agent-a")
    ~message_id:(Some "msg-001")
    ~role:(Some Assistant)
    ~delta:(Some "Hello world")
    Text_message_content in
  let json = event_to_json e in
  check_json_field json "type" "TEXT_MESSAGE_CONTENT";
  check_json_field json "threadId" "workspace-1";
  check_json_field json "runId" "agent-a";
  check_json_field json "messageId" "msg-001";
  check_json_field json "role" "assistant";
  check_json_field json "delta" "Hello world"

let test_event_to_json_custom () =
  let e = make_event ~thread_id:"workspace-1"
    ~custom_name:(Some "MY_EVENT")
    ~custom_value:(Some (`Assoc [("key", `String "value")]))
    Custom in
  let json = event_to_json e in
  check_json_field json "type" "CUSTOM";
  check_json_field json "name" "MY_EVENT";
  check_json_has_field json "value"

let test_event_to_json_run_error () =
  let e =
    run_error
      ~thread_id:"workspace-1"
      ~run_id:"run-1"
      ~message:"boom"
      ~code:"keeper_failed"
      ()
  in
  let json = event_to_json e in
  check_json_field json "type" "RUN_ERROR";
  check_json_field json "message" "boom";
  check_json_field json "code" "keeper_failed";
  assert (Yojson.Safe.Util.member "value" json = `Null)

let test_run_error_requires_message () =
  match make_event ~thread_id:"workspace-1" Run_error with
  | _ -> failwith "RUN_ERROR without message was accepted"
  | exception Invalid_argument _ -> ()

let test_run_error_rejects_custom_envelope () =
  match
    make_event
      ~thread_id:"workspace-1"
      ~message:(Some "boom")
      ~custom_value:(Some (`Assoc [ "message", `String "legacy" ]))
      Run_error
  with
  | _ -> failwith "RUN_ERROR Custom value envelope was accepted"
  | exception Invalid_argument _ -> ()

let test_event_to_sse_format () =
  let e = make_event ~thread_id:"workspace-1" Run_started in
  let sse = event_to_sse ~id:17 e in
  let transport_only_sse = event_to_sse e in
  assert (String.length sse > 0);
  assert (String.starts_with ~prefix:"id: 17\ndata: " sse);
  assert (String.starts_with ~prefix:"data: " transport_only_sse);
  assert (not (String.starts_with ~prefix:"id:" transport_only_sse));
  (* SSE ends with double newline *)
  let len = String.length sse in
  assert (String.sub sse (len - 2) 2 = "\n\n")

let test_of_custom () =
  let value = `Assoc [("key", `String "value")] in
  let e = of_custom ~name:"MY_EVENT" value in
  assert (e.event_type = Custom);
  assert (e.custom_name = Some "MY_EVENT")

(* ---------- Protocol Version ---------- *)

let test_protocol_version () =
  assert (String.length protocol_version > 0);
  assert (String.contains protocol_version '.')

(* ---------- Test Runner ---------- *)

let () =
  let tests = [
    ("event_type_to_string", test_event_type_to_string);
    ("role_to_string", test_role_to_string);
    ("event_to_json_basic", test_event_to_json_basic);
    ("event_to_json_optional_fields", test_event_to_json_with_optional_fields);
    ("event_to_json_custom", test_event_to_json_custom);
    ("event_to_json_run_error", test_event_to_json_run_error);
    ("run_error_requires_message", test_run_error_requires_message);
    ("run_error_rejects_custom_envelope", test_run_error_rejects_custom_envelope);
    ("event_to_sse_format", test_event_to_sse_format);
    ("of_custom", test_of_custom);
    ("protocol_version", test_protocol_version);
  ] in
  let passed = ref 0 in
  let failed = ref 0 in
  List.iter (fun (name, test) ->
    try
      test ();
      incr passed;
      Printf.printf "  \027[32m[OK]\027[0m  %s\n" name
    with e ->
      incr failed;
      Printf.printf "  \027[31m[FAIL]\027[0m %s: %s\n" name (Printexc.to_string e)
  ) tests;
  Printf.printf "\n%d passed, %d failed (%d total)\n" !passed !failed (!passed + !failed);
  if !failed > 0 then exit 1
