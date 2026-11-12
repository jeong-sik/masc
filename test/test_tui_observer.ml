open Alcotest
open Masc

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
   \"agent_name\":\"analyst\",\"task_id\":\"evt-f50d1cc0\",\
   \"payload\":{\"agent_name\":\"analyst\",\"task_id\":\"evt-f50d1cc0\",\
   \"elapsed_s\":1.25,\"success\":true,\"result\":\"ok\"}}\n\n"

(* The payload the bridge writes for a failed run, from the contract's own
   builder, so the fixture cannot drift from the shape on the wire. *)
let agent_failed_frame =
  let payload =
    Sse_event.agent_failed_payload ~agent_name:"analyst" ~task_id:"evt-9565f12c"
      ~elapsed_s:0.5 ~error:"rate limited" ~error_domain:"provider"
      ~error_code:"provider_error" ~error_retryable:true ~error_detail:`Null
  in
  "data: "
  ^ Yojson.Safe.to_string
      (`Assoc
        [ ("type", `String "agent_core:agent_failed")
        ; ("event_type", `String "agent_failed")
        ; ("event_id", `String "evt-failed")
        ; ("ts_unix", `Float 1787505651.0)
        ; ("correlation_id", `String "trace-2")
        ; ("run_id", `String "run-2")
        ; ("agent_name", `String "analyst")
        ; ("task_id", `String "evt-9565f12c")
        ; ("payload", payload)
        ])
  ^ "\n\n"

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
  |> List.map (fun (delivery : Observer.delivery) -> delivery.decoded)

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
         | Observer.Agent_completed _ -> "agent_completed"
         | Observer.Agent_failed _ -> "agent_failed"
         | Observer.Agent_yielded _ -> "agent_yielded"
         | Observer.Agent_input_required _ -> "agent_input_required"
         | Observer.Tool_approval_completed -> "tool_approval_completed"
         | Observer.Telemetry -> "telemetry"
         | Observer.Relay_subscription_loss { dropped_count; _ } ->
             Printf.sprintf "relay-loss:%d" dropped_count
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
      Printf.sprintf "keeper_tool_call(%s,turn=%s,%s,%s,%s)" c.Observer.kt_keeper
        (match c.Observer.kt_turn with Some n -> string_of_int n | None -> "-")
        c.Observer.kt_tool
        (match c.Observer.kt_duration_ms with
         | Some ms -> Printf.sprintf "%.0fms" ms
         | None -> "-")
        (match c.Observer.kt_disposition with
         | Some (Ok disposition) ->
             Masc.Tui_decode.keeper_call_disposition_to_string disposition
         | Some (Error error) -> "error:" ^ error
         | None -> "-")
  | Observer.Event (Observer.Keeper_turn_complete t) ->
      Printf.sprintf "turn_complete(%s,turn=%s,cost=%s)" t.Observer.tc_keeper
        (match t.Observer.tc_turn with Some n -> string_of_int n | None -> "-")
        (match t.Observer.tc_cost_usd with
         | Some c -> Printf.sprintf "%.4f" c
         | None -> "-")
  | Observer.Event (Observer.Keeper_turn_observation o) ->
      Printf.sprintf "observation(%s,call=%s,completed=%s)" o.Observer.to_keeper
        (match o.Observer.to_session_turn with Some n -> string_of_int n | None -> "-")
        (match o.Observer.to_total_turns with Some n -> string_of_int n | None -> "-")
  | Observer.Event (Observer.Keeper_composite_changed { keeper; _ }) ->
      "composite(" ^ keeper ^ ")"
  | Observer.Event (Observer.Keeper_metrics_appended { keeper; _ }) ->
      "metrics(" ^ keeper ^ ")"
  | Observer.Event (Observer.Keeper_chat_appended { keeper; connector; _ }) ->
      Printf.sprintf "chat(%s,%s)" keeper (Option.value ~default:"-" connector)
  | Observer.Event (Observer.Keeper_memory_journal_appended { keeper; _ }) ->
      "memory(" ^ keeper ^ ")"
  | Observer.Event (Observer.Keeper_runtime_journal_appended { keeper; journal; _ }) ->
      Printf.sprintf "runtime_journal(%s,%s)" keeper
        (match journal with
         | Observer.Native_tasks_journal -> "native_tasks"
         | Observer.Child_content_journal -> "child_content")
  | Observer.Event (Observer.Keeper_chat_stream_frame { keeper; frame; _ }) ->
      Printf.sprintf "stream(%s,%s)" keeper (Option.value ~default:"-" frame)
  | Observer.Event (Observer.Keeper_turn_stream_frame { keeper; turn_ref; _ }) ->
      "turn_stream(" ^ keeper ^ "," ^ Ids.Turn_ref.to_string turn_ref ^ ")"
  | Observer.Event (Observer.Keeper_waiting_inventory_changed { keeper; queue_kind; _ })
    ->
      Printf.sprintf "waiting(%s,%s)" keeper (Option.value ~default:"-" queue_kind)
  | Observer.Event (Observer.Fusion_run_status { keeper; run_id; status }) ->
      Printf.sprintf "fusion(%s,%s,%s)" keeper status run_id
  | Observer.Event (Observer.Internal_agent_runs_changed registry) ->
      "internal_runs(" ^ Masc.Internal_agent_runs_event.registry_to_wire registry ^ ")"
  | Observer.Event (Observer.Workspace_store_changed Observer.Schedule_store) -> "schedule_store_invalidated"
  | Observer.Event (Observer.Workspace_store_changed Observer.Pending_confirms) -> "pending_confirm_invalidated"
  | Observer.Event (Observer.Dataset_changed dataset) ->
      "dataset(" ^ Masc.Workspace_dataset_event.dataset_to_wire dataset
      ^ (match dataset with
         | Masc.Workspace_dataset_event.Keeper_metrics { keeper }
         | Masc.Workspace_dataset_event.Keeper_oauth_attempts { keeper }
         | Masc.Workspace_dataset_event.Skill_activations { keeper }
         | Masc.Workspace_dataset_event.Memory_health { keeper } -> ":" ^ keeper
         | Masc.Workspace_dataset_event.Machine_live { machine }
         | Masc.Workspace_dataset_event.Play_room { machine } ->
             ":" ^ Masc.Machine_lane.to_wire machine
         | Masc.Workspace_dataset_event.Browser_observation _ -> ""
         | Masc.Workspace_dataset_event.Dashboard_observation _
         | Masc.Workspace_dataset_event.World_memory
         | Masc.Workspace_dataset_event.Play_seats
         | Masc.Workspace_dataset_event.Repositories
         | Masc.Workspace_dataset_event.Verification_requests
         | Masc.Workspace_dataset_event.Harness_verdicts
         | Masc.Workspace_dataset_event.Goals
         | Masc.Workspace_dataset_event.Runtime_config
         | Masc.Workspace_dataset_event.Connectors
         | Masc.Workspace_dataset_event.Skill_catalog
         | Masc.Workspace_dataset_event.Clients
         | Masc.Workspace_dataset_event.Account_emails
         | Masc.Workspace_dataset_event.Provider_usage
         | Masc.Workspace_dataset_event.Provider_standing
         | Masc.Workspace_dataset_event.Keeper_costs
         | Masc.Workspace_dataset_event.Workspace_health
         | Masc.Workspace_dataset_event.Runtime_probe
         | Masc.Workspace_dataset_event.Runtime_metrics
         | Masc.Workspace_dataset_event.Lanes
         | Masc.Workspace_dataset_event.Lane_addons _ -> "")
      ^ ")"
  | Observer.Event (Observer.Workspace_store_changed Observer.Goal_projection) -> "goal_projection"
  | Observer.Event (Observer.Workspace_store_changed Observer.Runtime_config) -> "runtime_config"
  | Observer.Event (Observer.Workspace_store_changed Observer.Skill_catalog) -> "skill_catalog_published"
  | Observer.Event (Observer.Workspace_store_changed Observer.Lane_addon_exports) -> "lane_addon_exports_changed"
  | Observer.Event (Observer.Gate_connector_changed { connector }) -> "connector(" ^ connector ^ ")"
  | Observer.Event (Observer.Keeper_event_queue_changed { keeper }) ->
      "event_queue(" ^ keeper ^ ")"
  | Observer.Event (Observer.Approval_change change) ->
      Printf.sprintf "approval(%s)"
        (match change with
         | Observer.Approval_queue_changed -> "queue"
         | Observer.Approval_rules_changed -> "rules"
         | Observer.Gate_mode_changed -> "gate_mode"
         | Observer.Gate_keeper_settings_changed { keeper } -> "keeper_settings:" ^ keeper
         | Observer.Tool_approval_waits_changed { keeper } -> "waits:" ^ keeper
         | Observer.Tool_approval_mode_changed { keeper } -> "mode:" ^ keeper
         | Observer.Keeper_asks_changed { keeper } -> "asks:" ^ keeper
         | Observer.Installation_asks_changed { declaration_id } ->
             "installation_asks:" ^ declaration_id)
  | Observer.Event (Observer.Keeper_async_requests_changed { keeper }) ->
      "async_requests:" ^ keeper
  | Observer.Event (Observer.Keeper_skill_activations_changed { keeper }) ->
      "skill_activations:" ^ keeper
  | Observer.Event (Observer.Keeper_roster_change (Observer.Keeper_row_changed { keeper })) ->
      "roster_row:" ^ keeper
  | Observer.Event (Observer.Keeper_roster_change Observer.Every_row_changed) -> "roster_all"
  | Observer.Event (Observer.Keeper_turn_changed { keeper; change = Observer.Turn_state }) ->
      "turns:" ^ keeper
  | Observer.Event (Observer.Keeper_turn_changed { keeper; change = Observer.Turn_preview }) ->
      "preview:" ^ keeper
  | Observer.Event (Observer.Board_changed { post_id }) ->
      Printf.sprintf "board(%s)" (Option.value ~default:"-" post_id)
  | Observer.Event (Observer.Lane_resource { lr_package; lr_instance; lr_detail; _ })
    ->
      Printf.sprintf "lane_resource(%s,%s,%s)" lr_package lr_instance
        (Option.value ~default:"-" lr_detail)
  | Observer.Event (Observer.Snapshot projection) ->
      "snapshot:" ^ Observer.projection_name projection
  | Observer.Event Observer.Execution_snapshot ->
      "snapshot:" ^ Masc.Dashboard_event_slices.execution_snapshot_type
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

(* Field-for-field the shape the server sends, from an observer capture on
   2026-09-07: every one of 19 [keeper_tool_call] frames carried "turn".
   The fixture carried none until then, so nothing here could notice that
   the decoder dropped it. *)
let keeper_tool_call_frame =
  "data: {\"type\":\"keeper_tool_call\",\"name\":\"largo\",\"tool_name\":\"tool_execute\",\
   \"duration_ms\":14534,\"disposition\":\"completed\",\"ts_unix\":1787507566.14,\
   \"turn\":1157,\
   \"tool_args\":{\"argv\":[\"dune\",\"build\"]},\"tool_result\":{\"ok\":true}}\n\n"

(* A server that reports a call outside any invocation sends no turn. *)
let keeper_tool_call_frame_without_turn =
  "data: {\"type\":\"keeper_tool_call\",\"name\":\"largo\",\"tool_name\":\"Read\",\
   \"duration_ms\":8,\"disposition\":\"completed\",\"ts_unix\":1787507570.02}\n\n"

(* Shape from keeper_hooks_agent_core.ml: the hook's per-call report names
   the keeper, the agent session's ordinal for the call and the keeper turns
   completed before it. *)
let turn_observation_frame =
  "data: {\"type\":\"keeper_turn_observation\",\"usage_projection\":\"raw_observation\",\
   \"response_id\":null,\"name\":\"largo\",\"turn\":1157,\"model_used\":null,\
   \"input_tokens\":73877,\"output_tokens\":358,\"cost_usd\":0.0258,\
   \"tool_calls_made\":2,\"cache_read_tokens\":null,\"cache_n\":null,\
   \"prompt_n\":null,\"total_turns\":718,\"ts_unix\":1787505649.0}\n\n"

let test_a_turn_observation_names_the_call_and_the_completed_count () =
  check (list string) "the keeper, the session ordinal and the completed count"
    [ "observation(largo,call=1157,completed=718)" ]
    (List.map summary (decode_all [ turn_observation_frame ]))

(* The settle carries the cache counts beside the input they are part of.
   Figures are e-masc-the-leader's turn 1853 (2026-09-25). A frame without
   them, or with nulls, reads as not reported -- never as zero -- and a count
   of the wrong shape is a frame this build cannot read. *)
let cached_turn_complete_frame cache_fields =
  "data: {\"type\":\"keeper_turn_complete\",\"name\":\"e-masc-the-leader\",\
   \"turn\":1853,\"input_tokens\":3716155,\"output_tokens\":6622," ^ cache_fields
  ^ "\"ts_unix\":1790000000.0}\n\n"

let settle_cache_counts frame =
  match decode_all [ frame ] with
  | [ Observer.Event (Observer.Keeper_turn_complete t) ] ->
    Ok (t.Observer.tc_cache_read_tokens, t.Observer.tc_cache_creation_tokens)
  | [ Observer.Undecodable reason ] -> Error reason
  | events -> failf "expected one event, got %d" (List.length events)

let test_a_settle_keeps_its_cache_counts_apart_from_absent () =
  let counts = result (pair (option int) (option int)) string in
  check counts "both counts reported"
    (Ok (Some 3_556_362, Some 159_783))
    (settle_cache_counts
       (cached_turn_complete_frame
          "\"cache_read_tokens\":3556362,\"cache_creation_tokens\":159783,"));
  check counts "absent is not reported" (Ok (None, None))
    (settle_cache_counts (cached_turn_complete_frame ""));
  check counts "null is not reported" (Ok (None, None))
    (settle_cache_counts
       (cached_turn_complete_frame
          "\"cache_read_tokens\":null,\"cache_creation_tokens\":null,"));
  check counts "a count of the wrong shape is unreadable"
    (Error "keeper_turn_complete carries a non-integer cache_read_tokens")
    (settle_cache_counts
       (cached_turn_complete_frame "\"cache_read_tokens\":\"3556362\","))

let test_keeper_events_decode_by_name () =
  check (list string)
    "heartbeat, bare heartbeat, settlement, keeper tool call with and without \
     a turn"
    [ "heartbeat(bandleader,turn_running,in_turn=true)"
    ; "heartbeat(lane-smith,-,in_turn=-)"
    ; "turn_complete(largo,turn=2086,cost=0.0258)"
    ; "keeper_tool_call(largo,turn=1157,tool_execute,14534ms,completed)"
    ; "keeper_tool_call(largo,turn=-,Read,8ms,completed)"
    ]
    (List.map summary
       (decode_all
          [ heartbeat_frame; bare_heartbeat_frame; turn_complete_frame
          ; keeper_tool_call_frame; keeper_tool_call_frame_without_turn ]))

(* Shapes taken from the server: keeper_chat_broadcast.ml names the keeper in
   "name", keeper_waiting_inventory_broadcast.ml in "keeper_name". *)
let chat_stream_delta_frame =
  "data: {\"type\":\"keeper_chat_operation_event\",\"name\":\"test-keeper\",\
   \"operation_id\":\"op-1\",\"ts_unix\":1787507570.5,\"seq\":41,\
   \"ag_ui_event\":{\"type\":\"TEXT_MESSAGE_CONTENT\",\"delta\":\"hi\"}}\n\n"

let chat_stream_custom_frame =
  "data: {\"type\":\"keeper_chat_operation_event\",\"name\":\"test-keeper\",\
   \"operation_id\":\"op-1\",\"ts_unix\":1787507571.5,\
   \"ag_ui_event\":{\"type\":\"CUSTOM\",\"name\":\"KEEPER_TOOL_RESULT_READY\"}}\n\n"

(* A seq of the wrong shape is a frame this build cannot read, not the
   seq-less settle terminal. *)
let chat_stream_malformed_seq_frame =
  "data: {\"type\":\"keeper_chat_operation_event\",\"name\":\"test-keeper\",\
   \"operation_id\":\"op-1\",\"ts_unix\":1787507572.0,\"seq\":\"41\",\
   \"ag_ui_event\":{\"type\":\"TEXT_MESSAGE_CONTENT\",\"delta\":\"hi\"}}\n\n"

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
     | _ -> false);
  (* The operation and its journal seq are what the chat pane follows a
     foreign turn by; the settle-time terminal carries no seq and decodes to
     [None] rather than failing the frame. *)
  check (list string) "the frame names its operation and journal seq"
    [ "op-1@41"; "op-1@-" ]
    (List.map
       (function
         | Observer.Event (Observer.Keeper_chat_stream_frame { operation_id; seq; _ }) ->
             operation_id ^ "@"
             ^ (match seq with Some seq -> string_of_int seq | None -> "-")
         | _ -> "?")
       (decode_all [ chat_stream_delta_frame; chat_stream_custom_frame ]));
  check (list string) "a seq of the wrong shape fails the frame, not reads as absent"
    [ "undecodable:keeper_chat_operation_event carries a non-integer seq" ]
    (List.map summary (decode_all [ chat_stream_malformed_seq_frame ]))

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
  check (list bool) "only the transport measurement owes the transport a read"
    [ false; true ]
    (List.map
       (function
         | Observer.Event event -> Observer.transport_health_measured event
         | Observer.Undecodable _ -> false)
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

(* A whole-projection push can run to megabytes after its type, and the feed
   keeps only the name, so the frame is not read past the type: a body that
   is not JSON still arrives as the snapshot it names. An event read from its
   fields is still parsed whole and refused when it is not JSON, and a type
   that is not the first member is found by the whole parse, even when the
   first member is another string. *)
let test_a_frame_its_type_decides_is_not_read_past_the_type () =
  check (list string) "the snapshot is named without its body"
    [ "snapshot:operator_snapshot" ]
    (List.map summary
       (decode_all [ "data: {\"type\":\"operator_snapshot\",\"payload\":not json\n\n" ]));
  check (list string) "an untaught type is named the same way"
    [ "other:some_new_push" ]
    (List.map summary (decode_all [ "data: {\"type\":\"some_new_push\",oops\n\n" ]));
  (match decode_all [ "data: {\"type\":\"keeper_heartbeat\",\"name\":oops}\n\n" ] with
   | [ Observer.Undecodable _ ] -> ()
   | decoded ->
       fail
         ("an event read from its fields was not parsed whole: "
         ^ String.concat ", " (List.map summary decoded)));
  check (list string) "a type that is not the first member is still found"
    [ "snapshot:operator_snapshot" ]
    (List.map summary
       (decode_all [ "data: {\"ts_unix\":1.0,\"type\":\"operator_snapshot\"}\n\n" ]));
  check (list string) "a first member that is another string is not the type"
    [ "heartbeat(alpha,-,in_turn=-)" ]
    (List.map summary
       (decode_all
          [ "data: {\"name\":\"alpha\",\"type\":\"keeper_heartbeat\",\"ts_unix\":1.0}\n\n" ]))

(* The Goal sources' announcement: the Planning screen reads its Goals on it. *)
let test_a_goal_projection_change_is_named () =
  check (list string) "the push reads as a Goal projection change"
    [ "goal_projection" ]
    (List.map summary
       (decode_all
          [ Printf.sprintf "data: {\"type\":\"%s\",\"ts_unix\":1.0}\n\n"
              Masc.Goal_projection_broadcast.changed_event ]));
  check bool "and only it is a Goal projection change" true
    (Observer.goal_projection_changed (Observer.Workspace_store_changed Observer.Goal_projection)
     && not (Observer.goal_projection_changed (Observer.Workspace_store_changed Observer.Schedule_store)))

(* The server's runtime.toml commit announcement: the Config screen reads the
   file on it (RFC-0482 L4). *)
let test_a_runtime_config_change_is_named () =
  check (list string) "the push reads as a runtime.toml change"
    [ "runtime_config" ]
    (List.map summary
       (decode_all
          [ Printf.sprintf "data: {\"type\":\"%s\",\"ts_unix\":1.0}\n\n"
              Masc.Runtime_config_changed_event.event_type ]));
  check bool "and only it is a runtime.toml change" true
    (Observer.runtime_config_changed (Observer.Workspace_store_changed Observer.Runtime_config)
     && not (Observer.runtime_config_changed (Observer.Workspace_store_changed Observer.Goal_projection)))

(* The metrics file's own announcement, not the heartbeat: the in-turn pulse
   sends [keeper_heartbeat] without writing a row. *)
let test_a_metrics_append_names_its_keeper () =
  check (list string) "the append reads as the Keeper's metrics change"
    [ "metrics(lane-smith)" ]
    (List.map summary
       (decode_all
          [ "data: {\"type\":\"keeper_metrics_appended\",\"name\":\"lane-smith\",\"ts_unix\":1.0}\n\n" ]));
  check (option string) "and the logs view reads that Keeper" (Some "lane-smith")
    (match decode_all
             [ "data: {\"type\":\"keeper_metrics_appended\",\"name\":\"lane-smith\",\"ts_unix\":1.0}\n\n" ]
     with
     | [ Observer.Event event ] -> Observer.metrics_appended_keeper event
     | _ -> None);
  check (option string) "a heartbeat is not a metrics append" None
    (match decode_all
             [ "data: {\"type\":\"keeper_heartbeat\",\"name\":\"lane-smith\",\"ts_unix\":1.0}\n\n" ]
     with
     | [ Observer.Event event ] -> Observer.metrics_appended_keeper event
     | _ -> None)

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

(* Server shape: keeper_memory_journal_broadcast.ml writes the keeper in
   "name". *)
let memory_journal_frame =
  "data: {\"type\":\"keeper_memory_journal_appended\",\"name\":\"lane-smith\",\
   \"ts_unix\":1787507576.0}\n\n"

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
       (* A turn observation numbers a provider call inside a keeper turn and
          carries no transcript. It was absent from this list when the frame
          was added, and the reader silently stopped being exhaustive. Every
          frame this suite can build belongs here, so the next one cannot
          skip the question. *)
       ; turn_observation_frame; memory_journal_frame
       ]);
  check (list string) "the appended frame answers its keeper" [ "lane-smith" ]
    (reload_keepers [ chat_appended_frame ])

(* Server shape: keeper_runtime_journal_broadcast.ml writes the keeper in
   "name". *)
let native_tasks_frame =
  "data: {\"type\":\"keeper_native_tasks_appended\",\"name\":\"lane-smith\",\
   \"ts_unix\":1787507576.0}\n\n"

let child_content_frame =
  "data: {\"type\":\"keeper_child_content_appended\",\"name\":\"lane-smith\",\
   \"ts_unix\":1787507576.0}\n\n"

let test_only_a_runtime_journal_event_names_a_runtime_journal () =
  check (list string) "the journal frames decode with their keeper and journal"
    [ "runtime_journal(lane-smith,native_tasks)"; "runtime_journal(lane-smith,child_content)" ]
    (List.map summary (decode_all [ native_tasks_frame; child_content_frame ]));
  let journals frames =
    decode_all frames
    |> List.filter_map (function
         | Observer.Event event -> Observer.runtime_journal_appended event
         | Observer.Undecodable _ -> None)
  in
  check int "both name a journal" 2 (List.length (journals [ native_tasks_frame; child_content_frame ]));
  check int "a memory journal or chat frame names none" 0
    (List.length (journals [ memory_journal_frame; chat_appended_frame ]));
  check (list string) "neither reloads the chat history or the memory journal" []
    (decode_all [ native_tasks_frame; child_content_frame ]
     |> List.filter_map (function
          | Observer.Event event ->
            (match Observer.chat_appended_keeper event, Observer.memory_journal_appended_keeper event with
             | None, None -> None
             | Some keeper, _ | _, Some keeper -> Some keeper)
          | Observer.Undecodable _ -> None))

let test_only_a_memory_journal_event_names_a_journal_keeper () =
  check (list string) "the journal frame decodes with its keeper"
    [ "memory(lane-smith)" ]
    (List.map summary (decode_all [ memory_journal_frame ]));
  let journal_keepers frames =
    decode_all frames
    |> List.filter_map (function
         | Observer.Event event -> Observer.memory_journal_appended_keeper event
         | Observer.Undecodable _ -> None)
  in
  check (list string) "every other sample event answers no keeper" []
    (journal_keepers
       [ tool_called_frame; agent_completed_frame; agent_failed_frame
       ; heartbeat_frame; turn_complete_frame; keeper_tool_call_frame
       ; composite_frame; chat_stream_delta_frame; chat_stream_custom_frame
       ; waiting_inventory_frame; operator_digest_frame
       ; transport_health_frame; fusion_run_status_frame
       ; turn_observation_frame; chat_appended_frame
       ]);
  check (list string) "the journal frame answers its keeper" [ "lane-smith" ]
    (journal_keepers [ memory_journal_frame ])

(* The server sends Board writes as JSON-RPC notifications, with a method
   where the other events have a type. *)
let board_post_changed_frame =
  {|data: {"jsonrpc":"2.0","method":"notifications/board","params":{"type":"post_changed","event_type":"post.changed","post_id":"post-7","change":"pinned"}}

|}

let board_comment_voted_frame =
  {|data: {"jsonrpc":"2.0","method":"notifications/board","params":{"type":"comment_voted","comment_id":"comment-3","voter":"ann","direction":"up"}}

|}

let board_without_params_frame =
  {|data: {"jsonrpc":"2.0","method":"notifications/board"}

|}

let other_notification_frame =
  {|data: {"jsonrpc":"2.0","method":"notifications/progress","params":{"post_id":"post-7"}}

|}

let test_only_a_board_notification_names_a_board_change () =
  check (list string) "the post it names is read; a comment vote names none"
    [ "board(post-7)"; "board(-)" ]
    (List.map summary (decode_all [ board_post_changed_frame; board_comment_voted_frame ]));
  let board_changes frames =
    decode_all frames
    |> List.filter_map (function
         | Observer.Event event -> Observer.board_changed_post event
         | Observer.Undecodable _ -> None)
  in
  check (list (option string)) "every other sample event answers no board change" []
    (board_changes
       [ tool_called_frame; agent_completed_frame; agent_failed_frame
       ; heartbeat_frame; turn_complete_frame; keeper_tool_call_frame
       ; composite_frame; chat_stream_delta_frame; chat_stream_custom_frame
       ; waiting_inventory_frame; operator_digest_frame
       ; transport_health_frame; fusion_run_status_frame
       ; turn_observation_frame; chat_appended_frame; memory_journal_frame
       ; other_notification_frame
       ]);
  check bool "a board notification without params says why it was not read" true
    (match decode_all [ board_without_params_frame ] with
     | [ Observer.Undecodable reason ] ->
         String.starts_with ~prefix:"notifications/board" reason
     | _ -> false)

let gate_frames =
  [ {|data: {"type":"approval:pending","payload":{"id":"approval-1"}}

|}
  ; {|data: {"type":"approval:resolved","payload":{"id":"approval-1"}}

|}
  ; {|data: {"type":"approval:summary_updated","payload":{"id":"approval-1"}}

|}
  ; {|data: {"type":"approval_rules_changed"}

|}
  ; {|data: {"type":"gate_mode_changed","mode":"hitl"}

|}
  ; {|data: {"type":"gate_external_mode_changed","mode":"hitl"}

|}
  ; {|data: {"type":"gate_keeper_mode_changed","keeper_name":"lane-smith","mode":null}

|}
  ; {|data: {"type":"keeper_exact_lane_preference_changed","keeper_name":"lane-smith","lane_id":"l","slot_id":null}

|}
  ]

let tool_approval_frames =
  [ {|data: {"type":"keeper_tool_approval_waits_changed","name":"lane-smith"}

|}
  ; {|data: {"type":"keeper_tool_approval_mode_changed","name":"lane-smith"}

|}
  ]

let asks_frames =
  [ {|data: {"type":"keeper_asks_changed","name":"lane-smith"}

|}
  ; {|data: {"type":"lane_addon_asks_changed","declaration_id":"quiz"}

|}
  ]

let async_requests_frame =
  {|data: {"type":"keeper_async_requests_changed","name":"lane-smith"}

|}

let pending_confirms_frame =
  {|data: {"type":"operator_pending_confirm_invalidated"}

|}

let test_only_a_confirmation_change_reads_the_confirmations () =
  check (list string) "a confirmation change decodes as one"
    [ "pending_confirm_invalidated" ]
    (List.map summary (decode_all [ pending_confirms_frame ]));
  let count reads frames =
    decode_all frames
    |> List.filter (function
         | Observer.Event event -> reads event
         | Observer.Undecodable _ -> false)
    |> List.length
  in
  check int "it reads the confirmations" 1
    (count Observer.pending_confirms_changed [ pending_confirms_frame ]);
  check int "no question, Gate, held call or mode change does" 0
    (count Observer.pending_confirms_changed (asks_frames @ gate_frames @ tool_approval_frames));
  check int "it reads no Gate, held calls, modes or questions" 0
    (count
       (fun event ->
          Observer.gate_snapshot_changed event || Observer.held_calls_changed event
          || Observer.tool_modes_changed event || Observer.asks_changed event)
       [ pending_confirms_frame ])

let schedules_frame =
  {|data: {"type":"schedule_store_invalidated"}

|}

let test_only_a_schedule_change_reads_the_schedules () =
  check (list string) "a schedule change decodes as one" [ "schedule_store_invalidated" ]
    (List.map summary (decode_all [ schedules_frame ]));
  let count reads frames =
    decode_all frames
    |> List.filter (function
         | Observer.Event event -> reads event
         | Observer.Undecodable _ -> false)
    |> List.length
  in
  check int "it reads the schedules" 1 (count Observer.schedules_changed [ schedules_frame ]);
  check int "no confirmation, question, Gate, held call, mode or async request change does" 0
    (count Observer.schedules_changed
       ([ pending_confirms_frame; async_requests_frame ]
        @ asks_frames @ gate_frames @ tool_approval_frames));
  check int "it reads nothing else" 0
    (count
       (fun event ->
          Observer.gate_snapshot_changed event || Observer.held_calls_changed event
          || Observer.tool_modes_changed event || Observer.asks_changed event
          || Observer.pending_confirms_changed event || Observer.async_requests_changed event)
       [ schedules_frame ])

(* A Keeper's skill activation ledger change names that Keeper, and a
   published skill catalog is a store change of its own (RFC-0483 §4.3). *)
let test_skill_pushes_name_their_reads () =
  let activations_frame =
    {|data: {"type":"keeper_skill_activations_changed","name":"lane-smith","trace_id":"trace-1","ts_unix":1.0}

|}
  in
  let catalog_frame = {|data: {"type":"skill_catalog_published","ts_unix":1.0}

|} in
  check (list string) "both decode" [ "skill_activations:lane-smith"; "skill_catalog_published" ]
    (List.map summary (decode_all [ activations_frame; catalog_frame ]));
  let events frames =
    List.filter_map
      (function Observer.Event event -> Some event | Observer.Undecodable _ -> None)
      (decode_all frames)
  in
  check (list (option string)) "the ledger change names its Keeper"
    [ Some "lane-smith"; None ]
    (List.map Observer.skill_activations_keeper (events [ activations_frame; catalog_frame ]));
  check (list bool) "only the catalog push is a published catalog" [ false; true ]
    (List.map Observer.skill_catalog_published (events [ activations_frame; catalog_frame ]));
  let exports_frame = {|data: {"type":"lane_addon_exports_changed","ts_unix":1.0}

|} in
  check (list string) "the Lane Add-on exports push decodes" [ "lane_addon_exports_changed" ]
    (List.map summary (decode_all [ exports_frame ]));
  check (list bool) "only the exports push is an exports change" [ false; false; true ]
    (List.map Observer.lane_addon_exports_changed
       (events [ activations_frame; catalog_frame; exports_frame ]));
  check bool "a ledger change is not an async request change" false
    (List.exists Observer.async_requests_changed (events [ activations_frame ]));
  check bool "a ledger change without its Keeper says why it was not read" true
    (match decode_all [ {|data: {"type":"keeper_skill_activations_changed","ts_unix":1.0}

|} ] with
     | [ Observer.Undecodable _ ] -> true
     | [] | Observer.Event _ :: _ | Observer.Undecodable _ :: _ :: _ -> false)

let test_only_an_async_request_change_reads_the_async_requests () =
  check (list string) "an async request change decodes with its Keeper"
    [ "async_requests:lane-smith" ]
    (List.map summary (decode_all [ async_requests_frame ]));
  let count reads frames =
    decode_all frames
    |> List.filter (function
         | Observer.Event event -> reads event
         | Observer.Undecodable _ -> false)
    |> List.length
  in
  check int "it reads the async requests" 1
    (count Observer.async_requests_changed [ async_requests_frame ]);
  check int "no question, Gate, held call or mode change does" 0
    (count Observer.async_requests_changed (asks_frames @ gate_frames @ tool_approval_frames));
  let keepers frames =
    List.filter_map
      (function
        | Observer.Event event -> Some (Observer.async_requests_keeper event)
        | Observer.Undecodable _ -> None)
      (decode_all frames)
  in
  check (list (option string)) "it names the Keeper whose open detail reads again"
    [ Some "lane-smith" ] (keepers [ async_requests_frame ]);
  check bool "no question, Gate, held call or mode change names one" true
    (List.for_all Option.is_none (keepers (asks_frames @ gate_frames @ tool_approval_frames)));
  check bool "a change without its Keeper says why it was not read" true
    (match decode_all [ {|data: {"type":"keeper_async_requests_changed"}

|} ] with
     | [ Observer.Undecodable reason ] ->
         String.starts_with ~prefix:"keeper_async_requests_changed" reason
     | _ -> false)

let roster_frames =
  [ {|data: {"type":"keeper_row_changed","name":"lane-smith","ts_unix":100.0}

|}
  ; {|data: {"type":"keeper_roster_changed","ts_unix":100.0}

|}
  ]

let test_a_roster_push_names_the_row_or_every_row () =
  check (list string) "a row push names its Keeper; a roster push names every row"
    [ "roster_row:lane-smith"; "roster_all" ]
    (List.map summary (decode_all roster_frames));
  let changes frames =
    decode_all frames
    |> List.filter_map (function
         | Observer.Event (Observer.Keeper_roster_change change) -> Some change
         | Observer.Event _ | Observer.Undecodable _ -> None)
    |> List.length
  in
  check int "both owe the roster a read" 2 (changes roster_frames);
  check int "no question, Gate or held call change does" 0
    (changes (asks_frames @ gate_frames @ tool_approval_frames));
  check bool "a row push without its Keeper says why it was not read" true
    (match decode_all [ {|data: {"type":"keeper_row_changed"}

|} ] with
     | [ Observer.Undecodable reason ] ->
         String.starts_with ~prefix:"keeper_row_changed" reason
     | _ -> false)

let turn_frame =
  {|data: {"type":"keeper_turn_changed","name":"lane-smith","ts_unix":100.0}

|}

let preview_frame =
  {|data: {"type":"keeper_turn_preview_changed","name":"lane-smith","ts_unix":100.0}

|}

let test_a_turns_push_names_its_keeper () =
  check (list string) "a turns push and a preview push name their Keeper"
    [ "turns:lane-smith"; "preview:lane-smith" ]
    (List.map summary (decode_all [ turn_frame; preview_frame ]));
  let keepers frames =
    decode_all frames
    |> List.filter_map (function
         | Observer.Event event -> Option.map fst (Observer.turn_change event)
         | Observer.Undecodable _ -> None)
  in
  check (list string) "both owe that Keeper's turns a read" [ "lane-smith"; "lane-smith" ]
    (keepers [ turn_frame; preview_frame ]);
  check (list string) "no roster push does" [] (keepers roster_frames);
  check bool "a turns push without its Keeper says why it was not read" true
    (match decode_all [ {|data: {"type":"keeper_turn_changed"}

|} ] with
     | [ Observer.Undecodable reason ] ->
         String.starts_with ~prefix:"keeper_turn_changed" reason
     | _ -> false);
  check bool "a preview push without its Keeper says why it was not read" true
    (match decode_all [ {|data: {"type":"keeper_turn_preview_changed"}

|} ] with
     | [ Observer.Undecodable reason ] ->
         String.starts_with ~prefix:"keeper_turn_preview_changed" reason
     | _ -> false)

let verification_frames =
  [ {|data: {"type":"workspace_dataset_changed","dataset":"verification_requests","ts_unix":100.0}

|}
  ; {|data: {"type":"internal_agent_runs_changed","registry":"verification","ts_unix":100.0}

|}
  ]

let other_run_registry_frames =
  [ {|data: {"type":"internal_agent_runs_changed","registry":"goal_verification"}

|}
  ; {|data: {"type":"internal_agent_runs_changed","registry":"exact_lane"}

|}
  ]

let test_a_verification_or_run_push_reads_the_requests () =
  check (list string) "both decode with what changed"
    [ "dataset(verification_requests)"; "internal_runs(verification)" ]
    (List.map summary (decode_all verification_frames));
  let count frames =
    decode_all frames
    |> List.filter (function
         | Observer.Event event ->
             (match Observer.dataset_owed event with
              | Some Masc.Workspace_dataset_event.Verification_requests -> true
              | Some
                  ( Masc.Workspace_dataset_event.Repositories
                  | Masc.Workspace_dataset_event.Keeper_metrics _
                  | Masc.Workspace_dataset_event.Keeper_oauth_attempts _
                  | Masc.Workspace_dataset_event.Skill_activations _
                  | Masc.Workspace_dataset_event.Skill_catalog
                  | Masc.Workspace_dataset_event.Clients
                  | Masc.Workspace_dataset_event.Account_emails
                  | Masc.Workspace_dataset_event.Provider_usage
                  | Masc.Workspace_dataset_event.Provider_standing
                  | Masc.Workspace_dataset_event.Keeper_costs
                  | Masc.Workspace_dataset_event.Workspace_health
                  | Masc.Workspace_dataset_event.Runtime_probe
                  | Masc.Workspace_dataset_event.Runtime_metrics
                  | Masc.Workspace_dataset_event.Harness_verdicts
                  | Masc.Workspace_dataset_event.Goals
                  | Masc.Workspace_dataset_event.Runtime_config
                  | Masc.Workspace_dataset_event.Connectors
                  | Masc.Workspace_dataset_event.Lanes
                  | Masc.Workspace_dataset_event.Dashboard_observation _
                  | Masc.Workspace_dataset_event.World_memory
              | Masc.Workspace_dataset_event.Play_seats
              | Masc.Workspace_dataset_event.Memory_health _
                  | Masc.Workspace_dataset_event.Machine_live _
                  | Masc.Workspace_dataset_event.Play_room _
                  | Masc.Workspace_dataset_event.Browser_observation _
                  | Masc.Workspace_dataset_event.Lane_addons _ )
              | None -> false)
         | Observer.Undecodable _ -> false)
    |> List.length
  in
  check int "both owe the verification requests a read" 2 (count verification_frames);
  check int "no roster or turns push does" 0 (count (turn_frame :: roster_frames));
  check (list string) "the other registries decode by name"
    [ "internal_runs(goal_verification)"; "internal_runs(exact_lane)" ]
    (List.map summary (decode_all other_run_registry_frames));
  check int "and owe the verification requests nothing" 0 (count other_run_registry_frames);
  check (list string) "a Goal projection push decodes by name" [ "dataset(goals)" ]
    (List.map summary
       (decode_all [ "data: {\"type\":\"workspace_dataset_changed\",\"dataset\":\"goals\"}\n\n" ]));
  List.iter
    (fun frame ->
       match decode_all [ frame ] with
       | [ Observer.Undecodable _ ] -> ()
       | decoded ->
           fail
             ("a run push without a known registry was read: "
              ^ String.concat ", " (List.map summary decoded)))
    [ "data: {\"type\":\"internal_agent_runs_changed\"}\n\n"
    ; "data: {\"type\":\"internal_agent_runs_changed\",\"registry\":\"elsewhere\"}\n\n"
    ]

let test_browser_observation_decodes_the_exact_scope () =
  let frame =
    "data: {\"type\":\"workspace_dataset_changed\",\"dataset\":\"browser_observation\",\
     \"source\":\"live\",\"clientId\":\"01a16363-ef67-7000-ad62-05bcd0320d99\",\
     \"tabId\":2,\"view\":\"read\",\"revision\":\"" ^ String.make 64 'a' ^ "\"}\n\n"
  in
  match decode_all [ frame ] with
  | [ Observer.Event (Observer.Dataset_changed
        (Masc.Workspace_dataset_event.Browser_observation observation)) ] ->
      check string "the exact Browser client survives" "01a16363-ef67-7000-ad62-05bcd0320d99"
        (Option.get observation.scope.client_id);
      check int "the exact tab survives" 2 observation.scope.tab_id;
      check string "the revision survives" (String.make 64 'a') observation.revision
  | decoded ->
      fail ("a matching Browser observation did not decode: "
        ^ String.concat ", " (List.map summary decoded))

let event_queue_frame =
  {|data: {"type":"keeper_event_queue_changed","keeper":"alpha"}

|}

let test_a_queue_push_names_its_keeper () =
  check (list string) "it decodes with the Keeper it names" [ "event_queue(alpha)" ]
    (List.map summary (decode_all [ event_queue_frame ]));
  let keepers frames =
    decode_all frames
    |> List.filter_map (function
         | Observer.Event event -> Observer.event_queue_changed event
         | Observer.Undecodable _ -> None)
  in
  check (list string) "it is read as that Keeper's queue" [ "alpha" ] (keepers [ event_queue_frame ]);
  check (list string) "a schedule push names no queue" [] (keepers [ schedules_frame ]);
  match decode_all [ "data: {\"type\":\"keeper_event_queue_changed\"}\n\n" ] with
  | [ Observer.Undecodable _ ] -> ()
  | decoded ->
      fail
        ("a queue push without a Keeper was read: "
         ^ String.concat ", " (List.map summary decoded))

let repositories_frame =
  {|data: {"type":"workspace_dataset_changed","dataset":"repositories","ts_unix":100.0}

|}

let test_a_repository_push_reads_the_list () =
  check (list string) "it decodes with the dataset it names" [ "dataset(repositories)" ]
    (List.map summary (decode_all [ repositories_frame ]));
  let count frames =
    decode_all frames
    |> List.filter (function
         | Observer.Event event ->
             (match Observer.dataset_owed event with
              | Some Masc.Workspace_dataset_event.Repositories -> true
              | Some
                  ( Masc.Workspace_dataset_event.Verification_requests
                  | Masc.Workspace_dataset_event.Keeper_metrics _
                  | Masc.Workspace_dataset_event.Keeper_oauth_attempts _
                  | Masc.Workspace_dataset_event.Skill_activations _
                  | Masc.Workspace_dataset_event.Skill_catalog
                  | Masc.Workspace_dataset_event.Clients
                  | Masc.Workspace_dataset_event.Account_emails
                  | Masc.Workspace_dataset_event.Provider_usage
                  | Masc.Workspace_dataset_event.Provider_standing
                  | Masc.Workspace_dataset_event.Keeper_costs
                  | Masc.Workspace_dataset_event.Workspace_health
                  | Masc.Workspace_dataset_event.Runtime_probe
                  | Masc.Workspace_dataset_event.Runtime_metrics
                  | Masc.Workspace_dataset_event.Harness_verdicts
                  | Masc.Workspace_dataset_event.Goals
                  | Masc.Workspace_dataset_event.Runtime_config
                  | Masc.Workspace_dataset_event.Connectors
                  | Masc.Workspace_dataset_event.Lanes
                  | Masc.Workspace_dataset_event.Dashboard_observation _
                  | Masc.Workspace_dataset_event.World_memory
              | Masc.Workspace_dataset_event.Play_seats
              | Masc.Workspace_dataset_event.Memory_health _
                  | Masc.Workspace_dataset_event.Machine_live _
                  | Masc.Workspace_dataset_event.Play_room _
                  | Masc.Workspace_dataset_event.Browser_observation _
                  | Masc.Workspace_dataset_event.Lane_addons _ )
              | None -> false)
         | Observer.Undecodable _ -> false)
    |> List.length
  in
  check int "it owes the repository list a read" 1 (count [ repositories_frame ]);
  check bool "it owes the verification requests nothing" true
    (match decode_all [ repositories_frame ] with
     | [ Observer.Event event ] ->
         (match Observer.dataset_owed event with
          | Some Masc.Workspace_dataset_event.Verification_requests -> false
          | Some
              ( Masc.Workspace_dataset_event.Repositories
              | Masc.Workspace_dataset_event.Keeper_metrics _
              | Masc.Workspace_dataset_event.Keeper_oauth_attempts _
              | Masc.Workspace_dataset_event.Skill_activations _
              | Masc.Workspace_dataset_event.Skill_catalog
              | Masc.Workspace_dataset_event.Clients
              | Masc.Workspace_dataset_event.Account_emails
              | Masc.Workspace_dataset_event.Provider_usage
              | Masc.Workspace_dataset_event.Provider_standing
              | Masc.Workspace_dataset_event.Keeper_costs
              | Masc.Workspace_dataset_event.Workspace_health
              | Masc.Workspace_dataset_event.Runtime_probe
              | Masc.Workspace_dataset_event.Runtime_metrics
              | Masc.Workspace_dataset_event.Harness_verdicts
              | Masc.Workspace_dataset_event.Goals
              | Masc.Workspace_dataset_event.Runtime_config
              | Masc.Workspace_dataset_event.Connectors
              | Masc.Workspace_dataset_event.Lanes
              | Masc.Workspace_dataset_event.Dashboard_observation _
              | Masc.Workspace_dataset_event.World_memory
              | Masc.Workspace_dataset_event.Play_seats
              | Masc.Workspace_dataset_event.Memory_health _
              | Masc.Workspace_dataset_event.Machine_live _
              | Masc.Workspace_dataset_event.Play_room _
              | Masc.Workspace_dataset_event.Browser_observation _
              | Masc.Workspace_dataset_event.Lane_addons _ )
          | None -> true)
     | _ -> false);
  check int "a verification or run push does not" 0 (count verification_frames);
  List.iter
    (fun frame ->
       match decode_all [ frame ] with
       | [ Observer.Undecodable _ ] -> ()
       | decoded ->
           fail
             ("a dataset push without a known dataset was read: "
              ^ String.concat ", " (List.map summary decoded)))
    [ "data: {\"type\":\"workspace_dataset_changed\"}\n\n"
    ; "data: {\"type\":\"workspace_dataset_changed\",\"dataset\":\"elsewhere\"}\n\n"
    ; "data: {\"type\":\"workspace_dataset_changed\",\"dataset\":\"keeper_metrics\"}\n\n"
    ; "data: {\"type\":\"workspace_dataset_changed\",\"dataset\":\"keeper_metrics\",\"keeper\":\"\"}\n\n"
    ; "data: {\"type\":\"workspace_dataset_changed\",\"dataset\":\"keeper_oauth_attempts\"}\n\n"
    ; "data: {\"type\":\"workspace_dataset_changed\",\"dataset\":\"keeper_oauth_attempts\",\"keeper\":\"\"}\n\n"
    ; "data: {\"type\":\"workspace_dataset_changed\",\"dataset\":\"skill_activations\"}\n\n"
    ; "data: {\"type\":\"workspace_dataset_changed\",\"dataset\":\"memory_health\"}\n\n"
    ; "data: {\"type\":\"workspace_dataset_changed\",\"dataset\":\"memory_health\",\"keeper\":\"\"}\n\n"
    ];
  check (list string) "a harness push decodes by name"
    [ "dataset(harness_verdicts)" ]
    (List.map summary
       (decode_all
          [ "data: {\"type\":\"workspace_dataset_changed\",\"dataset\":\"harness_verdicts\"}\n\n" ]));
  check (list string) "a Keeper's metrics push names its Keeper"
    [ "dataset(keeper_metrics:alpha)" ]
    (List.map summary
       (decode_all
          [ "data: {\"type\":\"workspace_dataset_changed\",\"dataset\":\"keeper_metrics\",\"keeper\":\"alpha\"}\n\n" ]));
  check (list string) "a Keeper's login attempts decode with the Keeper"
    [ "dataset(keeper_oauth_attempts:largo)" ]
    (List.map summary
       (decode_all
          [ "data: {\"type\":\"workspace_dataset_changed\",\"dataset\":\"keeper_oauth_attempts\",\"keeper\":\"largo\"}\n\n" ]));
  check (list string) "Clients and provider usage and standing pushes decode by name"
    [ "dataset(clients)"; "dataset(provider_usage)"; "dataset(provider_standing)" ]
    (List.map summary
       (decode_all
          [ "data: {\"type\":\"workspace_dataset_changed\",\"dataset\":\"clients\"}\n\n"
          ; "data: {\"type\":\"workspace_dataset_changed\",\"dataset\":\"provider_usage\"}\n\n"
          ; "data: {\"type\":\"workspace_dataset_changed\",\"dataset\":\"provider_standing\"}\n\n"
          ]));
  check (list string) "an account emails push decodes by name"
    [ "dataset(account_emails)" ]
    (List.map summary
       (decode_all
          [ "data: {\"type\":\"workspace_dataset_changed\",\"dataset\":\"account_emails\"}\n\n" ]));
  check (list string) "A Keeper costs push decodes by name"
    [ "dataset(keeper_costs)" ]
    (List.map summary
       (decode_all
          [ "data: {\"type\":\"workspace_dataset_changed\",\"dataset\":\"keeper_costs\"}\n\n" ]));
  check (list string) "Skill pushes decode with the Keeper a ledger row names"
    [ "dataset(skill_activations:alpha)"; "dataset(skill_catalog)" ]
    (List.map summary
       (decode_all
          [ "data: {\"type\":\"workspace_dataset_changed\",\"dataset\":\"skill_activations\",\"keeper\":\"alpha\"}\n\n"
          ; "data: {\"type\":\"workspace_dataset_changed\",\"dataset\":\"skill_catalog\"}\n\n"
          ]));
  check (list string) "a Keeper's memory health push decodes with the Keeper"
    [ "dataset(memory_health:largo)" ]
    (List.map summary
       (decode_all
          [ "data: {\"type\":\"workspace_dataset_changed\",\"dataset\":\"memory_health\",\"keeper\":\"largo\"}\n\n" ]))

let connector_frame =
  {|data: {"type":"gate_connector_changed","connector":"slack","ts_unix":100.0}

|}

let test_a_connector_push_names_its_connector () =
  check (list string) "it decodes with the connector it names" [ "connector(slack)" ]
    (List.map summary (decode_all [ connector_frame ]));
  let count frames =
    decode_all frames
    |> List.filter (function
         | Observer.Event event -> Observer.gate_connector_changed event
         | Observer.Undecodable _ -> false)
    |> List.length
  in
  check int "it owes the connectors a read" 1 (count [ connector_frame ]);
  check int "a repository push does not" 0 (count [ repositories_frame ]);
  match decode_all [ "data: {\"type\":\"gate_connector_changed\"}\n\n" ] with
  | [ Observer.Undecodable _ ] -> ()
  | decoded ->
      fail
        ("a connector push without a connector was read: "
         ^ String.concat ", " (List.map summary decoded))

let test_only_a_question_change_reads_the_questions () =
  check (list string) "question changes decode with what asked them"
    [ "approval(asks:lane-smith)"; "approval(installation_asks:quiz)" ]
    (List.map summary (decode_all asks_frames));
  let count reads frames =
    decode_all frames
    |> List.filter (function
         | Observer.Event event -> reads event
         | Observer.Undecodable _ -> false)
    |> List.length
  in
  check int "both question changes read the questions" 2
    (count Observer.asks_changed asks_frames);
  check int "no Gate, held call or mode change does" 0
    (count Observer.asks_changed (gate_frames @ tool_approval_frames));
  check int "a question change reads no Gate, held calls or modes" 0
    (count
       (fun event ->
          Observer.gate_snapshot_changed event || Observer.held_calls_changed event
          || Observer.tool_modes_changed event)
       asks_frames);
  check bool "a question change without its asker says why it was not read" true
    (match decode_all [ {|data: {"type":"lane_addon_asks_changed"}

|} ] with
     | [ Observer.Undecodable reason ] -> String.starts_with ~prefix:"lane_addon_asks_changed" reason
     | _ -> false)

let test_only_a_gate_change_changes_the_gate_snapshot () =
  check (list string) "Gate changes decode to what changed"
    [ "approval(queue)"; "approval(queue)"; "approval(queue)"; "approval(rules)"
    ; "approval(gate_mode)"; "approval(gate_mode)"
    ; "approval(keeper_settings:lane-smith)"; "approval(keeper_settings:lane-smith)" ]
    (List.map summary (decode_all gate_frames));
  check (list string) "held call and mode changes decode with their Keeper"
    [ "approval(waits:lane-smith)"; "approval(mode:lane-smith)" ]
    (List.map summary (decode_all tool_approval_frames));
  let gate_changes frames =
    decode_all frames
    |> List.filter (function
         | Observer.Event event -> Observer.gate_snapshot_changed event
         | Observer.Undecodable _ -> false)
    |> List.length
  in
  check int "every Gate change changes the snapshot" (List.length gate_frames)
    (gate_changes gate_frames);
  check int "no other sample event does" 0
    (gate_changes
       (tool_approval_frames
        @ [ tool_called_frame; agent_completed_frame; agent_failed_frame
          ; heartbeat_frame; turn_complete_frame; keeper_tool_call_frame
          ; composite_frame; chat_stream_delta_frame; chat_stream_custom_frame
          ; waiting_inventory_frame; operator_digest_frame
          ; transport_health_frame; fusion_run_status_frame
          ; turn_observation_frame; chat_appended_frame; memory_journal_frame
          ; board_post_changed_frame ]));
  let count reads frames =
    decode_all frames
    |> List.filter (function
         | Observer.Event event -> reads event
         | Observer.Undecodable _ -> false)
    |> List.length
  in
  check int "only the held call change reads the held calls" 1
    (count Observer.held_calls_changed (gate_frames @ tool_approval_frames));
  (* A mode change and the two Keeper Gate setting changes. *)
  check int "a mode or Keeper Gate setting change reads the modes" 3
    (count Observer.tool_modes_changed (gate_frames @ tool_approval_frames));
  check bool "a Keeper setting change without its Keeper says why it was not read" true
    (match decode_all [ {|data: {"type":"gate_keeper_mode_changed","mode":null}

|} ] with
     | [ Observer.Undecodable reason ] ->
         String.starts_with ~prefix:"gate_keeper_mode_changed" reason
     | _ -> false)

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
    (List.map (fun (delivery : Observer.delivery) -> summary delivery.decoded) (Observer.feed reader head));
  check (list string) "and decodes whole once the rest arrives"
    [ "agent_core(analyst,tool_called,read_file,turn=2086,batch=0/2)" ]
    (List.map (fun (delivery : Observer.delivery) -> summary delivery.decoded) (Observer.feed reader tail))

let untaught_agent_core_frame =
  "data: {\"type\":\"agent_core:relay_dropped\",\"event_type\":\"relay_dropped\",\
   \"agent_name\":\"lane-smith\",\"ts_unix\":1.0}\n\n"

(* The run registries' change push is read by the name the server broadcasts
   it under, so the two cannot drift apart. *)
let test_the_internal_runs_push_is_read_by_the_servers_name () =
  let registries =
    Masc.Internal_agent_runs_event.[ Verification; Goal_verification; Exact_lane ]
  in
  check (list string) "the frames the server broadcasts decode to the push"
    [ "internal_runs(verification)"; "internal_runs(goal_verification)"
    ; "internal_runs(exact_lane)" ]
    (List.map summary
       (decode_all
          (List.map
             (fun registry ->
                "data: "
                ^ Yojson.Safe.to_string (Masc.Internal_agent_runs_event.to_json registry)
                ^ "\n\n")
             registries)))

let test_schedule_change_is_read_by_the_servers_name () =
  check (list string) "the schedule invalidation has a typed event"
    [ "schedule_store_invalidated" ]
    (List.map summary
       (decode_all
          [ "data: " ^ Yojson.Safe.to_string Masc.Schedule_invalidation_event.json ^ "\n\n" ]))

let test_pending_confirm_change_is_read_by_the_servers_name () =
  check (list string) "the pending confirmation invalidation has a typed event"
    [ "pending_confirm_invalidated" ]
    (List.map summary
       (decode_all
          [ "data: " ^ Yojson.Safe.to_string Masc.Pending_confirm_invalidation_event.json ^ "\n\n" ]))

(* The frame the bridge makes of the event the lane runtime publishes, so the
   test reads what the wire carries rather than a hand-built copy of it. *)
module Lane_events = Masc.Lane_addon_resource_events

let lane_resource_frame ?detail lifecycle =
  let resource =
    { Lane_events.instance_id = "inst-7"
    ; run_id = "run-7"
    ; package_id = "masc-dos"
    ; package_revision = "rev-1"
    ; resource = None
    ; detail
    }
  in
  match
    Masc.Keeper_event_bridge.native_event_to_json
      (Lane_events.event lifecycle resource)
  with
  | Some json -> "data: " ^ Yojson.Safe.to_string json ^ "\n\n"
  | None -> fail "the bridge relays no frame for a lane resource event"

(* Every lifecycle the lane runtime publishes is read as what it is, with the
   package, the instance and the failure reason the payload carries. *)
let test_every_lane_resource_lifecycle_is_read_with_its_payload () =
  List.iter
    (fun lifecycle ->
      let name = Lane_events.wire_name lifecycle in
      match decode_all [ lane_resource_frame ~detail:"image not found" lifecycle ] with
      | [ Observer.Event (Observer.Lane_resource resource) ] ->
          check bool (name ^ " keeps its lifecycle") true
            (resource.Observer.lr_lifecycle = lifecycle);
          check string (name ^ " names its package") "masc-dos"
            resource.Observer.lr_package;
          check string (name ^ " names its instance") "inst-7"
            resource.Observer.lr_instance;
          check (option string) (name ^ " keeps the reason") (Some "image not found")
            resource.Observer.lr_detail
      | decoded ->
          failf "%s decoded as %s" name
            (String.concat "; " (List.map summary decoded)))
    Lane_events.all

let test_a_lane_resource_without_a_reason_says_so () =
  check (list string) "an acquisition carries no reason"
    [ "lane_resource(masc-dos,inst-7,-)" ]
    (List.map summary (decode_all [ lane_resource_frame Lane_events.Acquired ]))
(* A run that ended says how long it ran, and a failed one why, read from
   the payload the bridge writes. *)
let test_an_ended_run_carries_its_elapsed_and_error () =
  (match decode_all [ agent_completed_frame ] with
   | [ Observer.Event
         (Observer.Agent_core
            { Observer.kind = Observer.Agent_completed { elapsed_s }; _ }) ] ->
       check (float 0.) "a completed run's elapsed" 1.25 elapsed_s
   | _ -> fail "expected one completed run");
  match decode_all [ agent_failed_frame ] with
  | [ Observer.Event
        (Observer.Agent_core
           { Observer.kind = Observer.Agent_failed { elapsed_s; error_code; error }; _ }) ] ->
      check (float 0.) "a failed run's elapsed" 0.5 elapsed_s;
      check string "its code" "provider_error" error_code;
      check string "its error" "rate limited" error
  | _ -> fail "expected one failed run"

(* A failure whose payload does not satisfy the contract is a frame this
   build cannot read, said with the reason, not a failure drawn without its
   cause. *)
let test_a_failed_run_without_its_error_is_undecodable () =
  let frame =
    "data: {\"type\":\"agent_core:agent_failed\",\"event_type\":\"agent_failed\",\
     \"ts_unix\":1.0,\"agent_name\":\"analyst\",\
     \"payload\":{\"agent_name\":\"analyst\",\"task_id\":\"evt-1\",\
     \"elapsed_s\":0.5}}\n\n"
  in
  match decode_all [ frame ] with
  | [ Observer.Undecodable reason ] ->
      check bool
        (Printf.sprintf "the reason names the payload: %s" reason)
        true
        (String.starts_with ~prefix:"agent_failed payload" reason)
  | decoded ->
      failf "expected an undecodable frame, got %s"
        (String.concat "; " (List.map summary decoded))

let test_what_this_build_was_not_taught_keeps_its_name () =
  check (list string) "snapshots are named, not retained; unknown types are named"
    [ "snapshot:execution_snapshot"
    ; "other:brand_new_push"
    ; "agent_core(lane-smith,other:relay_dropped,-,turn=-,batch=-)"
    ]
    (List.map summary
       (decode_all
          [ "data: {\"type\":\"execution_snapshot\",\"payload\":{\"keepers\":[]}}\n\n"
          ; "data: {\"type\":\"brand_new_push\"}\n\n"
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
             \"payload\":[\"Streaming_summary\",{\"ttft_ms\":19048.7}]}\n\n"
          ]))

let test_relay_subscription_loss_is_typed () =
  let frame source_id sequence count =
    let event_type = Masc.Keeper_event_bridge.subscription_loss_event_type in
    let json = `Assoc
      [ "type", `String ("agent_core:" ^ event_type)
      ; "event_type", `String event_type
      ; "ts_unix", `Float 1.
      ; "payload", `Assoc [ "source_id", source_id; "sequence", sequence;
                             "dropped_count", count ]
      ] in
    "data: " ^ Yojson.Safe.to_string json ^ "\n\n"
  in
  (match decode_all [ frame (`String "bridge-a") (`Int 2) (`Int 44) ] with
   | [ Observer.Event (Observer.Agent_core
         { kind = Observer.Relay_subscription_loss
             { source_id = "bridge-a"; sequence = 2; dropped_count = 44 }; _ }) ] -> ()
   | _ -> fail "expected a typed loss notice");
  List.iter (fun (source_id, sequence, count) ->
    match decode_all [ frame source_id sequence count ] with
    | [ Observer.Undecodable _ ] -> ()
    | _ -> fail "invalid loss identity or count was accepted")
    [ `String "a", `Int 1, `Int 0
    ; `String "a", `Int 1, `Int (-1)
    ; `String "a", `Int 1, `String "44"
    ; `String "a", `Int 1, `Null
    ; `String "", `Int 1, `Int 1
    ; `String "a", `Int 0, `Int 1
    ; `Null, `Int 1, `Int 1 ]
;;

let test_a_frame_this_cannot_read_says_why () =
  let reasons =
    decode_all
      [ "data: nope\n\n"
      ; "data: {\"ts_unix\":1.0}\n\n"
      ; "data: {\"type\":\"agent_core:tool_called\",\"event_type\":\"tool_called\",\"agent_name\":\"x\"}\n\n"
      ; "data:{\"type\":\"keeper_heartbeat\"}\n\n"
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

let test_exact_event_references_and_keeper_io () =
  let core =
    "data: {\"type\":\"agent_core:tool_completed\",\"event_type\":\"tool_completed\",\"ts_unix\":100,\"event_id\":\"event-exact\",\"run_id\":\"run-exact\",\"caused_by\":\"cause-exact\",\"parent_event_id\":\"parent-exact\",\"correlation_id\":\"trace-exact\",\"payload\":{\"tool_use_id\":\"call-exact\",\"execution_id\":\"exec-exact\"}}\n\n" in
  (match decode_all [core] with
   | [Observer.Event (Observer.Agent_core event)] ->
       check (option string) "event ID" (Some "event-exact") event.event_id;
       check (option string) "run ID" (Some "run-exact") event.run_id;
       check (option string) "causation" (Some "cause-exact") event.caused_by;
       check (option string) "parent" (Some "parent-exact") event.parent;
       check (option string) "correlation" (Some "trace-exact") event.correlation;
       check (option string) "execution" (Some "exec-exact") event.execution_id
   | _ -> fail "exact runtime event references were lost");
  let keeper =
    "data: {\"type\":\"keeper_tool_call\",\"name\":\"alpha\",\"tool_name\":\"keeper_skill\",\"ts_unix\":100,\"tool_use_id\":\"skill-call-exact\",\"tool_args\":{\"skill\":\"read-plan\"},\"tool_result\":null,\"tool_args_preview\":\"safe input\",\"tool_output_preview\":\"safe output\"}\n\n" in
  (match decode_all [keeper] with
   | [Observer.Event (Observer.Keeper_tool_call event)] ->
       check (option string) "provider call identity" (Some "skill-call-exact") event.kt_tool_use_id;
       check bool "provided JSON null survives" true (event.kt_tool_result = Some `Null);
       check bool "structured input survives" true
         (event.kt_tool_args = Some (`Assoc ["skill", `String "read-plan"]));
       check (option string) "redacted input preview" (Some "safe input") event.kt_tool_args_preview;
       check (option string) "redacted output preview" (Some "safe output") event.kt_tool_output_preview
   | _ -> fail "Keeper I/O observations were lost");
  match decode_all ["data: {\"type\":\"agent_core:tool_called\",\"event_type\":\"tool_called\",\"ts_unix\":100,\"event_id\":4}\n\n"] with
  | [Observer.Undecodable _] -> ()
  | _ -> fail "malformed identity became missing identity"

(* The disposition arrives typed in the call log's vocabulary. A blank word
   is no word, as the call log decoder reads it; a word outside the
   vocabulary stays an error beside the call rather than a default. *)
let test_keeper_disposition_is_typed_at_the_wire () =
  let observe extra =
    let json = `Assoc
      ([ "type", `String "keeper_tool_call"; "name", `String "alpha"
       ; "tool_name", `String "Read"; "ts_unix", `Int 100 ] @ extra)
    in
    match decode_all ["data: " ^ Yojson.Safe.to_string json ^ "\n\n"] with
    | [Observer.Event (Observer.Keeper_tool_call event)] -> event.kt_disposition
    | _ -> fail "the call was not decoded"
  in
  check bool "absent stays absent" true (observe [] = None);
  check bool "blank is absent, as the call log reads it" true
    (observe [ "disposition", `String "" ] = None);
  check bool "the wire word becomes the variant" true
    (observe [ "disposition", `String "deferred" ]
     = Some (Ok Masc.Tui_decode.Keeper_call_deferred));
  match observe [ "disposition", `String "delivered" ] with
  | Some (Error reason) ->
      check bool "an unknown word is kept as the error" true
        (String.starts_with ~prefix:"keeper call has unknown disposition" reason)
  | Some (Ok _) | None -> fail "an unknown word was folded into a default"

let test_keeper_scheduling_keeps_io_when_metadata_is_invalid () =
  let observe extra =
    let json = `Assoc
      ([ "type", `String "keeper_tool_call"; "name", `String "alpha"
       ; "tool_name", `String "keeper_skill"; "ts_unix", `Int 100
       ; "tool_result", `Assoc [ "receipt", `String "retained" ] ] @ extra)
    in
    match decode_all ["data: " ^ Yojson.Safe.to_string json ^ "\n\n"] with
    | [Observer.Event (Observer.Keeper_tool_call event)] ->
        check bool "call result survives scheduling metadata" true
          (event.kt_tool_result = Some (`Assoc ["receipt", `String "retained"]));
        event.kt_schedule
    | _ -> fail "schedule metadata discarded the call evidence"
  in
  check bool "absent is not invented serial" true (observe [] = None);
  List.iter
    (fun mode ->
      let schedule : Agent_core.Tool_contract.schedule =
        { planned_index = 3; batch_index = 1; batch_size = 2; execution_mode = mode }
      in
      let fields = match Agent_core.Execution_tool_schedule.to_yojson schedule with
        | `Assoc fields -> fields
        | _ -> fail "schedule contract did not encode an object"
      in
      check bool "canonical schedule survives" true
        (observe fields = Some (Ok schedule)))
    [Agent_core.Tool_contract.Concurrent; Agent_core.Tool_contract.Serial];
  List.iter
    (fun fields ->
      match observe fields with
      | Some (Error _) -> ()
      | Some (Ok _) | None -> fail "partial or invalid scheduling became missing or valid")
    [ ["batch_index", `Int 0]
    ; ["planned_index", `Int 0; "batch_index", `Int 0; "batch_size", `Int 1;
       "execution_mode", `String "unknown"]
    ]

let test_cursor_commits_only_with_a_complete_event () =
  let reader = Observer.create () in
  check int "ID-only frame does not acknowledge an event" 0
    (List.length (Observer.feed reader "id: 41\n\n"));
  let partial =
    "id: 42\ndata: {\"type\":\"keeper_tool_call\",\"name\":\"alpha\",\"tool_name\":\"keeper_skill\",\"ts_unix\":1}\n"
  in
  check int "data line without frame terminator is not delivered" 0
    (List.length (Observer.feed reader partial));
  (match Observer.feed reader "\n" with
   | [{ Observer.cursor = Some 42; decoded = Observer.Event (Observer.Keeper_tool_call call) }] ->
       check string "complete frame retains exact call" "keeper_skill" call.kt_tool
   | _ -> fail "expected one fully framed event with cursor 42");
  check int "unfinished payload is not a delivered cursor" 0
    (List.length (Observer.feed reader "id: 43\ndata: {"))

let test_multiline_frame_preserves_payload_and_cursor () =
  let reader = Observer.create () in
  match Observer.feed reader
    "id: 44\ndata: {\"type\":\"keeper_tool_call\",\ndata: \"name\":\"alpha\",\"tool_name\":\"keeper_skill\",\"ts_unix\":1}\n\n" with
  | [{ Observer.cursor = Some 44; decoded = Observer.Event (Observer.Keeper_tool_call call) }] ->
      check string "multiline canonical SSE data preserved" "alpha" call.kt_keeper
  | _ -> fail "expected one multiline event with cursor 44"

let test_lane_inventory_pushes_decode_with_their_scope () =
  let lanes = "data: {\"type\":\"workspace_dataset_changed\",\"dataset\":\"lanes\"}\n\n" in
  let addon = "data: {\"type\":\"workspace_dataset_changed\",\"dataset\":\"lane_addons\",\"instance_id\":\"inst-7\"}\n\n" in
  check (list string) "Lane and Add-on pushes decode by name"
    [ "dataset(lanes)"; "dataset(lane_addons)" ]
    (List.map summary (decode_all [ lanes; addon ]));
  List.iter
    (fun (frame, expected_name) ->
      match decode_all [ frame ] with
      | [ Observer.Event event ] ->
          (match Observer.dataset_owed event with
           | Some dataset ->
               check string "the owed dataset survives" expected_name
                 (Masc.Workspace_dataset_event.dataset_name dataset)
           | None -> fail "a Lane push owes no read")
      | decoded -> failf "a Lane push was not read: %s"
          (String.concat ", " (List.map summary decoded)))
    [ lanes, "lanes"; addon, "lane_addons" ];
  let fields = match Yojson.Safe.from_string
    "{\"type\":\"workspace_dataset_changed\",\"dataset\":\"lane_addons\",\"instance_id\":\"inst-7\"}" with
    | `Assoc fields -> fields
    | _ -> fail "the Add-on fixture is not an object"
  in
  (match Masc.Workspace_dataset_event.of_fields fields with
   | Ok dataset ->
       check string "the Add-on dataset name" "lane_addons"
         (Masc.Workspace_dataset_event.dataset_name dataset);
       check (option string) "the open instance is preserved" (Some "inst-7")
         (Option.bind (List.assoc_opt "instance_id" fields)
           Yojson.Safe.Util.to_string_option)
   | Error detail -> fail detail);
  List.iter
    (fun frame ->
      match decode_all [ frame ] with
      | [ Observer.Undecodable _ ] -> ()
      | decoded -> failf "an Add-on push without a valid instance was read: %s"
          (String.concat ", " (List.map summary decoded)))
    [ "data: {\"type\":\"workspace_dataset_changed\",\"dataset\":\"lane_addons\"}\n\n"
    ; "data: {\"type\":\"workspace_dataset_changed\",\"dataset\":\"lane_addons\",\"instance_id\":\"\"}\n\n" ]

let test_play_room_pushes_share_cross_machine_changes () =
  List.iter
    (fun expected ->
      let fields = [ "type", `String "workspace_dataset_changed"
                   ; "dataset", `String "play_room"; "machine", `String expected ] in
      match Masc.Workspace_dataset_event.of_fields fields with
      | Ok (Masc.Workspace_dataset_event.Play_room { machine }) ->
          check string "the source machine is preserved" expected
            (Masc.Machine_lane.to_wire machine)
      | Ok _ | Error _ -> fail "a Play room push lost its source machine")
    [ "msx"; "dos" ];
  List.iter
    (fun fields ->
      match Masc.Workspace_dataset_event.of_fields fields with
      | Error _ -> ()
      | Ok _ -> fail "a Play room push with invalid scope was accepted")
    [ [ "type", `String "workspace_dataset_changed"; "dataset", `String "play_room" ]
    ; [ "type", `String "workspace_dataset_changed"; "dataset", `String "play_room"
      ; "machine", `String "other" ] ]

let test_workspace_memory_and_play_seats_reach_the_typed_consumer () =
  List.iter (fun dataset ->
    let wire = Yojson.Safe.to_string (`Assoc
      [ "type", `String Masc.Workspace_dataset_event.event_type
      ; "dataset", `String (Masc.Workspace_dataset_event.dataset_to_wire dataset)
      ; "ts_unix", `Float 1.0 ]) in
    match decode_all [ "data: " ^ wire ^ "\n\n" ] with
    | [Observer.Event event] ->
        check bool "the producer name reaches the dataset read dispatcher" true
          (Observer.dataset_owed event = Some dataset)
    | [] | _ :: _ -> fail "the workspace push did not decode as one event")
    [Masc.Workspace_dataset_event.World_memory; Masc.Workspace_dataset_event.Play_seats]

let test_memory_health_pushes_require_their_keeper () =
  let fields = [ "type", `String "workspace_dataset_changed"
               ; "dataset", `String "memory_health"; "keeper", `String "alpha" ] in
  (match Masc.Workspace_dataset_event.of_fields fields with
   | Ok (Masc.Workspace_dataset_event.Memory_health { keeper }) ->
       check string "the changed Keeper is preserved" "alpha" keeper
   | Ok _ | Error _ -> fail "a Memory health push lost its Keeper");
  List.iter
    (fun frame ->
      match decode_all [ frame ] with
      | [ Observer.Undecodable _ ] -> ()
      | decoded -> failf "a Memory health push without a valid Keeper was read: %s"
          (String.concat ", " (List.map summary decoded)))
    [ "data: {\"type\":\"workspace_dataset_changed\",\"dataset\":\"memory_health\"}\n\n"
    ; "data: {\"type\":\"workspace_dataset_changed\",\"dataset\":\"memory_health\",\"keeper\":\"\"}\n\n" ]

let test_machine_live_pushes_scope_the_machine () =
  List.iter
    (fun expected ->
      let fields = [ "type", `String "workspace_dataset_changed"
                   ; "dataset", `String "machine_live"; "machine", `String expected ] in
      match Masc.Workspace_dataset_event.of_fields fields with
      | Ok (Masc.Workspace_dataset_event.Machine_live { machine }) ->
          check string "only the selected machine is named" expected
            (Masc.Machine_lane.to_wire machine)
      | Ok _ | Error _ -> fail "a machine push was not decoded")
    [ "msx"; "dos" ];
  List.iter
    (fun frame ->
      match decode_all [ frame ] with
      | [ Observer.Undecodable _ ] -> ()
      | decoded -> failf "a machine push without a valid machine was read: %s"
          (String.concat ", " (List.map summary decoded)))
    [ "data: {\"type\":\"workspace_dataset_changed\",\"dataset\":\"machine_live\"}\n\n"
    ; "data: {\"type\":\"workspace_dataset_changed\",\"dataset\":\"machine_live\",\"machine\":\"\"}\n\n"
    ; "data: {\"type\":\"workspace_dataset_changed\",\"dataset\":\"machine_live\",\"machine\":\"other\"}\n\n" ]

let () =
  run "tui observer"
    [ ( "session"
      , [ test_case "the session id is read off the initialize answer" `Quick
            test_the_session_id_is_read_off_the_initialize_answer
        ; test_case "the initialize body names the method and the client" `Quick
            test_the_initialize_body_names_the_method_and_the_client
        ] )
    ; ( "events"
      , [ test_case "Keeper disposition is typed at the wire" `Quick
            test_keeper_disposition_is_typed_at_the_wire
        ; test_case "Keeper scheduling preserves call evidence" `Quick
            test_keeper_scheduling_keeps_io_when_metadata_is_invalid
        ; test_case "exact event references and redacted Keeper I/O survive" `Quick
            test_exact_event_references_and_keeper_io
        ; test_case "a tool call decodes with its turn and batch" `Quick
            test_a_tool_call_decodes_with_its_turn_and_batch
        ; test_case "agent terminal frames keep their distinct kinds" `Quick
            test_agent_terminal_frames_keep_their_distinct_kinds
        ; test_case "keeper events decode by name" `Quick
            test_keeper_events_decode_by_name
        ; test_case "the chat stream and waiting queue keep their keeper and clock"
            `Quick test_the_chat_stream_and_waiting_queue_keep_their_keeper_and_clock
        ; test_case "every whole-projection push decodes as a snapshot" `Quick
            test_every_whole_projection_push_decodes_as_a_snapshot
        ; test_case "a frame its type decides is not read past the type" `Quick
            test_a_frame_its_type_decides_is_not_read_past_the_type
        ; test_case "a delta with a slice is not a snapshot" `Quick
            test_a_delta_with_a_slice_is_not_a_snapshot
        ; test_case "a metrics append names its Keeper" `Quick
            test_a_metrics_append_names_its_keeper
        ; test_case "a Goal projection change is named" `Quick
            test_a_goal_projection_change_is_named
        ; test_case "a runtime.toml change is named" `Quick
            test_a_runtime_config_change_is_named
        ; test_case "only a chat-appended event names a reload keeper" `Quick
            test_only_a_chat_appended_event_names_a_reload_keeper
        ; test_case "only a memory journal event names a journal keeper" `Quick
            test_only_a_memory_journal_event_names_a_journal_keeper
        ; test_case "only a runtime journal event names a runtime journal" `Quick
            test_only_a_runtime_journal_event_names_a_runtime_journal
        ; test_case "only a board notification names a board change" `Quick
            test_only_a_board_notification_names_a_board_change
        ; test_case "only a Gate change changes the Gate snapshot" `Quick
            test_only_a_gate_change_changes_the_gate_snapshot
        ; test_case "only a question change reads the questions" `Quick
            test_only_a_question_change_reads_the_questions
        ; test_case "only an async request change reads the async requests" `Quick
            test_only_an_async_request_change_reads_the_async_requests
        ; test_case "Skill pushes name their reads" `Quick test_skill_pushes_name_their_reads
        ; test_case "a roster push names the row or every row" `Quick
            test_a_roster_push_names_the_row_or_every_row
        ; test_case "a turns or preview push names its Keeper" `Quick
            test_a_turns_push_names_its_keeper
        ; test_case "a verification or run push reads the requests" `Quick
            test_a_verification_or_run_push_reads_the_requests
        ; test_case "a repository push reads the list" `Quick
            test_a_repository_push_reads_the_list
        ; test_case "Lane inventory pushes decode with their scope" `Quick
            test_lane_inventory_pushes_decode_with_their_scope
        ; test_case "Play room pushes share cross-machine changes" `Quick
            test_play_room_pushes_share_cross_machine_changes
        ; test_case "Memory health pushes require their Keeper" `Quick
            test_memory_health_pushes_require_their_keeper
        ; test_case "workspace memory and Play seats reach their typed consumer" `Quick
            test_workspace_memory_and_play_seats_reach_the_typed_consumer
        ; test_case "Machine live pushes name their machine" `Quick
            test_machine_live_pushes_scope_the_machine
        ; test_case "Browser observation pushes decode their exact scope" `Quick
            test_browser_observation_decodes_the_exact_scope
        ; test_case "a queue push names its Keeper" `Quick
            test_a_queue_push_names_its_keeper
        ; test_case "a connector push names its connector" `Quick
            test_a_connector_push_names_its_connector
        ; test_case "only a confirmation change reads the confirmations" `Quick
            test_only_a_confirmation_change_reads_the_confirmations
        ; test_case "only a schedule change reads the schedules" `Quick
            test_only_a_schedule_change_reads_the_schedules
        ; test_case "a fusion status frame decodes its identity strings" `Quick
            test_a_fusion_status_frame_decodes_its_identity_strings
        ; test_case "cursor commits only with a complete event" `Quick
            test_cursor_commits_only_with_a_complete_event
        ; test_case "multiline frame preserves payload and cursor" `Quick
            test_multiline_frame_preserves_payload_and_cursor
        ; test_case "a line cut by the chunk boundary is held" `Quick
            test_a_line_cut_by_the_chunk_boundary_is_held
        ; test_case "the internal runs push is read by the server's name" `Quick
            test_the_internal_runs_push_is_read_by_the_servers_name
        ; test_case "the schedule change is read by the server's name" `Quick
            test_schedule_change_is_read_by_the_servers_name
        ; test_case "the pending confirmation change is read by the server's name" `Quick
            test_pending_confirm_change_is_read_by_the_servers_name
        ; test_case "every lane resource lifecycle is read with its payload"
            `Quick test_every_lane_resource_lifecycle_is_read_with_its_payload
        ; test_case "a lane resource without a reason says so" `Quick
            test_a_lane_resource_without_a_reason_says_so
        ; test_case "an ended run carries its elapsed and error" `Quick
            test_an_ended_run_carries_its_elapsed_and_error
        ; test_case "a failed run without its error is undecodable" `Quick
            test_a_failed_run_without_its_error_is_undecodable
        ; test_case "what this build was not taught keeps its name" `Quick
            test_what_this_build_was_not_taught_keeps_its_name
        ; test_case "streaming telemetry names no agent" `Quick
            test_streaming_telemetry_names_no_agent
        ; test_case "relay subscription loss is typed" `Quick
            test_relay_subscription_loss_is_typed
        ; test_case "a frame this cannot read says why" `Quick
            test_a_frame_this_cannot_read_says_why
        ; test_case "a turn observation names the call and the completed count"
            `Quick test_a_turn_observation_names_the_call_and_the_completed_count
        ; test_case "a settle keeps its cache counts apart from absent" `Quick
            test_a_settle_keeps_its_cache_counts_apart_from_absent
        ] )
    ]
