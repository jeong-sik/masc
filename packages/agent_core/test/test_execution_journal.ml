open Alcotest
open Agent_sdk
module Internal = Agent_sdk__
module Event = Internal.Execution_event
module Journal = Internal.Execution_journal

let require_ok = function
  | Ok value -> value
  | Error error -> fail (Journal.error_to_string error)
;;

let require_started_run result = fst (require_ok result)
let require_opened_node result = fst (require_ok result)

let require_codec_ok = function
  | Ok value -> value
  | Error detail -> fail detail
;;

let serial_schedule : Tool_contract.schedule =
  { planned_index = 0
  ; batch_index = 0
  ; batch_size = 1
  ; execution_mode = Tool_contract.Serial
  }
;;

let provider_response ?(id = "response-stream-1") ?(cost_usd = Some 0.25) () =
  { Llm_provider.Types.id
  ; model = "streaming-model"
  ; stop_reason = Llm_provider.Types.EndTurn
  ; content = [ Llm_provider.Types.Text "answer" ]
  ; usage =
      Some
        { input_tokens = 11
        ; output_tokens = 22
        ; cache_creation_input_tokens = 3
        ; cache_read_input_tokens = 4
        ; cost_usd
        }
  ; telemetry = None
  }
;;

let provider_attempt ?(model_id = "test-model") ordinal =
  let config =
    Llm_provider.Provider_config.make
      ~kind:Llm_provider.Provider_kind.OpenAI_compat
      ~provider_id:"test-provider"
      ~model_id
      ~base_url:"https://provider.test"
      ()
  in
  let binding =
    Binding_identity.of_provider_config
      ~transport:(Binding_identity.transport_for_call ~injected:false)
      config
    |> require_codec_ok
  in
  require_codec_ok (Event.provider_attempt ~ordinal binding)
;;

let tool_invocation ?(planned_index = 0) name =
  Event.Tool_invocation
    { provider_tool_use_id = Some ("provider-" ^ name)
    ; tool_name = name
    ; schedule = { serial_schedule with planned_index; batch_index = planned_index }
    ; completion = Tool_contract.Continue_after_success
    }
;;

let tool_use name input =
  Llm_provider.Types.ToolUse { id = "provider-" ^ name; name; input }
;;

let tool_result name value =
  Llm_provider.Types.ToolResult
    { tool_use_id = "provider-" ^ name
    ; content = Yojson.Safe.to_string value
    ; outcome = Llm_provider.Types.Tool_succeeded
    ; json = Some value
    ; content_blocks = None
    }
;;

let external_source value = require_codec_ok (Event.External_source.of_string value)

let check_contiguous events =
  List.iteri
    (fun index event -> check int "global sequence" (index + 1) (Event.seq event))
    events
;;

let cursor_at cursor seq =
  let json = Journal.cursor_to_yojson cursor in
  match json with
  | `Assoc fields ->
    require_codec_ok
      (Journal.cursor_of_yojson
         (`Assoc (("seq", `Int seq) :: List.remove_assoc "seq" fields)))
  | _ -> fail "cursor encoder did not return an object"
;;

let open_provider_attempt
      ?(turn_ordinal = 0)
      ?(attempt_ordinal = 0)
      ?(model_id = "test-model")
      journal
      run
  =
  let agent_turn =
    require_opened_node
      (Journal.open_node
         journal
         ~run
         ~parent:(Journal.run_root run)
         ~kind:(Event.Agent_turn { ordinal = turn_ordinal }))
  in
  let attempt =
    require_opened_node
      (Journal.open_node
         journal
         ~run
         ~parent:agent_turn
         ~kind:(provider_attempt ~model_id attempt_ordinal))
  in
  agent_turn, attempt
;;

let build_recursive_run journal =
  let parent_run = require_started_run (Journal.start_run journal ~agent_name:"keeper") in
  let parent_agent_turn, parent_turn = open_provider_attempt journal parent_run in
  ignore
    (require_ok
       (Journal.update_node
          journal
          ~node:parent_turn
          (Event.Provider_event (`Assoc [ "phase", `String "started" ]))));
  let thinking =
    require_opened_node
      (Journal.open_node
         journal
         ~run:parent_run
         ~parent:parent_turn
         ~kind:(Event.Output_block { ordinal = 0; block_kind = Event.Thinking_block }))
  in
  ignore
    (require_ok
       (Journal.update_node
          journal
          ~node:thinking
          (Event.Output_delta (`Assoc [ "text", `String "inspect" ]))));
  ignore
    (require_ok
       (Journal.update_node
          journal
          ~node:thinking
          (Event.Output_snapshot
             (Llm_provider.Types.Thinking { content = "inspect source"; signature = None }))));
  ignore (require_ok (Journal.close_node journal ~node:thinking Event.Succeeded));
  let invocation =
    require_opened_node
      (Journal.open_node
         journal
         ~run:parent_run
         ~parent:parent_turn
         ~kind:(tool_invocation "read_source"))
  in
  ignore
    (require_ok
       (Journal.update_node
          journal
          ~node:invocation
          (Event.Tool_input_delta (`Assoc [ "path", `String "lib/agent.ml" ]))));
  ignore
    (require_ok
       (Journal.update_node
          journal
          ~node:invocation
          (Event.Tool_input_snapshot
             (tool_use "read_source" (`Assoc [ "path", `String "lib/agent.ml" ])))));
  let attempt =
    require_opened_node
      (Journal.open_node
         journal
         ~run:parent_run
         ~parent:invocation
         ~kind:Event.Tool_attempt)
  in
  ignore
    (require_ok
       (Journal.update_node
          journal
          ~node:attempt
          (Event.Tool_progress (`Assoc [ "bytes", `Int 512 ]))));
  let child_run =
    require_started_run
      (Journal.start_run ~parent_attempt:attempt journal ~agent_name:"reviewer")
  in
  let child_agent_turn, child_turn = open_provider_attempt journal child_run in
  ignore (require_ok (Journal.close_node journal ~node:child_turn Event.Succeeded));
  ignore (require_ok (Journal.close_node journal ~node:child_agent_turn Event.Succeeded));
  let child_finished =
    require_ok (Journal.finish_run journal ~run:child_run Event.Succeeded)
  in
  let attempt_closed =
    require_ok (Journal.close_node journal ~node:attempt Event.Succeeded)
  in
  ignore
    (require_ok
       (Journal.update_node
          ~causes:
            [ Event.Internal_event (Event.event_id attempt_closed)
            ; Event.Internal_event (Event.event_id child_finished)
            ]
          journal
          ~node:invocation
          (Event.Tool_result
             (tool_result "read_source" (`Assoc [ "review", `String "accepted" ])))));
  ignore (require_ok (Journal.close_node journal ~node:invocation Event.Succeeded));
  ignore (require_ok (Journal.close_node journal ~node:parent_turn Event.Succeeded));
  ignore (require_ok (Journal.close_node journal ~node:parent_agent_turn Event.Succeeded));
  ignore (require_ok (Journal.finish_run journal ~run:parent_run Event.Succeeded));
  parent_run, child_run
;;

let test_recursive_tree_and_global_sequence () =
  Eio_main.run
  @@ fun _env ->
  let journal = require_ok (Journal.create ()) in
  let parent_run, child_run = build_recursive_run journal in
  let events = Journal.events journal in
  check int "all events retained" 25 (List.length events);
  check_contiguous events;
  let tool_result_event =
    List.find
      (fun event ->
         match Event.payload event with
         | Event.Node_updated { update = Event.Tool_result _; _ } -> true
         | Event.Node_opened _ | Event.Node_updated _ | Event.Node_closed _ -> false)
      events
  in
  (match Event.causes tool_result_event with
   | [ Event.Internal_event attempt; Event.Internal_event child ] ->
     check bool "fan-in causes are distinct" false (Event.Event_id.equal attempt child)
   | _ -> fail "tool result did not retain attempt plus child-run fan-in");
  let after_fifteen = cursor_at (Journal.current_cursor journal) 15 in
  let page = require_ok (Journal.read_page journal ~after:after_fifteen ~limit:10 ()) in
  let tail = page.events in
  let next = page.next_cursor in
  check int "exclusive cursor" 10 (List.length tail);
  check bool "cursor order" true (List.for_all (fun event -> Event.seq event > 15) tail);
  check int "returned cursor watermark" 25 (Journal.cursor_seq next);
  let ahead = cursor_at next 26 in
  (match Journal.read_page journal ~after:ahead ~limit:1 () with
   | Error (Journal.Cursor_ahead { after_seq = 26; last_seq = 25 }) -> ()
   | _ -> fail "a cursor ahead of the journal was silently accepted");
  let foreign = Journal.beginning_cursor (require_ok (Journal.create ())) in
  (match Journal.read_page journal ~after:foreign ~limit:1 () with
   | Error Journal.Cursor_scope_mismatch -> ()
   | _ -> fail "a cursor from another journal was silently accepted");
  let expected_correlation = Event.correlation_id (List.hd events) in
  check
    bool
    "recursive runs share one execution correlation"
    true
    (List.for_all
       (fun event ->
          Event.Correlation_id.equal (Event.correlation_id event) expected_correlation)
       events);
  (match Journal.find_run journal (Journal.run_id parent_run) with
   | Some
       { status = Journal.Finished { value = Event.Succeeded; _ }
       ; parent_attempt = None
       ; _
       } -> ()
   | _ -> fail "parent run was not finished as a root run");
  match Journal.find_run journal (Journal.run_id child_run) with
  | Some
      { status = Journal.Finished { value = Event.Succeeded; _ }
      ; parent_attempt = Some _
      ; _
      } -> ()
  | _ -> fail "child run did not retain its exact attempt parent"
;;

let test_codec_roundtrip_and_exactness () =
  Eio_main.run
  @@ fun _env ->
  (match
     ( Event.classify_content_block (tool_use "classification" (`Assoc []))
     , Event.classify_content_block (tool_result "classification" (`Assoc [])) )
   with
   | Event.Tool_use_content, Event.Tool_result_content -> ()
   | _ -> fail "tool use and tool result lost their distinct structural classes");
  (match Event.classify_content_block (Llm_provider.Types.Text "output") with
   | Event.Output_content Event.Text_block -> ()
   | _ -> fail "text content did not project to a text output block");
  (match Event.External_source.of_string " test-domain" with
   | Error _ -> ()
   | Ok _ -> fail "external source accepted surrounding whitespace");
  let journal = require_ok (Journal.create ()) in
  let run, opened = require_ok (Journal.start_run journal ~agent_name:"codec") in
  let event = List.hd (Journal.events journal) in
  check bool "start_run returns its exact event" true (Event.equal opened event);
  let decoded = require_codec_ok (Event.of_json_string (Event.to_json_string event)) in
  check bool "event round-trip" true (Event.equal event decoded);
  (match
     Event.node_update_of_yojson (`Assoc [ "type", `String "unknown"; "value", `Null ])
   with
   | Error _ -> ()
   | Ok _ -> fail "unknown update type was accepted");
  let json = Event.to_yojson event in
  let with_unknown_envelope_field =
    match json with
    | `Assoc fields ->
      let envelope = List.assoc "envelope" fields in
      let envelope =
        match envelope with
        | `Assoc envelope_fields -> `Assoc (("legacy", `Bool true) :: envelope_fields)
        | _ -> fail "event envelope was not an object"
      in
      `Assoc (("envelope", envelope) :: List.remove_assoc "envelope" fields)
    | _ -> fail "execution event was not an object"
  in
  (match Event.of_yojson with_unknown_envelope_field with
   | Error _ -> ()
   | Ok _ -> fail "unknown envelope field was accepted");
  let decoded_invocation =
    let json = require_codec_ok (Event.node_kind_to_yojson (tool_invocation "pending")) in
    require_codec_ok (Event.node_kind_of_yojson json)
  in
  (match decoded_invocation with
   | Event.Tool_invocation { tool_name = "pending"; _ } -> ()
   | _ -> fail "tool invocation identity did not round-trip");
  let agent_turn, turn = open_provider_attempt journal run in
  let invocation =
    require_opened_node
      (Journal.open_node journal ~run ~parent:turn ~kind:(tool_invocation "null_input"))
  in
  ignore
    (require_ok
       (Journal.update_node
          journal
          ~node:invocation
          (Event.Tool_input_snapshot (tool_use "null_input" `Null))));
  (match Journal.find_node journal invocation with
   | Some
       { materialized =
           Journal.Tool_invocation_state
             { input = Some (Llm_provider.Types.ToolUse { input = `Null; _ }); _ }
       ; _
       } -> ()
   | _ -> fail "canonical JSON null was confused with absent input");
  let failed =
    Event.Failed
      { kind = Event.Tool_failure; detail = "expected codec test stop"; data = None }
  in
  ignore (require_ok (Journal.close_node journal ~node:invocation failed));
  ignore (require_ok (Journal.close_node journal ~node:turn Event.Succeeded));
  ignore (require_ok (Journal.close_node journal ~node:agent_turn Event.Succeeded));
  ignore (require_ok (Journal.finish_run journal ~run Event.Succeeded))
;;

let id module_id value =
  match module_id value with
  | Ok value -> value
  | Error detail -> fail detail
;;

let make_manual_event
      ~event_id
      ~run_id
      ~seq
      ?correlation_id
      ?parent_event_id
      ?causes
      payload
  =
  let correlation_id =
    Option.value correlation_id ~default:(Event.Run_id.to_string run_id)
  in
  let envelope =
    Event_envelope.make
      ~event_id:(Event.Event_id.to_string event_id)
      ~correlation_id
      ~run_id:(Event.Run_id.to_string run_id)
      ~seq
      ?parent_event_id
      ()
  in
  require_codec_ok (Event.make ?causes ~envelope payload)
;;

let test_reducer_rejects_sequence_and_unknown_parent_event () =
  let run_id = id Event.Run_id.of_string "execution-run-manual" in
  let root_id = id Event.Node_id.of_string "execution-node-manual" in
  let node =
    require_codec_ok
      (Event.make_node
         ~node_id:root_id
         ~run_id
         ~parent_node_id:None
         ~kind:(Event.Agent_run { agent_name = "manual" }))
  in
  let event_id = id Event.Event_id.of_string "execution-event-manual" in
  let seq_two = make_manual_event ~event_id ~run_id ~seq:2 (Event.Node_opened node) in
  (match Journal.Reducer.apply Journal.Reducer.empty seq_two with
   | Error (Journal.Sequence_mismatch { expected = 1; actual = 2 }) -> ()
   | _ -> fail "sequence gap was not rejected");
  let unknown_parent = "execution-event-does-not-exist" in
  let seq_one =
    make_manual_event
      ~event_id
      ~run_id
      ~seq:1
      ~parent_event_id:unknown_parent
      (Event.Node_opened node)
  in
  (match Journal.Reducer.apply Journal.Reducer.empty seq_one with
   | Error (Journal.Unknown_parent_event _) -> ()
   | _ -> fail "unknown parent event reference was not rejected");
  let unknown_cause = id Event.Event_id.of_string "execution-event-unknown-cause" in
  let dangling_cause =
    make_manual_event
      ~event_id
      ~run_id
      ~seq:1
      ~causes:[ Event.Internal_event unknown_cause ]
      (Event.Node_opened node)
  in
  match Journal.Reducer.apply Journal.Reducer.empty dangling_cause with
  | Error (Journal.Unknown_cause_event event_id)
    when Event.Event_id.equal event_id unknown_cause -> ()
  | _ -> fail "unknown typed cause event was not rejected"
;;

let test_reducer_rejects_correlation_drift () =
  let run_id = id Event.Run_id.of_string "execution-run-correlation" in
  let root_id = id Event.Node_id.of_string "execution-node-correlation" in
  let opened_id = id Event.Event_id.of_string "execution-event-correlation-opened" in
  let closed_id = id Event.Event_id.of_string "execution-event-correlation-closed" in
  let node =
    require_codec_ok
      (Event.make_node
         ~node_id:root_id
         ~run_id
         ~parent_node_id:None
         ~kind:(Event.Agent_run { agent_name = "manual" }))
  in
  let opened =
    make_manual_event
      ~event_id:opened_id
      ~run_id
      ~seq:1
      ~correlation_id:"execution-scope-one"
      ~causes:
        [ Event.External_event
            { source = external_source "test"; event_id = "external-trigger-one" }
        ]
      (Event.Node_opened node)
  in
  let state =
    match Journal.Reducer.apply Journal.Reducer.empty opened with
    | Ok state -> state
    | Error violation -> fail (Journal.show_invariant_violation violation)
  in
  let closed =
    make_manual_event
      ~event_id:closed_id
      ~run_id
      ~seq:2
      ~correlation_id:"execution-scope-two"
      ~parent_event_id:(Event.Event_id.to_string opened_id)
      (Event.Node_closed { node_id = root_id; terminal = Event.Succeeded })
  in
  match Journal.Reducer.apply state closed with
  | Error (Journal.Correlation_mismatch { expected; actual })
    when String.equal (Event.Correlation_id.to_string expected) "execution-scope-one"
         && String.equal (Event.Correlation_id.to_string actual) "execution-scope-two" ->
    ()
  | _ -> fail "execution correlation drift was accepted"
;;

let test_recursion_rejections_are_pinned () =
  (* Negative pins for the #2637 attempt-owned recursion topology: the
     admission matrix must keep rejecting flattened nesting, and the
     open-child fence must cover child RUNS, not only nested invocations.
     A wrong [true] in parent_accepts_child or a lost cross-run child
     registration would otherwise go green through the whole suite. *)
  Eio_main.run
  @@ fun _env ->
  let journal = require_ok (Journal.create ()) in
  let run = require_started_run (Journal.start_run journal ~agent_name:"neg-pins") in
  let _turn, provider_attempt = open_provider_attempt journal run in
  let invocation =
    require_opened_node
      (Journal.open_node
         journal
         ~run
         ~parent:provider_attempt
         ~kind:(tool_invocation "outer"))
  in
  ignore
    (require_ok
       (Journal.update_node
          journal
          ~node:invocation
          (Event.Tool_input_snapshot (tool_use "outer" (`Assoc [])))));
  (match
     Journal.open_node journal ~run ~parent:invocation ~kind:(tool_invocation "flat")
   with
   | Error (Journal.Invariant_violation (Journal.Invalid_parent_kind _)) -> ()
   | Ok _ -> fail "nested invocation was admitted directly under an invocation"
   | Error error -> fail (Journal.error_to_string error));
  let attempt =
    require_opened_node
      (Journal.open_node journal ~run ~parent:invocation ~kind:Event.Tool_attempt)
  in
  (match Journal.open_node journal ~run ~parent:attempt ~kind:Event.Tool_attempt with
   | Error (Journal.Invariant_violation (Journal.Invalid_parent_kind _)) -> ()
   | Ok _ -> fail "attempt was admitted directly under an attempt"
   | Error error -> fail (Journal.error_to_string error));
  let child_run =
    require_started_run
      (Journal.start_run ~parent_attempt:attempt journal ~agent_name:"child")
  in
  (match Journal.close_node journal ~node:attempt Event.Succeeded with
   | Error (Journal.Invariant_violation (Journal.Node_has_open_children _)) -> ()
   | Ok _ -> fail "attempt closed while its child run was still open"
   | Error error -> fail (Journal.error_to_string error));
  ignore (require_ok (Journal.finish_run journal ~run:child_run Event.Succeeded));
  ignore (require_ok (Journal.close_node journal ~node:attempt Event.Succeeded));
  check_contiguous (Journal.events journal)
;;

let test_open_under_closed_parent_is_parent_node_closed () =
  Eio_main.run
  @@ fun _env ->
  let journal = require_ok (Journal.create ()) in
  let run = require_started_run (Journal.start_run journal ~agent_name:"closed-parent") in
  let _agent_turn, attempt = open_provider_attempt journal run in
  ignore (require_ok (Journal.close_node journal ~node:attempt Event.Succeeded));
  match
    Journal.open_node
      journal
      ~run
      ~parent:attempt
      ~kind:(Event.Output_block { ordinal = 0; block_kind = Event.Text_block })
  with
  | Error (Journal.Invariant_violation (Journal.Parent_node_closed parent_id))
    when Event.Node_id.equal parent_id attempt -> ()
  | Ok _ -> fail "a child was opened under a closed parent"
  | Error error -> fail (Journal.error_to_string error)
;;

let test_hierarchy_and_lifecycle_rejections () =
  Eio_main.run
  @@ fun _env ->
  let journal = require_ok (Journal.create ()) in
  let run = require_started_run (Journal.start_run journal ~agent_name:"invalid") in
  let root = Journal.run_root run in
  (match
     Journal.open_node
       journal
       ~run
       ~parent:root
       ~kind:(Event.Output_block { ordinal = 0; block_kind = Event.Text_block })
   with
   | Error (Journal.Invariant_violation (Journal.Invalid_parent_kind _)) -> ()
   | result ->
     failf
       "invalid root child result: %s"
       (match result with
        | Ok _ -> "accepted"
        | Error e -> Journal.error_to_string e));
  check int "rejected open is not committed" 1 (Journal.length journal);
  let agent_turn, turn = open_provider_attempt journal run in
  (match
     Journal.open_node journal ~run ~parent:root ~kind:(Event.Agent_turn { ordinal = 0 })
   with
   | Error (Journal.Invariant_violation (Journal.Occurrence_already_opened existing))
     when Event.Node_id.equal existing agent_turn -> ()
   | Ok _ | Error _ -> fail "duplicate turn occurrence was not rejected");
  (match Journal.open_node journal ~run ~parent:agent_turn ~kind:(provider_attempt 0) with
   | Error (Journal.Invariant_violation (Journal.Occurrence_already_opened existing))
     when Event.Node_id.equal existing turn -> ()
   | Ok _ | Error _ -> fail "duplicate provider occurrence was not rejected");
  (match
     Journal.update_node journal ~node:turn (Event.Output_delta (`String "wrong"))
   with
   | Error (Journal.Invariant_violation (Journal.Invalid_update_for_node _)) -> ()
   | _ -> fail "invalid update was not rejected");
  let output =
    require_opened_node
      (Journal.open_node
         journal
         ~run
         ~parent:turn
         ~kind:(Event.Output_block { ordinal = 0; block_kind = Event.Text_block }))
  in
  (match Journal.close_node journal ~node:turn Event.Succeeded with
   | Error (Journal.Invariant_violation (Journal.Node_has_open_children _)) -> ()
   | _ -> fail "node with an open child was closed");
  (match Journal.start_run ~parent_attempt:turn journal ~agent_name:"bad-child" with
   | Error (Journal.Invariant_violation (Journal.Child_run_parent_not_tool_attempt _)) ->
     ()
   | _ -> fail "child run under a provider turn was accepted");
  (match Journal.close_node journal ~node:root Event.Succeeded with
   | Error (Journal.Invariant_violation (Journal.Root_must_use_finish_run _)) -> ()
   | _ -> fail "root was closed without finish_run");
  (match Journal.close_node journal ~node:output Event.Succeeded with
   | Error (Journal.Invariant_violation (Journal.Output_snapshot_not_materialized _)) ->
     ()
   | _ -> fail "an output block succeeded without a canonical snapshot");
  (match
     Journal.update_node
       journal
       ~node:output
       (Event.Output_snapshot (tool_result "streamed" (`String "not-output")))
   with
   | Error (Journal.Invariant_violation (Journal.Output_snapshot_kind_mismatch _)) -> ()
   | _ -> fail "a tool result was accepted as an output block snapshot");
  ignore
    (require_ok
       (Journal.update_node
          journal
          ~node:output
          (Event.Output_snapshot (Llm_provider.Types.Text "materialized"))));
  ignore (require_ok (Journal.close_node journal ~node:output Event.Succeeded));
  let invocation =
    require_opened_node
      (Journal.open_node journal ~run ~parent:turn ~kind:(tool_invocation "streamed"))
  in
  (match
     Journal.open_node
       journal
       ~run
       ~parent:turn
       ~kind:(tool_invocation "same-planned-index")
   with
   | Error
       (Journal.Invariant_violation
          (Journal.Tool_occurrence_conflict { parent; planned_index = 0; existing }))
     when Event.Node_id.equal parent turn && Event.Node_id.equal existing invocation -> ()
   | Ok _ | Error _ -> fail "duplicate Tool occurrence was not rejected");
  (match
     Journal.update_node
       journal
       ~node:invocation
       (Event.Tool_result (tool_result "streamed" (`String "early")))
   with
   | Error (Journal.Invariant_violation (Journal.Tool_input_not_materialized _)) -> ()
   | _ -> fail "tool result was accepted before canonical input");
  (match Journal.open_node journal ~run ~parent:invocation ~kind:Event.Tool_attempt with
   | Error (Journal.Invariant_violation (Journal.Tool_input_not_materialized _)) -> ()
   | _ -> fail "tool attempt was opened before canonical input");
  (match Journal.close_node journal ~node:invocation Event.Succeeded with
   | Error (Journal.Invariant_violation (Journal.Tool_input_not_materialized _)) -> ()
   | _ -> fail "tool invocation succeeded without canonical input");
  (match
     Journal.update_node
       journal
       ~node:invocation
       (Event.Tool_input_snapshot (Llm_provider.Types.Text "not a tool use"))
   with
   | Error (Journal.Invariant_violation (Journal.Tool_input_snapshot_not_tool_use _)) ->
     ()
   | _ -> fail "non-tool-use content was accepted as a tool input snapshot");
  (match
     Journal.update_node
       journal
       ~node:invocation
       (Event.Tool_input_snapshot (tool_use "another_tool" (`Assoc [])))
   with
   | Error (Journal.Invariant_violation (Journal.Tool_input_snapshot_identity_mismatch _))
     -> ()
   | _ -> fail "a mismatched tool use was accepted as invocation input");
  ignore
    (require_ok
       (Journal.update_node
          journal
          ~node:invocation
          (Event.Tool_input_snapshot (tool_use "streamed" (`Assoc [ "value", `Int 1 ])))));
  (match
     Journal.update_node
       journal
       ~node:invocation
       (Event.Tool_input_snapshot (tool_use "streamed" (`Assoc [ "value", `Int 2 ])))
   with
   | Error (Journal.Invariant_violation (Journal.Tool_input_already_materialized _)) -> ()
   | _ -> fail "a second canonical tool input snapshot was accepted");
  (match
     Journal.update_node
       journal
       ~node:invocation
       (Event.Tool_input_delta (`String "late"))
   with
   | Error (Journal.Invariant_violation (Journal.Tool_input_delta_after_snapshot _)) -> ()
   | _ -> fail "tool input delta was accepted after its snapshot");
  (match Journal.close_node journal ~node:invocation Event.Succeeded with
   | Error (Journal.Invariant_violation (Journal.Tool_result_not_materialized _)) -> ()
   | _ -> fail "tool invocation succeeded without a canonical result");
  (match
     Journal.update_node
       journal
       ~node:invocation
       (Event.Tool_result (Llm_provider.Types.Text "not a tool result"))
   with
   | Error (Journal.Invariant_violation (Journal.Tool_result_snapshot_not_tool_result _))
     -> ()
   | _ -> fail "non-tool-result content was accepted as a tool result snapshot");
  (match
     Journal.update_node
       journal
       ~node:invocation
       (Event.Tool_result (tool_result "another_tool" (`Assoc [])))
   with
   | Error
       (Journal.Invariant_violation (Journal.Tool_result_snapshot_identity_mismatch _)) ->
     ()
   | _ -> fail "a mismatched tool result was accepted by an invocation");
  let attempt =
    require_opened_node
      (Journal.open_node journal ~run ~parent:invocation ~kind:Event.Tool_attempt)
  in
  (match
     Journal.start_run ~parent_attempt:invocation journal ~agent_name:"merged-retry"
   with
   | Error (Journal.Invariant_violation (Journal.Child_run_parent_not_tool_attempt _)) ->
     ()
   | _ -> fail "child run was attached to a logical invocation instead of an attempt");
  let nested_invocation =
    require_opened_node
      (Journal.open_node journal ~run ~parent:attempt ~kind:(tool_invocation "nested"))
  in
  (match Journal.close_node journal ~node:attempt Event.Succeeded with
   | Error (Journal.Invariant_violation (Journal.Node_has_open_children _)) -> ()
   | _ -> fail "tool attempt closed while exact nested work remained open");
  ignore
    (require_ok
       (Journal.close_node
          journal
          ~node:nested_invocation
          (Event.Failed
             { kind = Event.Tool_failure; detail = "nested tool rejected"; data = None })));
  (match
     Journal.update_node
       journal
       ~node:invocation
       (Event.Tool_result (tool_result "streamed" (`Assoc [ "value", `Int 1 ])))
   with
   | Error (Journal.Invariant_violation (Journal.Tool_result_while_children_open _)) -> ()
   | _ -> fail "tool result was accepted while an attempt was open");
  ignore (require_ok (Journal.close_node journal ~node:attempt Event.Succeeded));
  ignore
    (require_ok
       (Journal.update_node
          journal
          ~node:invocation
          (Event.Tool_result (tool_result "streamed" (`Assoc [ "value", `Int 1 ])))));
  (match
     Journal.update_node
       journal
       ~node:invocation
       (Event.Tool_result (tool_result "streamed" (`Assoc [ "value", `Int 2 ])))
   with
   | Error (Journal.Invariant_violation (Journal.Tool_result_already_materialized _)) ->
     ()
   | _ -> fail "a second canonical tool result was accepted");
  (match Journal.open_node journal ~run ~parent:invocation ~kind:Event.Tool_attempt with
   | Error (Journal.Invariant_violation (Journal.Child_after_tool_result _)) -> ()
   | _ -> fail "a tool attempt was opened after the canonical result");
  ignore (require_ok (Journal.close_node journal ~node:invocation Event.Succeeded));
  let failed_invocation =
    require_opened_node
      (Journal.open_node
         journal
         ~run
         ~parent:turn
         ~kind:(tool_invocation ~planned_index:1 "parse_failure"))
  in
  ignore
    (require_ok
       (Journal.close_node
          journal
          ~node:failed_invocation
          (Event.Failed
             { kind = Event.Protocol_failure
             ; detail = "tool input was not valid JSON"
             ; data = None
             })));
  let invocation_without_provider_id =
    require_opened_node
      (Journal.open_node
         journal
         ~run
         ~parent:turn
         ~kind:
           (Event.Tool_invocation
              { provider_tool_use_id = None
              ; tool_name = "late_identity"
              ; schedule = { serial_schedule with planned_index = 2; batch_index = 2 }
              ; completion = Tool_contract.Continue_after_success
              }))
  in
  let canonical_tool_use =
    Llm_provider.Types.ToolUse
      { id = "canonical-late-identity"; name = "late_identity"; input = `Assoc [] }
  in
  ignore
    (require_ok
       (Journal.update_node
          journal
          ~node:invocation_without_provider_id
          (Event.Tool_input_snapshot canonical_tool_use)));
  (match
     Journal.update_node
       journal
       ~node:invocation_without_provider_id
       (Event.Tool_result (tool_result "late_identity" (`Assoc [])))
   with
   | Error
       (Journal.Invariant_violation (Journal.Tool_result_snapshot_identity_mismatch _)) ->
     ()
   | _ -> fail "tool result ignored the canonical input correlation identity");
  let matching_tool_result =
    Llm_provider.Types.ToolResult
      { tool_use_id = "canonical-late-identity"
      ; content = "{}"
      ; outcome = Llm_provider.Types.Tool_succeeded
      ; json = Some (`Assoc [])
      ; content_blocks = None
      }
  in
  ignore
    (require_ok
       (Journal.update_node
          journal
          ~node:invocation_without_provider_id
          (Event.Tool_result matching_tool_result)));
  ignore
    (require_ok
       (Journal.close_node journal ~node:invocation_without_provider_id Event.Succeeded));
  ignore (require_ok (Journal.close_node journal ~node:turn Event.Succeeded));
  ignore (require_ok (Journal.close_node journal ~node:agent_turn Event.Succeeded));
  ignore (require_ok (Journal.finish_run journal ~run Event.Succeeded))
;;

let test_output_snapshot_is_terminal_for_output_updates () =
  Eio_main.run
  @@ fun _env ->
  let journal = require_ok (Journal.create ()) in
  let run =
    require_started_run (Journal.start_run journal ~agent_name:"output-snapshot")
  in
  let agent_turn, turn = open_provider_attempt journal run in
  let output =
    require_opened_node
      (Journal.open_node
         journal
         ~run
         ~parent:turn
         ~kind:(Event.Output_block { ordinal = 0; block_kind = Event.Text_block }))
  in
  ignore
    (require_ok
       (Journal.update_node journal ~node:output (Event.Output_delta (`String "a"))));
  ignore
    (require_ok
       (Journal.update_node
          journal
          ~node:output
          (Event.Output_snapshot (Llm_provider.Types.Text "answer"))));
  (match
     Journal.update_node
       journal
       ~node:output
       (Event.Output_snapshot (Llm_provider.Types.Text "replacement"))
   with
   | Error (Journal.Invariant_violation (Journal.Output_snapshot_already_materialized _))
     -> ()
   | _ -> fail "a second output snapshot was accepted");
  (match
     Journal.update_node journal ~node:output (Event.Output_delta (`String "late"))
   with
   | Error (Journal.Invariant_violation (Journal.Output_delta_after_snapshot _)) -> ()
   | _ -> fail "an output delta was accepted after its snapshot");
  ignore (require_ok (Journal.close_node journal ~node:output Event.Succeeded));
  ignore (require_ok (Journal.close_node journal ~node:turn Event.Succeeded));
  ignore (require_ok (Journal.close_node journal ~node:agent_turn Event.Succeeded));
  ignore (require_ok (Journal.finish_run journal ~run Event.Succeeded))
;;

let test_streaming_provider_identity_and_projection () =
  Eio_main.run
  @@ fun _env ->
  let journal = require_ok (Journal.create ()) in
  let run =
    require_started_run (Journal.start_run journal ~agent_name:"streaming-projection")
  in
  let agent_turn =
    require_opened_node
      (Journal.open_node
         journal
         ~run
         ~parent:(Journal.run_root run)
         ~kind:(Event.Agent_turn { ordinal = 0 }))
  in
  let attempt, opened =
    require_ok
      (Journal.open_node
         journal
         ~run
         ~parent:agent_turn
         ~kind:(provider_attempt ~model_id:"streaming-model" 0))
  in
  (match Event.payload opened with
   | Event.Node_opened node when Event.Node_id.equal (Event.node_id node) attempt -> ()
   | _ -> fail "open_node did not return its exact opened event");
  let response = provider_response () in
  ignore
    (require_ok
       (Journal.update_node
          journal
          ~node:attempt
          (Event.Provider_event (`Assoc [ "phase", `String "headers" ]))));
  ignore
    (require_ok
       (Journal.update_node
          journal
          ~node:attempt
          (Event.Provider_response_snapshot response)));
  (match
     Journal.update_node
       journal
       ~node:attempt
       (Event.Provider_response_snapshot (provider_response ~id:"response-stream-2" ()))
   with
   | Error
       (Journal.Invariant_violation (Journal.Provider_response_already_materialized _)) ->
     ()
   | _ -> fail "a second provider response snapshot was accepted");
  let output =
    require_opened_node
      (Journal.open_node
         journal
         ~run
         ~parent:attempt
         ~kind:(Event.Output_block { ordinal = 0; block_kind = Event.Text_block }))
  in
  ignore
    (require_ok
       (Journal.update_node journal ~node:output (Event.Output_delta (`String "a"))));
  ignore
    (require_ok
       (Journal.update_node
          journal
          ~node:output
          (Event.Output_snapshot (Llm_provider.Types.Text "answer"))));
  ignore (require_ok (Journal.close_node journal ~node:output Event.Succeeded));
  ignore (require_ok (Journal.close_node journal ~node:attempt Event.Succeeded));
  let fallback_attempt =
    require_opened_node
      (Journal.open_node
         journal
         ~run
         ~parent:agent_turn
         ~kind:(provider_attempt ~model_id:"streaming-model" 1))
  in
  check
    bool
    "attempt node identity is occurrence identity"
    false
    (Event.Node_id.equal attempt fallback_attempt);
  ignore
    (require_ok
       (Journal.close_node
          journal
          ~node:fallback_attempt
          (Event.Failed
             { kind = Event.Provider_failure
             ; detail = "fallback attempt not selected"
             ; data = None
             })));
  ignore (require_ok (Journal.close_node journal ~node:agent_turn Event.Succeeded));
  ignore (require_ok (Journal.finish_run journal ~run Event.Succeeded));
  (match Journal.find_node journal (Journal.run_root run) with
   | Some { children = [ { value = child; _ } ]; _ }
     when Event.Node_id.equal (Event.node_id child) agent_turn -> ()
   | _ -> fail "run projection lost its logical agent-turn child");
  (match Journal.find_node journal agent_turn with
   | Some
       { children = [ { value = first; _ }; { value = second; _ } ]
       ; materialized = Journal.Agent_turn_state
       ; _
       }
     when Event.Node_id.equal (Event.node_id first) attempt
          && Event.Node_id.equal (Event.node_id second) fallback_attempt -> ()
   | _ -> fail "logical agent turn lost ordered provider attempts");
  (match Journal.find_node journal attempt with
   | Some
       { status = Journal.Closed { value = Event.Succeeded; _ }
       ; updates =
           [ { value = Event.Provider_event _; _ }
           ; { value = Event.Provider_response_snapshot update_response; _ }
           ]
       ; children = [ { value = child; _ } ]
       ; materialized =
           Journal.Provider_attempt_state { response = Some materialized_response }
       ; _
       }
     when Event.Node_id.equal (Event.node_id child) output
          && update_response = response
          && materialized_response = response -> ()
   | _ -> fail "provider attempt projection lost updates or its output child");
  match Journal.find_node journal output with
  | Some
      { status = Journal.Closed { value = Event.Succeeded; _ }
      ; updates =
          [ { value = Event.Output_delta _; _ }; { value = Event.Output_snapshot _; _ } ]
      ; children = []
      ; materialized =
          Journal.Output_block_state
            { snapshot = Some (Llm_provider.Types.Text "answer") }
      ; _
      } -> ()
  | _ -> fail "output projection lost its chronological updates"
;;

let test_json_terminal_and_id_boundaries () =
  Eio_main.run
  @@ fun _env ->
  let journal = require_ok (Journal.create ()) in
  (match Journal.start_run journal ~agent_name:" \t\n" with
   | Error (Journal.Invalid_argument _) -> ()
   | _ -> fail "whitespace-only agent name entered the journal");
  check int "invalid agent name did not advance journal" 0 (Journal.length journal);
  let run = require_started_run (Journal.start_run journal ~agent_name:"validation") in
  let agent_turn, turn = open_provider_attempt journal run in
  let later_batch : Tool_contract.schedule =
    { planned_index = 0
    ; batch_index = 2
    ; batch_size = 1
    ; execution_mode = Tool_contract.Serial
    }
  in
  let later_batch_kind =
    Event.Tool_invocation
      { provider_tool_use_id = Some "provider-later-batch"
      ; tool_name = "valid_tool"
      ; schedule = later_batch
      ; completion = Tool_contract.Continue_after_success
      }
  in
  (match Event.node_kind_to_yojson later_batch_kind with
   | Error message -> fail ("valid later batch was rejected: " ^ message)
   | Ok json ->
     (match Event.node_kind_of_yojson json with
      | Ok (Event.Tool_invocation { schedule; _ }) ->
        check int "later batch ordinal roundtrip" 2 schedule.batch_index;
        check int "batch size roundtrip" 1 schedule.batch_size
      | Ok _ | Error _ -> fail "valid later batch did not roundtrip"));
  let expect_invalid_node_kind kind =
    match Event.node_kind_to_yojson kind with
    | Error _ -> ()
    | Ok _ -> fail "whitespace-only node identity passed the public codec"
  in
  expect_invalid_node_kind (Event.Agent_run { agent_name = "  " });
  expect_invalid_node_kind
    (Event.Tool_invocation
       { provider_tool_use_id = None
       ; tool_name = " \t"
       ; schedule = serial_schedule
       ; completion = Tool_contract.Continue_after_success
       });
  let exact_provider_id = " \n" in
  let exact_provider_kind =
    Event.Tool_invocation
      { provider_tool_use_id = Some exact_provider_id
      ; tool_name = "valid_tool"
      ; schedule = serial_schedule
      ; completion = Tool_contract.Continue_after_success
      }
  in
  (match Event.node_kind_to_yojson exact_provider_kind with
   | Error _ -> fail "opaque provider tool id did not encode"
   | Ok json ->
     (match Event.node_kind_of_yojson json with
      | Ok (Event.Tool_invocation { provider_tool_use_id = Some decoded; _ }) ->
        check string "provider tool id roundtrip is exact" exact_provider_id decoded
      | Ok _ | Error _ -> fail "opaque provider tool id did not roundtrip exactly"));
  let opaque_tool_use =
    Llm_provider.Types.ToolUse { id = " \t"; name = "valid_tool"; input = `Assoc [] }
  in
  let opaque_tool_result =
    Llm_provider.Types.ToolResult
      { tool_use_id = "\n "
      ; content = "ok"
      ; outcome = Llm_provider.Types.Tool_succeeded
      ; json = None
      ; content_blocks = None
      }
  in
  List.iter
    (fun update ->
       match Event.node_update_to_yojson update with
       | Error _ -> fail "opaque content-block provider id did not encode"
       | Ok json ->
         (match Event.node_update_of_yojson json with
          | Ok decoded when decoded = update -> ()
          | Ok _ | Error _ -> fail "opaque content-block provider id changed"))
    [ Event.Tool_input_snapshot opaque_tool_use; Event.Tool_result opaque_tool_result ];
  let before_invalid_response = Journal.length journal in
  let invalid_response = provider_response ~cost_usd:(Some nan) () in
  (match
     Journal.update_node
       journal
       ~node:turn
       (Event.Provider_response_snapshot invalid_response)
   with
   | Error (Journal.Invalid_event _) -> ()
   | _ -> fail "non-finite provider response snapshot entered the journal");
  check
    int
    "invalid provider response did not advance journal"
    before_invalid_response
    (Journal.length journal);
  let before_invalid_updates = Journal.length journal in
  let invalid_json_values = [ `Float nan; `Intlit "not-a-json-integer" ] in
  List.iter
    (fun value ->
       match Journal.update_node journal ~node:turn (Event.Provider_event value) with
       | Error (Journal.Invalid_event _) -> ()
       | _ -> fail "non-serializable provider JSON entered the in-memory journal")
    invalid_json_values;
  check
    int
    "invalid JSON did not advance in-memory journal"
    before_invalid_updates
    (Journal.length journal);
  let invalid_payload = `Assoc [ "nested", `List [ `Float infinity ] ] in
  let invalid_output =
    Llm_provider.Types.ReasoningDetails
      { reasoning_content = None; details = [ { raw = invalid_payload; text = None } ] }
  in
  let invalid_tool_input =
    Llm_provider.Types.ToolUse
      { id = "provider-invalid"; name = "invalid"; input = invalid_payload }
  in
  let invalid_tool_result =
    Llm_provider.Types.ToolResult
      { tool_use_id = "provider-invalid"
      ; content = "valid"
      ; outcome = Llm_provider.Types.Tool_succeeded
      ; json = Some invalid_payload
      ; content_blocks = None
      }
  in
  let invalid_updates =
    [ Event.Provider_event invalid_payload
    ; Event.Output_delta invalid_payload
    ; Event.Output_snapshot invalid_output
    ; Event.Tool_input_delta invalid_payload
    ; Event.Tool_input_snapshot invalid_tool_input
    ; Event.Tool_progress invalid_payload
    ; Event.Tool_result invalid_tool_result
    ]
  in
  List.iter
    (fun update ->
       let envelope =
         Event_envelope.make
           ~event_id:
             (Event.Event_id.to_string (require_codec_ok (Event.Event_id.fresh ())))
           ~correlation_id:(Event.Run_id.to_string (Journal.run_id run))
           ~run_id:(Event.Run_id.to_string (Journal.run_id run))
           ~seq:1
           ()
       in
       match Event.make ~envelope (Event.Node_updated { node_id = turn; update }) with
       | Error _ -> ()
       | Ok _ -> fail "an opaque non-finite JSON update passed Event.make")
    invalid_updates;
  (match
     Event.node_update_of_yojson
       (`Assoc [ "type", `String "provider_event"; "value", `Float nan ])
   with
   | Error _ -> ()
   | Ok _ -> fail "non-finite JSON passed the node update decoder");
  (match
     Event.node_update_of_yojson
       (`Assoc
           [ "type", `String "output_snapshot"
           ; ( "value"
             , `Assoc
                 [ "type", `String "text"
                 ; "text", `String "answer"
                 ; "unknown", `Bool true
                 ] )
           ])
   with
   | Error _ -> ()
   | Ok _ -> fail "unknown canonical snapshot field passed the closed decoder");
  (match Event.node_update_to_yojson (Event.Tool_input_snapshot invalid_tool_input) with
   | Error _ -> ()
   | Ok _ -> fail "non-finite JSON passed the public node update encoder");
  let non_lossless_tool_result =
    Llm_provider.Types.ToolResult
      { tool_use_id = "provider-non-lossless"
      ; content = "{\"value\":1}"
      ; outcome = Llm_provider.Types.Tool_succeeded
      ; json = None
      ; content_blocks = None
      }
  in
  (match Event.node_update_to_yojson (Event.Tool_result non_lossless_tool_result) with
   | Error _ -> ()
   | Ok _ -> fail "a non-lossless canonical tool result was silently normalized");
  let output =
    require_opened_node
      (Journal.open_node
         journal
         ~run
         ~parent:turn
         ~kind:(Event.Output_block { ordinal = 0; block_kind = Event.Text_block }))
  in
  let expect_invalid_terminal terminal =
    match Journal.close_node journal ~node:output terminal with
    | Error (Journal.Invalid_event _) -> ()
    | _ -> fail "invalid terminal payload was committed"
  in
  expect_invalid_terminal
    (Event.Failed { kind = Event.Protocol_failure; detail = " \t\n"; data = None });
  expect_invalid_terminal
    (Event.Failed
       { kind = Event.Protocol_failure
       ; detail = "provider returned invalid data"
       ; data = Some invalid_payload
       });
  expect_invalid_terminal (Event.Cancelled { reason = None; data = None });
  expect_invalid_terminal (Event.Cancelled { reason = Some "  "; data = None });
  expect_invalid_terminal
    (Event.Cancelled { reason = Some "provider cancelled"; data = Some (`Float nan) });
  (match
     Event.terminal_of_yojson
       (`Assoc
           [ "type", `String "failed"
           ; ( "failure"
             , `Assoc
                 [ "kind", `String "protocol"; "detail", `String "  "; "data", `Null ] )
           ])
   with
   | Error _ -> ()
   | Ok _ -> fail "whitespace-only failure passed the terminal decoder");
  ignore
    (require_ok
       (Journal.close_node
          journal
          ~node:output
          (Event.Cancelled { reason = Some "operator requested stop"; data = None })));
  ignore (require_ok (Journal.close_node journal ~node:turn Event.Succeeded));
  ignore (require_ok (Journal.close_node journal ~node:agent_turn Event.Succeeded));
  ignore (require_ok (Journal.finish_run journal ~run Event.Succeeded));
  let expect_prefix_only_rejected result =
    match result with
    | Error _ -> ()
    | Ok _ -> fail "prefix-only execution identifier was accepted"
  in
  expect_prefix_only_rejected (Event.Event_id.of_string "execution-event-");
  expect_prefix_only_rejected (Event.Run_id.of_string "execution-run-");
  expect_prefix_only_rejected (Event.Node_id.of_string "execution-node-")
;;

let test_terminal_certificate_preserves_payload () =
  let run_id = id Event.Run_id.of_string "execution-run-certified-terminal" in
  let node_id = id Event.Node_id.of_string "execution-node-certified-terminal" in
  let terminal =
    Event.Failed
      { kind = Event.Protocol_failure
      ; detail = "provider returned a typed protocol failure"
      ; data = Some (`Assoc [ "wire_code", `String "invalid_frame" ])
      }
  in
  let certified = require_codec_ok (Event.validate_terminal terminal) in
  let payload = Event.close_payload ~node_id certified in
  let envelope =
    Event_envelope.make
      ~event_id:(Event.Event_id.to_string (require_codec_ok (Event.Event_id.fresh ())))
      ~correlation_id:"certified-terminal-test"
      ~run_id:(Event.Run_id.to_string run_id)
      ~seq:1
      ()
  in
  let event = require_codec_ok (Event.make_validated ~envelope payload) in
  match Event.payload event with
  | Event.Node_closed { node_id = actual_node_id; terminal = actual_terminal } ->
    check
      bool
      "certificate retains target node identity"
      true
      (Event.Node_id.equal actual_node_id node_id);
    check
      string
      "certificate retains the exact terminal payload"
      (Yojson.Safe.to_string (require_codec_ok (Event.terminal_to_yojson terminal)))
      (Yojson.Safe.to_string
         (require_codec_ok (Event.terminal_to_yojson actual_terminal)))
  | Event.Node_opened _ | Event.Node_updated _ ->
    fail "terminal certificate produced a non-close payload"
;;

let test_one_top_level_run_per_journal () =
  Eio_main.run
  @@ fun _env ->
  let journal = require_ok (Journal.create ()) in
  let run = require_started_run (Journal.start_run journal ~agent_name:"root") in
  let expect_existing_root = function
    | Error (Journal.Invariant_violation Journal.Top_level_run_already_exists) -> ()
    | Error error -> fail (Journal.error_to_string error)
    | Ok _ -> fail "a second top-level run was accepted"
  in
  expect_existing_root (Journal.start_run journal ~agent_name:"second-root");
  check int "rejected root is not committed" 1 (Journal.length journal);
  ignore (require_ok (Journal.finish_run journal ~run Event.Succeeded));
  expect_existing_root (Journal.start_run journal ~agent_name:"root-after-finish");
  check int "finished scope is not reused" 2 (Journal.length journal)
;;

let test_abort_run_closes_recursive_subtree_atomically () =
  Eio_main.run
  @@ fun _env ->
  let journal = require_ok (Journal.create ()) in
  let run = require_started_run (Journal.start_run journal ~agent_name:"abort-root") in
  let _agent_turn, turn = open_provider_attempt journal run in
  let output =
    require_opened_node
      (Journal.open_node
         journal
         ~run
         ~parent:turn
         ~kind:(Event.Output_block { ordinal = 0; block_kind = Event.Thinking_block }))
  in
  ignore
    (require_ok
       (Journal.update_node journal ~node:output (Event.Output_delta (`String "partial"))));
  let invocation =
    require_opened_node
      (Journal.open_node journal ~run ~parent:turn ~kind:(tool_invocation "delegate"))
  in
  ignore
    (require_ok
       (Journal.update_node
          journal
          ~node:invocation
          (Event.Tool_input_snapshot
             (tool_use "delegate" (`Assoc [ "task", `String "review" ])))));
  let attempt =
    require_opened_node
      (Journal.open_node journal ~run ~parent:invocation ~kind:Event.Tool_attempt)
  in
  let child =
    require_started_run
      (Journal.start_run ~parent_attempt:attempt journal ~agent_name:"child")
  in
  let _child_agent_turn, child_turn = open_provider_attempt journal child in
  let before_rejected_success = Journal.length journal in
  (match Journal.abort_run journal ~run Event.Succeeded with
   | Error (Journal.Invalid_argument _) -> ()
   | _ -> fail "abort_run accepted a successful terminal");
  check int "rejected abort is atomic" before_rejected_success (Journal.length journal);
  let invalid_terminal =
    Event.Failed
      { kind = Event.Protocol_failure
      ; detail = "provider returned invalid terminal data"
      ; data = Some (`Assoc [ "nested", `List [ `String "valid-prefix"; `Float nan ] ])
      }
  in
  let before_invalid_terminal = Journal.length journal in
  (match Journal.abort_run journal ~run invalid_terminal with
   | Error (Journal.Invalid_event _) -> ()
   | _ -> fail "abort_run accepted invalid terminal JSON");
  check
    int
    "invalid abort terminal leaves sequence and state unchanged"
    before_invalid_terminal
    (Journal.length journal);
  let terminal =
    Event.Cancelled { reason = Some "owning fiber cancelled"; data = None }
  in
  let cancellation_trigger =
    Event.External_event
      { source = external_source "test-runtime"; event_id = "cancel-signal-1" }
  in
  let closed =
    require_ok (Journal.abort_run ~causes:[ cancellation_trigger ] journal ~run terminal)
  in
  check int "every open recursive node was closed" 9 (List.length closed);
  let root_closed = List.hd (List.rev closed) in
  (match Event.causes root_closed with
   | [ Event.External_event _; Event.Internal_event child_terminal ] ->
     check
       bool
       "abort root records its direct child terminal cause"
       true
       (List.exists
          (fun event -> Event.Event_id.equal (Event.event_id event) child_terminal)
          closed)
   | _ -> fail "abort root did not retain trigger plus direct child fan-in");
  check_contiguous (Journal.events journal);
  let check_cancelled label node_id =
    match Journal.find_node journal node_id with
    | Some { status = Journal.Closed { value = Event.Cancelled _; _ }; _ } -> ()
    | _ -> fail (label ^ " remained open after abort")
  in
  check_cancelled "output" output;
  check_cancelled "child turn" child_turn;
  (match Journal.find_run journal (Journal.run_id child) with
   | Some { status = Journal.Finished { value = Event.Cancelled _; _ }; _ } -> ()
   | _ -> fail "child run remained running after parent abort");
  match Journal.find_run journal (Journal.run_id run) with
  | Some { status = Journal.Finished { value = Event.Cancelled _; _ }; _ } -> ()
  | _ -> fail "top-level run remained running after abort"
;;

let test_abort_run_handles_deep_recursive_composition_iteratively () =
  Eio_main.run
  @@ fun _env ->
  let journal = require_ok (Journal.create ()) in
  let beginning = Journal.beginning_cursor journal in
  let root = require_started_run (Journal.start_run journal ~agent_name:"deep-root") in
  let current_run = ref root in
  let deep_chain_depth = 2048 in
  for index = 0 to deep_chain_depth - 1 do
    let run = !current_run in
    let _agent_turn, turn = open_provider_attempt ~turn_ordinal:index journal run in
    let invocation =
      require_opened_node
        (Journal.open_node
           journal
           ~run
           ~parent:turn
           ~kind:(tool_invocation ("deep-" ^ string_of_int index)))
    in
    ignore
      (require_ok
         (Journal.update_node
            journal
            ~node:invocation
            (Event.Tool_input_snapshot
               (tool_use ("deep-" ^ string_of_int index) (`Assoc [ "depth", `Int index ])))));
    let attempt =
      require_opened_node
        (Journal.open_node journal ~run ~parent:invocation ~kind:Event.Tool_attempt)
    in
    current_run
    := require_started_run
         (Journal.start_run
            ~parent_attempt:attempt
            journal
            ~agent_name:("deep-agent-" ^ string_of_int index))
  done;
  let terminal =
    Event.Cancelled { reason = Some "deep composition cancelled"; data = None }
  in
  let peer_ready, resolve_peer_ready = Eio.Promise.create () in
  let abort_result = ref None in
  let peer_observed_abort_in_progress = ref false in
  Eio.Fiber.both
    (fun () ->
       Eio.Promise.await peer_ready;
       abort_result := Some (Journal.abort_run journal ~run:root terminal))
    (fun () ->
       Eio.Promise.resolve resolve_peer_ready ();
       Eio.Fiber.yield ();
       peer_observed_abort_in_progress := Option.is_none !abort_result);
  check
    bool
    "unrelated fiber progresses before deep abort publishes"
    true
    !peer_observed_abort_in_progress;
  let closed =
    match !abort_result with
    | Some result -> require_ok result
    | None -> fail "deep abort fiber returned without a result"
  in
  check
    int
    "every deep recursive node closed"
    (1 + (5 * deep_chain_depth))
    (List.length closed);
  let page =
    require_ok
      (Journal.read_page journal ~after:beginning ~limit:(Journal.length journal) ())
  in
  check
    int
    "deep journal cursor is exact"
    (List.length page.events)
    (Journal.cursor_seq page.next_cursor)
;;

let test_cancelled_abort_does_not_publish_a_partial_batch () =
  Eio_main.run
  @@ fun _env ->
  let journal = require_ok (Journal.create ()) in
  let run = require_started_run (Journal.start_run journal ~agent_name:"abort-race") in
  let _agent_turn, attempt = open_provider_attempt journal run in
  let output =
    require_opened_node
      (Journal.open_node
         journal
         ~run
         ~parent:attempt
         ~kind:(Event.Output_block { ordinal = 0; block_kind = Event.Thinking_block }))
  in
  let terminal = Event.Cancelled { reason = Some "test cancellation"; data = None } in
  let before = Journal.length journal in
  let cancelled =
    match
      Eio.Cancel.sub (fun cancellation ->
        Eio.Cancel.cancel cancellation Exit;
        ignore (Journal.abort_run journal ~run terminal);
        false)
    with
    | value -> value
    | exception Eio.Cancel.Cancelled Exit -> true
    | exception exn -> raise exn
  in
  check bool "cancelled abort exits" true cancelled;
  check int "cancelled abort publishes no prefix" before (Journal.length journal);
  ignore
    (require_ok
       (Journal.update_node
          journal
          ~node:output
          (Event.Output_delta (`String "after-cancellation"))));
  let closed = require_ok (Journal.abort_run journal ~run terminal) in
  check int "later abort closes one four-node provider path" 4 (List.length closed);
  check_contiguous (Journal.events journal)
;;

let test_concurrent_updates_keep_one_sequence () =
  Eio_main.run
  @@ fun _env ->
  let journal = require_ok (Journal.create ()) in
  let run = require_started_run (Journal.start_run journal ~agent_name:"concurrent") in
  let _agent_turn, turn = open_provider_attempt journal run in
  let output =
    require_opened_node
      (Journal.open_node
         journal
         ~run
         ~parent:turn
         ~kind:(Event.Output_block { ordinal = 0; block_kind = Event.Text_block }))
  in
  Eio.Switch.run (fun sw ->
    List.init 32 Fun.id
    |> List.iter (fun index ->
      Eio.Fiber.fork ~sw (fun () ->
        ignore
          (require_ok
             (Journal.update_node
                journal
                ~node:output
                (Event.Output_delta (`Assoc [ "index", `Int index ])))))));
  let events = Journal.events journal in
  check int "every update retained" 36 (List.length events);
  check_contiguous events
;;

let test_batch_stages_immutably_and_publishes_once () =
  Eio_main.run
  @@ fun _env ->
  let journal = require_ok (Journal.create ()) in
  let empty = Journal.begin_batch journal in
  check int "empty batch has no events" 0 (Journal.batch_length empty);
  (match Journal.commit_batch empty with
   | Error Journal.Empty_batch -> ()
   | Error error -> fail (Journal.error_to_string error)
   | Ok _ -> fail "an empty batch was committed");
  let batch, (run, opened_run) =
    require_ok
      (Journal.stage empty (Journal.Transaction.start_run ~agent_name:"batched-run" ()))
  in
  let batch, (turn, opened_turn) =
    require_ok
      (Journal.stage
         batch
         (Journal.Transaction.open_node
            ~run
            ~parent:(Journal.run_root run)
            ~kind:(Event.Agent_turn { ordinal = 0 })
            ()))
  in
  check int "two semantic mutations are staged" 2 (Journal.batch_length batch);
  (match Journal.stage batch (Journal.Transaction.finish_run ~run Event.Succeeded) with
   | Error (Journal.Invariant_violation (Journal.Node_has_open_children node_id)) ->
     check
       bool
       "invalid stage reports the exact run root"
       true
       (Event.Node_id.equal node_id (Journal.run_root run))
   | Error error -> fail (Journal.error_to_string error)
   | Ok _ -> fail "an invalid finish entered the batch");
  check int "rejected stage leaves input batch unchanged" 2 (Journal.batch_length batch);
  check int "staging does not publish a prefix" 0 (Journal.length journal);
  (match Journal.find_run journal (Journal.run_id run) with
   | None -> ()
   | Some _ -> fail "a staged run was visible before the batch commit");
  let batch, closed_turn =
    require_ok
      (Journal.stage batch (Journal.Transaction.close_node ~node:turn Event.Succeeded))
  in
  let batch, closed_run =
    require_ok (Journal.stage batch (Journal.Transaction.finish_run ~run Event.Succeeded))
  in
  check int "valid replacement extends original batch" 4 (Journal.batch_length batch);
  let committed = require_ok (Journal.commit_batch batch) in
  check int "all staged events committed together" 4 (List.length committed);
  check int "one final reducer snapshot is visible" 4 (Journal.length journal);
  check_contiguous committed;
  check
    bool
    "commit retains staged event identities and order"
    true
    (List.equal
       Event.equal
       [ opened_run; opened_turn; closed_turn; closed_run ]
       committed);
  match Journal.find_run journal (Journal.run_id run) with
  | Some { status = Journal.Finished { value = Event.Succeeded; _ }; through_seq; _ } ->
    check int "published projection uses final batch watermark" 4 through_seq
  | _ -> fail "committed batch did not publish its finished run projection"
;;

let test_batch_rejects_a_stale_base_without_rebuilding_events () =
  Eio_main.run
  @@ fun _env ->
  let journal = require_ok (Journal.create ()) in
  let batch, (_staged_run, staged_event) =
    require_ok
      (Journal.stage
         (Journal.begin_batch journal)
         (Journal.Transaction.start_run ~agent_name:"staged-before-race" ()))
  in
  let _committed_run, committed_event =
    require_ok (Journal.start_run journal ~agent_name:"concurrent-winner")
  in
  let expect_stale () =
    match Journal.commit_batch batch with
    | Error (Journal.Stale_batch { expected_last_seq = 0; actual_last_seq = 1 }) -> ()
    | Error error -> fail (Journal.error_to_string error)
    | Ok _ -> fail "a batch from a stale reducer snapshot was committed"
  in
  expect_stale ();
  expect_stale ();
  check int "stale rejection retains the immutable batch" 1 (Journal.batch_length batch);
  check int "stale commit does not mutate journal" 1 (Journal.length journal);
  check
    bool
    "staged identity was not substituted for committed state"
    false
    (Event.Event_id.equal (Event.event_id staged_event) (Event.event_id committed_event))
;;

let test_closed_abort_transaction_stages_one_batch () =
  Eio_main.run
  @@ fun _env ->
  let journal = require_ok (Journal.create ()) in
  let terminal = Event.Cancelled { reason = Some "composed abort"; data = None } in
  let batch, (run, opened_run) =
    require_ok
      (Journal.stage
         (Journal.begin_batch journal)
         (Journal.Transaction.start_run ~agent_name:"closed-abort" ()))
  in
  let batch, (_turn, opened_turn) =
    require_ok
      (Journal.stage
         batch
         (Journal.Transaction.open_node
            ~run
            ~parent:(Journal.run_root run)
            ~kind:(Event.Agent_turn { ordinal = 0 })
            ()))
  in
  let batch, aborted =
    require_ok (Journal.stage batch (Journal.Transaction.abort_run ~run terminal))
  in
  check
    int
    "closed transaction set stages open and terminal events"
    4
    (Journal.batch_length batch);
  (match Journal.stage batch (Journal.Transaction.abort_run ~run terminal) with
   | Error (Journal.Invariant_violation (Journal.Run_already_finished run_id)) ->
     check
       bool
       "second abort identifies the already-finished run"
       true
       (Event.Run_id.equal run_id (Journal.run_id run))
   | Error error -> fail (Journal.error_to_string error)
   | Ok _ -> fail "closed abort transaction accepted an already-closed run");
  check
    int
    "rejected abort leaves the staged batch unchanged"
    4
    (Journal.batch_length batch);
  check int "closed transaction is invisible before commit" 0 (Journal.length journal);
  check int "typed abort closes turn and root" 2 (List.length aborted);
  let committed = require_ok (Journal.commit_batch batch) in
  check
    bool
    "closed transaction retains exact event identities"
    true
    (List.equal Event.equal ([ opened_run; opened_turn ] @ aborted) committed);
  match Journal.find_run journal (Journal.run_id run) with
  | Some { status = Journal.Finished { value = Event.Cancelled _; _ }; _ } -> ()
  | _ -> fail "closed abort transaction did not close its run"
;;

let () =
  run
    "Execution journal"
    [ ( "topology"
      , [ test_case
            "recursive runs retain hierarchy and order"
            `Quick
            test_recursive_tree_and_global_sequence
        ; test_case
            "hierarchy and lifecycle violations"
            `Quick
            test_hierarchy_and_lifecycle_rejections
        ; test_case
            "closed parent rejects new children as Parent_node_closed"
            `Quick
            test_open_under_closed_parent_is_parent_node_closed
        ; test_case
            "flattened recursion rejected and child-run fence holds"
            `Quick
            test_recursion_rejections_are_pinned
        ; test_case
            "concurrent updates share one sequence"
            `Quick
            test_concurrent_updates_keep_one_sequence
        ; test_case
            "output snapshot terminates output updates"
            `Quick
            test_output_snapshot_is_terminal_for_output_updates
        ; test_case
            "streaming provider identity and recursive projection"
            `Quick
            test_streaming_provider_identity_and_projection
        ; test_case
            "one top-level run defines the execution scope"
            `Quick
            test_one_top_level_run_per_journal
        ; test_case
            "abort closes a recursive subtree atomically"
            `Quick
            test_abort_run_closes_recursive_subtree_atomically
        ; test_case
            "abort handles deep recursive composition iteratively"
            `Slow
            test_abort_run_handles_deep_recursive_composition_iteratively
        ; test_case
            "cancelled abort does not publish a partial batch"
            `Quick
            test_cancelled_abort_does_not_publish_a_partial_batch
        ; test_case
            "immutable batch rejects a stage and publishes once"
            `Quick
            test_batch_stages_immutably_and_publishes_once
        ; test_case
            "stale batch is rejected without rebuilding events"
            `Quick
            test_batch_rejects_a_stale_base_without_rebuilding_events
        ; test_case
            "closed abort transaction stages one batch"
            `Quick
            test_closed_abort_transaction_stages_one_batch
        ] )
    ; ( "codec"
      , [ test_case
            "round-trip and exact schema"
            `Quick
            test_codec_roundtrip_and_exactness
        ; test_case
            "reducer rejects gaps and dangling causality"
            `Quick
            test_reducer_rejects_sequence_and_unknown_parent_event
        ; test_case
            "reducer rejects execution correlation drift"
            `Quick
            test_reducer_rejects_correlation_drift
        ; test_case
            "JSON terminal and identifier boundaries"
            `Quick
            test_json_terminal_and_id_boundaries
        ; test_case
            "terminal validation certificate preserves payload"
            `Quick
            test_terminal_certificate_preserves_payload
        ] )
    ]
;;
