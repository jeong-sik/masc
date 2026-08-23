open Alcotest

module Observer = Masc_tui_observer

(* Frames as the live server wrote them on 2026-08-23 (observer-sample.sse),
   trimmed to the fields the decoder reads plus a few it must ignore. *)
let tool_called_frame =
  "id: 26163\n\
   event: message\n\
   data: {\"type\":\"agent_core:tool_called\",\"event_type\":\"tool_called\",\
   \"event_id\":\"evt-0c69\",\"ts_unix\":1787505641.288864,\
   \"correlation_id\":\"trace-1787333553810-0001a\",\"run_id\":\"wr-1a02\",\
   \"parent_event_id\":null,\"agent_name\":\"analyst\",\"task_id\":\"task-494\",\
   \"tool_name\":\"read_file\",\"payload\":{\"agent_name\":\"analyst\",\
   \"batch_index\":0,\"batch_size\":2,\"execution_mode\":\"concurrent\",\
   \"tool_name\":\"read_file\",\"tool_use_id\":\"tu-1\",\"turn\":2086}}\n\n"

let heartbeat_frame =
  "data: {\"type\":\"keeper_heartbeat\",\"name\":\"taskmaster\",\
   \"ts_unix\":1787505649.446111,\"phase\":\"turn_running\",\"in_turn\":true,\
   \"in_flight_elapsed_ms\":2189925.43,\"since_last_progress_ms\":13093.6}\n\n"

let turn_complete_frame =
  "data: {\"type\":\"keeper_turn_complete\",\"name\":\"rondo\",\"turn\":2086,\
   \"model_used\":null,\"input_tokens\":73877,\"output_tokens\":358,\
   \"cost_usd\":0.02581816,\"tool_calls_made\":0,\"total_turns\":547,\
   \"ts_unix\":1787505649.491379}\n\n"

let decode_all chunks =
  let reader = Observer.create () in
  List.concat_map (Observer.feed reader) chunks

let summary = function
  | Observer.Event (Observer.Agent_core e) ->
      Printf.sprintf "agent_core(%s,%s,%s,turn=%s,batch=%s)"
        (Option.value ~default:"-" e.Observer.agent)
        (match e.Observer.kind with
         | Observer.Tool_called -> "tool_called"
         | Observer.Tool_completed -> "tool_completed"
         | Observer.Turn_started -> "turn_started"
         | Observer.Turn_ready -> "turn_ready"
         | Observer.Turn_completed -> "turn_completed"
         | Observer.Agent_started -> "agent_started"
         | Observer.Agent_completed -> "agent_completed"
         | Observer.Agent_failed -> "agent_failed"
         | Observer.Agent_yielded -> "agent_yielded"
         | Observer.Tool_approval_completed -> "tool_approval_completed"
         | Observer.Telemetry -> "telemetry"
         | Observer.Agent_core_other name -> "other:" ^ name)
        (Option.value ~default:"-" e.Observer.tool)
        (match e.Observer.turn with Some t -> string_of_int t | None -> "-")
        (match e.Observer.batch with
         | Some (i, n) -> Printf.sprintf "%d/%d" i n
         | None -> "-")
  | Observer.Event (Observer.Keeper_heartbeat h) ->
      Printf.sprintf "heartbeat(%s,%s,in_turn=%s)" h.Observer.hb_keeper
        (Option.value ~default:"-" h.Observer.hb_phase)
        (match h.Observer.hb_in_turn with
         | Some b -> string_of_bool b
         | None -> "-")
  | Observer.Event (Observer.Keeper_tool_call c) ->
      Printf.sprintf "keeper_tool_call(%s,%s,%s,%s)" c.Observer.kt_keeper
        c.Observer.kt_tool
        (match c.Observer.kt_duration_ms with
         | Some ms -> Printf.sprintf "%.0fms" ms
         | None -> "-")
        (Option.value ~default:"-" c.Observer.kt_disposition)
  | Observer.Event (Observer.Keeper_turn_complete t) ->
      Printf.sprintf "turn_complete(%s,turn=%s,cost=%s)" t.Observer.tc_keeper
        (match t.Observer.tc_turn with Some n -> string_of_int n | None -> "-")
        (match t.Observer.tc_cost_usd with
         | Some c -> Printf.sprintf "%.4f" c
         | None -> "-")
  | Observer.Event (Observer.Keeper_composite_changed { keeper; _ }) ->
      "composite(" ^ keeper ^ ")"
  | Observer.Event (Observer.Keeper_chat_appended { keeper; connector; _ }) ->
      Printf.sprintf "chat(%s,%s)" keeper (Option.value ~default:"-" connector)
  | Observer.Event (Observer.Snapshot name) -> "snapshot:" ^ name
  | Observer.Event (Observer.Other name) -> "other:" ^ name
  | Observer.Undecodable detail -> "undecodable:" ^ detail

let test_the_session_id_is_read_off_the_initialize_answer () =
  check (result string string) "matched without regard to case"
    (Ok "mcp_VT8T6lg")
    (Observer.session_id_of_headers
       [ ("Content-Type", "application/json"); ("MCP-Session-ID", " mcp_VT8T6lg ") ]);
  check bool "an answer without the header is an error, not an empty id" true
    (Result.is_error
       (Observer.session_id_of_headers [ ("Content-Type", "application/json") ]));
  check bool "a blank header is an error too" true
    (Result.is_error (Observer.session_id_of_headers [ ("Mcp-Session-Id", "") ]))

let test_the_initialize_body_names_the_method_and_the_client () =
  match Yojson.Safe.from_string (Observer.initialize_request_body ~client_version:"0.24.0") with
  | `Assoc fields ->
      let string_at key = function
        | `Assoc inner -> (
            match List.assoc_opt key inner with Some (`String v) -> Some v | _ -> None)
        | _ -> None
      in
      check (option string) "method" (Some "initialize") (string_at "method" (`Assoc fields));
      let params = Option.value ~default:`Null (List.assoc_opt "params" fields) in
      check (option string) "protocolVersion" (Some "2025-06-18")
        (string_at "protocolVersion" params);
      let client =
        match params with
        | `Assoc inner -> Option.value ~default:`Null (List.assoc_opt "clientInfo" inner)
        | _ -> `Null
      in
      check (option string) "client name" (Some "masc-tui") (string_at "name" client);
      check (option string) "client version" (Some "0.24.0") (string_at "version" client)
  | _ -> fail "initialize body is not an object"

let test_a_tool_call_decodes_with_its_turn_and_batch () =
  check (list string) "the frame becomes one typed event"
    [ "agent_core(analyst,tool_called,read_file,turn=2086,batch=0/2)" ]
    (List.map summary (decode_all [ tool_called_frame ]))

let bare_heartbeat_frame =
  "data: {\"type\":\"keeper_heartbeat\",\"name\":\"lane-smith\",\"ts_unix\":1787505653.07}\n\n"

let keeper_tool_call_frame =
  "data: {\"type\":\"keeper_tool_call\",\"name\":\"rondo\",\"tool_name\":\"tool_execute\",\
   \"duration_ms\":14534,\"disposition\":\"completed\",\"ts_unix\":1787507566.14,\
   \"tool_args\":{\"argv\":[\"dune\",\"build\"]},\"tool_result\":{\"ok\":true}}\n\n"

let test_keeper_events_decode_by_name () =
  check (list string) "heartbeat, bare heartbeat, settlement, keeper tool call"
    [ "heartbeat(taskmaster,turn_running,in_turn=true)"
    ; "heartbeat(lane-smith,-,in_turn=-)"
    ; "turn_complete(rondo,turn=2086,cost=0.0258)"
    ; "keeper_tool_call(rondo,tool_execute,14534ms,completed)"
    ]
    (List.map summary
       (decode_all
          [ heartbeat_frame; bare_heartbeat_frame; turn_complete_frame
          ; keeper_tool_call_frame ]))

let test_a_line_cut_by_the_chunk_boundary_is_held () =
  let at = String.index tool_called_frame '{' + 40 in
  let head = String.sub tool_called_frame 0 at in
  let tail =
    String.sub tool_called_frame at (String.length tool_called_frame - at)
  in
  let reader = Observer.create () in
  check (list string) "the cut line produces nothing yet" []
    (List.map summary (Observer.feed reader head));
  check (list string) "and decodes whole once the rest arrives"
    [ "agent_core(analyst,tool_called,read_file,turn=2086,batch=0/2)" ]
    (List.map summary (Observer.feed reader tail))

let untaught_agent_core_frame =
  "data: {\"type\":\"agent_core:relay_dropped\",\"event_type\":\"relay_dropped\",\
   \"agent_name\":\"lane-smith\",\"ts_unix\":1.0}\n"

let test_what_this_build_was_not_taught_keeps_its_name () =
  check (list string) "snapshots are named, not retained; unknown types are named"
    [ "snapshot:execution_snapshot"
    ; "other:internal_agent_runs_changed"
    ; "agent_core(lane-smith,other:relay_dropped,-,turn=-,batch=-)"
    ]
    (List.map summary
       (decode_all
          [ "data: {\"type\":\"execution_snapshot\",\"payload\":{\"keepers\":[]}}\n"
          ; "data: {\"type\":\"internal_agent_runs_changed\"}\n"
          ; untaught_agent_core_frame
          ]));
  match decode_all [ untaught_agent_core_frame ] with
  | [ Observer.Event
        (Observer.Agent_core { Observer.kind = Observer.Agent_core_other name; _ }) ] ->
      check string "the family keeps the untaught event_type" "relay_dropped" name
  | _ -> fail "expected one agent_core event of an untaught kind"

let test_streaming_telemetry_names_no_agent () =
  (* Provider streaming telemetry: agent_name null, payload a tagged list. *)
  check (list string) "it is still an event of the family, with no agent"
    [ "agent_core(-,telemetry,-,turn=-,batch=-)" ]
    (List.map summary
       (decode_all
          [ "data: {\"type\":\"agent_core:telemetry_event\",\"event_type\":\
             \"telemetry_event\",\"agent_name\":null,\"ts_unix\":1.0,\
             \"payload\":[\"Streaming_summary\",{\"ttft_ms\":19048.7}]}\n"
          ]))

let test_a_frame_this_cannot_read_says_why () =
  let reasons =
    decode_all
      [ "data: nope\n"
      ; "data: {\"ts_unix\":1.0}\n"
      ; "data: {\"type\":\"agent_core:tool_called\",\"event_type\":\"tool_called\",\"agent_name\":\"x\"}\n"
      ; "data:{\"type\":\"keeper_heartbeat\"}\n"
      ]
    |> List.map (function
         | Observer.Undecodable detail -> detail
         | other -> "event:" ^ summary other)
  in
  match reasons with
  | [ bad_json; no_type; no_agent; noncanonical ] ->
      check bool "bad JSON is reported as such" true
        (String.starts_with ~prefix:"invalid JSON" bad_json);
      check string "a payload without a type" "event carries no type" no_type;
      check string "an agent_core payload without its timestamp"
        "agent_core:tool_called carries no ts_unix" no_agent;
      check bool "a data line without the canonical prefix is reported" true
        (String.starts_with ~prefix:"data line without" noncanonical)
  | _ -> failf "expected four reasons, got %d" (List.length reasons)

let () =
  run "tui observer"
    [ ( "session"
      , [ test_case "the session id is read off the initialize answer" `Quick
            test_the_session_id_is_read_off_the_initialize_answer
        ; test_case "the initialize body names the method and the client" `Quick
            test_the_initialize_body_names_the_method_and_the_client
        ] )
    ; ( "events"
      , [ test_case "a tool call decodes with its turn and batch" `Quick
            test_a_tool_call_decodes_with_its_turn_and_batch
        ; test_case "keeper events decode by name" `Quick
            test_keeper_events_decode_by_name
        ; test_case "a line cut by the chunk boundary is held" `Quick
            test_a_line_cut_by_the_chunk_boundary_is_held
        ; test_case "what this build was not taught keeps its name" `Quick
            test_what_this_build_was_not_taught_keeps_its_name
        ; test_case "streaming telemetry names no agent" `Quick
            test_streaming_telemetry_names_no_agent
        ; test_case "a frame this cannot read says why" `Quick
            test_a_frame_this_cannot_read_says_why
        ] )
    ]
