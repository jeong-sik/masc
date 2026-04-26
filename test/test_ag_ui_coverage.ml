(** AG-UI Protocol Event Bridge Tests *)

open Ag_ui

let () = Printexc.record_backtrace true

(* ---------- Helpers ---------- *)

let check_json_field json key expected_value =
  let open Yojson.Safe.Util in
  let actual = json |> member key |> to_string in
  if actual <> expected_value
  then failwith (Printf.sprintf "Expected %s=%s, got %s" key expected_value actual)
;;

let check_json_has_field json key =
  let open Yojson.Safe.Util in
  match json |> member key with
  | `Null -> failwith (Printf.sprintf "Missing field: %s" key)
  | _ -> ()
;;

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
;;

let test_role_to_string () =
  assert (role_to_string User = "user");
  assert (role_to_string Assistant = "assistant");
  assert (role_to_string System = "system");
  assert (role_to_string Tool = "tool")
;;

(* ---------- Event Serialization Tests ---------- *)

let test_event_to_json_basic () =
  let e = make_event ~thread_id:"room-1" Run_started in
  let json = event_to_json e in
  check_json_field json "type" "RUN_STARTED";
  check_json_field json "threadId" "room-1";
  check_json_has_field json "timestamp"
;;

let test_event_to_json_with_optional_fields () =
  let e =
    make_event
      ~thread_id:"room-1"
      ~run_id:(Some "agent-a")
      ~message_id:(Some "msg-001")
      ~role:(Some Assistant)
      ~delta:(Some "Hello world")
      Text_message_content
  in
  let json = event_to_json e in
  check_json_field json "type" "TEXT_MESSAGE_CONTENT";
  check_json_field json "threadId" "room-1";
  check_json_field json "runId" "agent-a";
  check_json_field json "messageId" "msg-001";
  check_json_field json "role" "assistant";
  check_json_field json "delta" "Hello world"
;;

let test_event_to_json_custom () =
  let e =
    make_event
      ~thread_id:"room-1"
      ~custom_name:(Some "MY_EVENT")
      ~custom_value:(Some (`Assoc [ "key", `String "value" ]))
      Custom
  in
  let json = event_to_json e in
  check_json_field json "type" "CUSTOM";
  check_json_field json "name" "MY_EVENT";
  check_json_has_field json "value"
;;

let test_event_to_sse_format () =
  let e = make_event ~thread_id:"room-1" Run_started in
  let sse = event_to_sse e in
  assert (String.length sse > 0);
  assert (String.sub sse 0 6 = "data: ");
  (* SSE ends with double newline *)
  let len = String.length sse in
  assert (String.sub sse (len - 2) 2 = "\n\n")
;;

(* ---------- MASC → AG-UI Mapping Tests ---------- *)

let test_of_agent_joined () =
  let e = of_agent_joined ~agent_name:"claude" in
  assert (e.event_type = Run_started);
  assert (e.thread_id = "default");
  assert (e.run_id = Some "claude");
  assert (e.custom_name = Some "AGENT_JOINED")
;;

let test_of_agent_left () =
  let e = of_agent_left ~agent_name:"claude" in
  assert (e.event_type = Run_finished);
  assert (e.thread_id = "default");
  assert (e.run_id = Some "claude")
;;

let test_of_broadcast () =
  let events = of_broadcast ~agent_name:"claude" ~message:"Hello" ~message_id:"msg-001" in
  assert (List.length events = 3);
  let e0 = List.nth events 0 in
  let e1 = List.nth events 1 in
  let e2 = List.nth events 2 in
  assert (e0.event_type = Text_message_start);
  assert (e0.role = Some Assistant);
  assert (e1.event_type = Text_message_content);
  assert (e1.delta = Some "Hello");
  assert (e2.event_type = Text_message_end)
;;

let test_of_task_claimed () =
  let e = of_task_claimed ~agent_name:"claude" ~task_id:"task-001" in
  assert (e.event_type = Step_started);
  assert (e.step_name = Some "task-001")
;;

let test_of_task_done () =
  let e = of_task_done ~agent_name:"claude" ~task_id:"task-001" in
  assert (e.event_type = Step_finished);
  assert (e.step_name = Some "task-001")
;;

let test_of_tool_call () =
  let events =
    of_tool_call
      ~agent_name:"claude"
      ~tool_name:"search"
      ~call_id:"call-001"
      ~args_json:"{\"q\": \"test\"}"
  in
  assert (List.length events = 3);
  let e0 = List.nth events 0 in
  assert (e0.event_type = Tool_call_start);
  assert (e0.tool_call_name = Some "search");
  let e1 = List.nth events 1 in
  assert (e1.event_type = Tool_call_args);
  assert (e1.delta = Some "{\"q\": \"test\"}");
  let e2 = List.nth events 2 in
  assert (e2.event_type = Tool_call_end)
;;

let test_of_room_state () =
  let state = `Assoc [ "agents", `Int 3; "tasks", `Int 5 ] in
  let e = of_room_state state in
  assert (e.event_type = State_snapshot);
  assert (e.snapshot = Some state)
;;

let test_of_custom () =
  let value = `Assoc [ "key", `String "value" ] in
  let e = of_custom ~name:"MY_EVENT" value in
  assert (e.event_type = Custom);
  assert (e.custom_name = Some "MY_EVENT")
;;

(* ---------- Task Update Mapping ---------- *)

let test_of_task_update_claimed () =
  let json =
    `Assoc
      [ "id", `String "task-001"; "status", `String "claimed"; "agent", `String "claude" ]
  in
  let e = of_task_update json in
  assert (e.event_type = Step_started)
;;

let test_of_task_update_done () =
  let json =
    `Assoc
      [ "id", `String "task-001"; "status", `String "done"; "agent", `String "claude" ]
  in
  let e = of_task_update json in
  assert (e.event_type = Step_finished)
;;

let test_of_task_update_other () =
  let json =
    `Assoc
      [ "id", `String "task-001"
      ; "status", `String "in_progress"
      ; "agent", `String "claude"
      ]
  in
  let e = of_task_update json in
  assert (e.event_type = Custom);
  assert (e.custom_name = Some "TASK_UPDATE")
;;

(* ---------- Protocol Version ---------- *)

let test_protocol_version () =
  assert (String.length protocol_version > 0);
  assert (String.contains protocol_version '.')
;;

(* ---------- Test Runner ---------- *)

let () =
  let tests =
    [ "event_type_to_string", test_event_type_to_string
    ; "role_to_string", test_role_to_string
    ; "event_to_json_basic", test_event_to_json_basic
    ; "event_to_json_optional_fields", test_event_to_json_with_optional_fields
    ; "event_to_json_custom", test_event_to_json_custom
    ; "event_to_sse_format", test_event_to_sse_format
    ; "of_agent_joined", test_of_agent_joined
    ; "of_agent_left", test_of_agent_left
    ; "of_broadcast", test_of_broadcast
    ; "of_task_claimed", test_of_task_claimed
    ; "of_task_done", test_of_task_done
    ; "of_tool_call", test_of_tool_call
    ; "of_room_state", test_of_room_state
    ; "of_custom", test_of_custom
    ; "of_task_update_claimed", test_of_task_update_claimed
    ; "of_task_update_done", test_of_task_update_done
    ; "of_task_update_other", test_of_task_update_other
    ; "protocol_version", test_protocol_version
    ]
  in
  let passed = ref 0 in
  let failed = ref 0 in
  List.iter
    (fun (name, test) ->
       try
         test ();
         incr passed;
         Printf.printf "  \027[32m[OK]\027[0m  %s\n" name
       with
       | e ->
         incr failed;
         Printf.printf "  \027[31m[FAIL]\027[0m %s: %s\n" name (Printexc.to_string e))
    tests;
  Printf.printf "\n%d passed, %d failed (%d total)\n" !passed !failed (!passed + !failed);
  if !failed > 0 then exit 1
;;
