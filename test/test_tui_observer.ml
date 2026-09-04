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

let agent_completed_frame =
  "data: {\"type\":\"agent_core:agent_completed\",\"event_type\":\"agent_completed\",\
   \"event_id\":\"evt-completed\",\"ts_unix\":1787505650.0,\
   \"correlation_id\":\"trace-1\",\"run_id\":\"run-1\",\
   \"agent_name\":\"analyst\",\"task_id\":\"task-1\",\
   \"payload\":{\"agent_name\":\"analyst\",\"task_id\":\"task-1\",\
   \"elapsed_s\":1.25,\"success\":true,\"result\":\"ok\"}}\n\n"

let agent_failed_frame =
  "data: {\"type\":\"agent_core:agent_failed\",\"event_type\":\"agent_failed\",\
   \"event_id\":\"evt-failed\",\"ts_unix\":1787505651.0,\
   \"correlation_id\":\"trace-2\",\"run_id\":\"run-2\",\
   \"agent_name\":\"analyst\",\"task_id\":\"task-2\",\
   \"payload\":{\"agent_name\":\"analyst\",\"task_id\":\"task-2\",\
   \"elapsed_s\":0.5,\"error\":\"boom\"}}\n\n"

let heartbeat_frame =
  "data: {\"type\":\"keeper_heartbeat\",\"name\":\"bandleader\",\
   \"ts_unix\":1787505649.446111,\"phase\":\"turn_running\",\"in_turn\":true,\
   \"in_flight_elapsed_ms\":2189925.43,\"since_last_progress_ms\":13093.6}\n\n"

let turn_complete_frame =
  "data: {\"type\":\"keeper_turn_complete\",\"name\":\"largo\",\"turn\":2086,\
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
  | Observer.Event (Observer.Keeper_chat_stream_frame { keeper; frame; _ }) ->
      Printf.sprintf "stream(%s,%s)" keeper (Option.value ~default:"-" frame)
  | Observer.Event (Observer.Keeper_waiting_inventory_changed { keeper; queue_kind; _ })
    ->
      Printf.sprintf "waiting(%s,%s)" keeper (Option.value ~default:"-" queue_kind)
  | Observer.Event (Observer.Fusion_run_status { keeper; run_id; status }) ->
      Printf.sprintf "fusion(%s,%s,%s)" keeper status run_id
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

let test_agent_terminal_frames_keep_their_distinct_kinds () =
  check (list string) "success decodes as one completion"
    [ "agent_core(analyst,agent_completed,-,turn=-,batch=-)" ]
    (List.map summary (decode_all [ agent_completed_frame ]));
  check (list string) "failure decodes as one failure"
    [ "agent_core(analyst,agent_failed,-,turn=-,batch=-)" ]
    (List.map summary (decode_all [ agent_failed_frame ]))

let bare_heartbeat_frame =
  "data: {\"type\":\"keeper_heartbeat\",\"name\":\"lane-smith\",\"ts_unix\":1787505653.07}\n\n"

let keeper_tool_call_frame =
  "data: {\"type\":\"keeper_tool_call\",\"name\":\"largo\",\"tool_name\":\"tool_execute\",\
   \"duration_ms\":14534,\"disposition\":\"completed\",\"ts_unix\":1787507566.14,\
   \"tool_args\":{\"argv\":[\"dune\",\"build\"]},\"tool_result\":{\"ok\":true}}\n\n"

let test_keeper_events_decode_by_name () =
  check (list string) "heartbeat, bare heartbeat, settlement, keeper tool call"
    [ "heartbeat(bandleader,turn_running,in_turn=true)"
    ; "heartbeat(lane-smith,-,in_turn=-)"
    ; "turn_complete(largo,turn=2086,cost=0.0258)"
    ; "keeper_tool_call(largo,tool_execute,14534ms,completed)"
    ]
    (List.map summary
       (decode_all
          [ heartbeat_frame; bare_heartbeat_frame; turn_complete_frame
          ; keeper_tool_call_frame ]))

(* Shapes taken from the server: keeper_chat_broadcast.ml names the keeper in
   "name", keeper_waiting_inventory_broadcast.ml in "keeper_name". *)
let chat_stream_delta_frame =
  "data: {\"type\":\"keeper_chat_operation_event\",\"name\":\"test-keeper\",\
   \"operation_id\":\"op-1\",\"ts_unix\":1787507570.5,\
   \"ag_ui_event\":{\"type\":\"TEXT_MESSAGE_CONTENT\",\"delta\":\"hi\"}}\n\n"

let chat_stream_custom_frame =
  "data: {\"type\":\"keeper_chat_operation_event\",\"name\":\"test-keeper\",\
   \"operation_id\":\"op-1\",\"ts_unix\":1787507571.5,\
   \"ag_ui_event\":{\"type\":\"CUSTOM\",\"name\":\"KEEPER_TOOL_RESULT_READY\"}}\n\n"

let waiting_inventory_frame =
  "data: {\"type\":\"keeper_waiting_inventory_changed\",\
   \"keeper_name\":\"lane-smith\",\"queue_kind\":\"board\",\
   \"ts_unix\":1787507572.5}\n\n"

(* These two arrived as Other before: the Acting screen drew them with no
   time, no keeper and no detail, because Other keeps only the type name. The
   keeper and the timestamp were in the frame the whole time. *)
let test_the_chat_stream_and_waiting_queue_keep_their_keeper_and_clock () =
  check (list string) "stream frames and a queue change decode by their own fields"
    [ "stream(test-keeper,TEXT_MESSAGE_CONTENT)"
    ; "stream(test-keeper,CUSTOM KEEPER_TOOL_RESULT_READY)"
    ; "waiting(lane-smith,board)"
    ]
    (List.map summary
       (decode_all
          [ chat_stream_delta_frame; chat_stream_custom_frame
          ; waiting_inventory_frame ]));
  check bool "the stream frame carries the server's clock, not zero" true
    (match decode_all [ chat_stream_delta_frame ] with
     | [ Observer.Event (Observer.Keeper_chat_stream_frame { at; _ }) ] ->
         Float.equal at 1787507570.5
     | _ -> false)

let operator_digest_frame =
  "data: {\"type\":\"operator_digest\",\"ts_unix\":1787507573.0}\n\n"

let transport_health_frame =
  "data: {\"type\":\"transport_health_snapshot\",\"ts_unix\":1787507574.0}\n\n"

let composite_frame =
  "data: {\"type\":\"keeper_composite_changed\",\"name\":\"lane-smith\",\
   \"ts_unix\":1787507575.0}\n\n"

(* Third time in this decoder. The chat stream frame and the waiting-queue
   change above arrived as Other until each was given an arm; the snapshot list
   was left as it was and had drifted by two. Both of these were on the Acting
   screen as untaught types, and an untaught type counts as an action -- so the
   filter that exists to show what a keeper did was showing server pushes.

   The list is gone. [Dashboard_event_slices] is the table the server routes
   by, and this decoder reads the same one. *)
let test_every_whole_projection_push_decodes_as_a_snapshot () =
  check (list string) "the two that were untaught read as snapshots"
    [ "snapshot:operator_digest"; "snapshot:transport_health_snapshot" ]
    (List.map summary
       (decode_all [ operator_digest_frame; transport_health_frame ]));
  (* Not one at a time: every type the table calls a whole projection. A new
     one added to the table is covered here without this test being touched. *)
  List.iter
    (fun (entry : Masc.Dashboard_event_slices.entry) ->
      if entry.whole_projection then
        let frame =
          Printf.sprintf "data: {\"type\":\"%s\",\"ts_unix\":1.0}\n\n"
            entry.event_type
        in
        check (list string)
          (Printf.sprintf "%s is a snapshot, not an untaught type"
             entry.event_type)
          [ "snapshot:" ^ entry.event_type ]
          (List.map summary (decode_all [ frame ])))
    Masc.Dashboard_event_slices.entries

(* A delta has a slice too, and reading the table for "does this have one"
   rather than "does it replace a projection" would swallow this one: the
   screen would drop a keeper change into the quiet class. It has its own arm
   above, and the table marks it as not a whole projection, so both halves
   have to break before it can go wrong. *)
let test_a_delta_with_a_slice_is_not_a_snapshot () =
  check (list string) "a composite change stays a keeper event"
    [ "composite(lane-smith)" ]
    (List.map summary (decode_all [ composite_frame ]));
  check bool "and the table does not call it a whole projection" false
    (Masc.Dashboard_event_slices.carries_whole_projection
       "keeper_composite_changed")

(* Server shape: keeper_chat_broadcast.ml writes the keeper in "name" and
   the connector when the turn came through one. *)
let chat_appended_frame =
  "data: {\"type\":\"keeper_chat_appended\",\"name\":\"lane-smith\",\
   \"connector\":\"api\",\"ts_unix\":1787507576.0}\n\n"

(* The chat pane reloads its history on exactly one event.  Quantified
   over every sample frame in this file: only the appended frame names
   a keeper, so a new variant cannot start reloading the pane by
   arriving, and the appended frame cannot silently stop. *)
(* The same run shape the HTTP list serves, and no ts_unix: the frame is a
   trigger, and only its identity strings are read here. *)
let fusion_run_status_frame =
  {|data: {"type":"fusion_run_status","run":{"run_id":"kmsg-f04701e2","keeper":"polisher","preset":"quorum","topology":"judge_of_judges","started_at":1788516104.9,"status":"running","stage":"panel"}}

|}

let fusion_run_status_without_run_frame =
  {|data: {"type":"fusion_run_status"}

|}

let test_only_a_chat_appended_event_names_a_reload_keeper () =
  check (list string) "the appended frame decodes with keeper and connector"
    [ "chat(lane-smith,api)" ]
    (List.map summary (decode_all [ chat_appended_frame ]));
  let reload_keepers frames =
    decode_all frames
    |> List.filter_map (function
         | Observer.Event event -> Observer.chat_appended_keeper event
         | Observer.Undecodable _ -> None)
  in
  check (list string) "every other sample event answers no keeper" []
    (reload_keepers
       [ tool_called_frame; agent_completed_frame; agent_failed_frame
       ; heartbeat_frame; turn_complete_frame; keeper_tool_call_frame
       ; composite_frame; chat_stream_delta_frame; chat_stream_custom_frame
       ; waiting_inventory_frame; operator_digest_frame
       ; transport_health_frame; fusion_run_status_frame
       ]);
  check (list string) "the appended frame answers its keeper" [ "lane-smith" ]
    (reload_keepers [ chat_appended_frame ])

let test_a_fusion_status_frame_decodes_its_identity_strings () =
  check (list string) "the three identity strings survive the decode"
    [ "fusion(polisher,running,kmsg-f04701e2)" ]
    (List.map summary (decode_all [ fusion_run_status_frame ]));
  check bool "a frame with no run object says why it was not read" true
    (match decode_all [ fusion_run_status_without_run_frame ] with
     | [ Observer.Undecodable reason ] ->
         String.starts_with ~prefix:"fusion_run_status" reason
     | _ -> false)

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
        ; test_case "agent terminal frames keep their distinct kinds" `Quick
            test_agent_terminal_frames_keep_their_distinct_kinds
        ; test_case "keeper events decode by name" `Quick
            test_keeper_events_decode_by_name
        ; test_case "the chat stream and waiting queue keep their keeper and clock"
            `Quick test_the_chat_stream_and_waiting_queue_keep_their_keeper_and_clock
        ; test_case "every whole-projection push decodes as a snapshot" `Quick
            test_every_whole_projection_push_decodes_as_a_snapshot
        ; test_case "a delta with a slice is not a snapshot" `Quick
            test_a_delta_with_a_slice_is_not_a_snapshot
        ; test_case "only a chat-appended event names a reload keeper" `Quick
            test_only_a_chat_appended_event_names_a_reload_keeper
        ; test_case "a fusion status frame decodes its identity strings" `Quick
            test_a_fusion_status_frame_decodes_its_identity_strings
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
