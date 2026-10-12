open Alcotest
module E = Masc.Keeper_chat_events
module B = Masc.Keeper_chat_agent_core_stream_bridge
module J = Masc.Keeper_chat_event_log
module F = Native_tool_outcome_fixture
module L = Masc_tui_keeper_chat_live
module Log = Masc_tui_keeper_chat_log
module T = Masc_tui_keeper_chat_transcript
module P = Masc_tui_keeper_chat_projection

let activity ?(generation=0) ?(scope=0) ?(index=0) ?(channel=E.Model_text) state =
  {E.content_generation=generation; content_scope=scope; content_index=index; content_provider_message_id=Some "reusable"; channel; state}
let observed ?generation ?scope ?index ?channel () = L.Model_content_activity (activity ?generation ?scope ?index ?channel E.Content_observed)
let ended ?generation ?scope ?index ?channel () = L.Model_content_activity (activity ?generation ?scope ?index ?channel E.Content_ended)
let start = L.Stream_model_started {generation=None;stream_scope=None; message_id=Some "reusable"; model="fixture"; usage=None}
let rows t = String.concat "\n" (List.map snd (T.status_rows ~now:1000. t))
let contains t needle = Astring.String.is_infix ~affix:needle (rows t)
let assert_signal t signal =
  check bool ("signal: " ^ signal) true (contains t signal);
  if signal="model content ended" then begin
    check bool "content end is not a response end" false (contains t "model response ended");
    check bool "no stale answering" false (contains t "STREAMING");
    check bool "no stale reasoning" false (contains t "THINKING")
  end
let create () =
  let t = T.create ~keeper_name:"fixture" ~request_id:"r" ~started_at:0. in
  T.apply ~now:0. t L.Run_started; T.apply ~now:0. t start; t

let test_overlap_uses_event_order () =
  let t = create () in
  (* Wall clock moves backwards. The last event, not the biggest clock, owns
     the label; stopping it returns to the newest remaining active event. *)
  List.iter (fun (now,delta) -> T.apply ~now t delta)
    [90.,L.Text {text="A"; response=Unobserved_scope (None)}; 90.,observed (); 80.,L.Thinking {text="R";response=None;content_index=None};
     80.,observed ~index:1 ~channel:E.Model_thinking ();
     70.,L.Text {text="B"; response=Unobserved_scope (None)}; 70.,observed ~index:2 ()];
  assert_signal t "STREAMING";
  T.apply ~now:60. t (ended ~index:2 ()); assert_signal t "THINKING";
  T.apply ~now:50. t (ended ~index:99 ()); assert_signal t "THINKING";
  T.apply ~now:40. t (ended ~scope:1 ~index:1 ~channel:E.Model_thinking ());
  assert_signal t "THINKING";
  T.apply ~now:30. t (ended ~index:1 ~channel:E.Model_thinking ()); assert_signal t "STREAMING";
  T.apply ~now:20. t (ended ()); assert_signal t "model content ended";
  T.apply ~now:10. t (ended ()); assert_signal t "model content ended";
  check string "body bytes preserved" "AB" (T.text t);
  check string "reasoning bytes preserved" "R" (T.thinking t);
  T.apply ~now:1. t (L.Stream_model_stopped (Some {response_generation=0; response_scope=0})); assert_signal t "model response ended"

let test_scope_retry_and_fallback () =
  let t = create () in
  T.apply ~now:1. t (observed ());
  T.apply ~now:2. t start;
  T.apply ~now:3. t (observed ());
  check bool "unbound start cannot reset owned response" true
    (T.model_activity t = Some T.Activity_answering);
  T.apply ~now:4. t (observed ~scope:1 ());
  T.apply ~now:5. t (ended ()); assert_signal t "STREAMING";
  T.apply ~now:6. t (ended ~scope:1 ()); assert_signal t "model content ended";
  T.apply ~now:7. t (observed ~scope:1 ()); assert_signal t "model content ended";
  T.apply ~now:8. t (L.Runtime_attempt_started {runtime_id=Some "next"; attempt_index=Some 1});
  T.apply ~now:9. t (observed ~scope:2 ~channel:E.Model_thinking ());
  T.apply ~now:10. t (ended ~scope:1 ()); assert_signal t "THINKING";
  T.apply ~now:11. t (ended ~scope:2 ~channel:E.Model_thinking ()); assert_signal t "model content ended";
  (* Legacy flat data lacks occurrence authority: an unrelated old content
     stop cannot certify that this later text has ended. *)
  T.apply ~now:12. t (L.Text {text="legacy"; response=Unobserved_scope (None)});
  T.apply ~now:13. t (ended ~scope:2 ~channel:E.Model_thinking ());
  check bool "unbound text does not invent owned answering activity" true
    (T.model_activity t=Some T.Activity_content_ended);
  check string "unbound body bytes are retained" "legacy" (T.text t);
  T.apply ~now:14. t (L.Stream_model_stopped (Some {response_generation=0; response_scope=2}));
  T.apply ~now:15. t (observed ~scope:2 ()); assert_signal t "model response ended";
  T.apply ~now:16. t L.Run_finished;
  T.apply ~now:17. t (observed ~scope:3 ());
  check bool "late model activity cannot reopen the run" false (contains t "STREAMING")

let test_bridge_live_and_journal () =
  let f = F.create () in
  let send = F.on_event f in
  let snapshots expected =
    let live,replay = F.snapshots f in
    List.iter (fun log ->
      let t = T.of_log ~now:2000. log in
      check bool "no unreadable event" true (Option.is_none (T.unreadable t));
      assert_signal t expected;
      let before = T.status_rows ~now:2000. t in
      List.iter (fun (entry:Log.entry) ->
        check bool "overlapping journal replay is deduplicated" false
          (Log.add ?at:entry.at log ~seq:entry.seq entry.delta)) (Log.entries log);
      check bool "duplicate frames do not change activity" true
        (T.status_rows ~now:2000. (T.of_log ~now:2000. log)=before)) [live;replay];
    check bool "live and durable activity agree" true
      (T.status_rows ~now:2000. (T.of_log ~now:2000. live)=T.status_rows ~now:2000. (T.of_log ~now:2000. replay)) in
  let open Agent_core.Types in
  send (MessageStart {id="response";model="fixture";usage=None});
  send (ContentBlockStart {index=9;content_type="thinking";tool_id=None;tool_name=None});
  send (ContentBlockDelta {index=9;delta=ThinkingDelta ""});
  send (ContentBlockStop {index=9}); snapshots "model started";
  send (ContentBlockDelta {index=0;delta=TextDelta "A\n"}); snapshots "STREAMING";
  send (ContentBlockDelta {index=1;delta=ThinkingDelta "R\n"}); snapshots "THINKING";
  send (ContentBlockStop {index=99}); snapshots "THINKING";
  send (ContentBlockStop {index=1}); snapshots "STREAMING";
  send (ContentBlockStop {index=0}); snapshots "model content ended";
  send (ContentBlockStop {index=0}); snapshots "model content ended";
  send (ContentBlockStart {index=3;content_type=Runtime_native_tools.stream_content_type;tool_id=Some "native";tool_name=Some "Read"});
  let live,_ = F.snapshots f in
  let t = T.of_log ~now:2000. live in
  check bool "native remains running after content ends" true
    (List.exists (fun (call:T.tool_activity) -> call.outcome=T.Native_running) (T.tool_calls t));
  F.on_completion f ~block_index:3 ~tool_call_id:(Some "native") Runtime_native_tools.end_observed;
  send (ContentBlockStop {index=3}); snapshots "model content ended";
  send MessageStop; snapshots "model response ended";
  check string "model body intact" "A\n" (T.text (T.of_log ~now:2000. (fst (F.snapshots f))))

let test_stop_reason_closes_content_without_turn_completion () =
  let f = F.create () in
  F.on_event f (Agent_core.Types.ContentBlockDelta {index=0;delta=TextDelta "body\n"});
  F.on_event f (Agent_core.Types.MessageDelta {stop_reason=Some EndTurn;usage=None});
  let live,replay = F.snapshots f in
  List.iter (fun log -> assert_signal (T.of_log ~now:2000. log) "model content ended") [live;replay]

let test_closed_delta_cannot_reopen_activity () =
  List.iter (fun thinking ->
    let f = F.create () in
    let send = F.on_event f in
    let delta text = Agent_core.Types.ContentBlockDelta {index=0;
      delta=(if thinking then ThinkingDelta text else TextDelta text)} in
    send (delta "original\n"); send (Agent_core.Types.ContentBlockStop {index=0});
    send (delta "late\n");
    let live,replay = F.snapshots f in
    List.iter (fun log ->
      let t = T.of_log ~now:2000. log in
      assert_signal t "model content ended";
      check string "closed payload is rejected before flat body projection" "original\n"
        (if thinking then T.thinking t else T.text t);
      check bool "late closed payload remains a visible protocol defect" true (Option.is_some (T.unreadable t))) [live;replay]) [false;true]

let test_poisoned_scope_retires_observed_activity () =
  let open Agent_core.Types in
  let failures = [
    SSEError {message="provider failed";error_type=Some "provider_error";
      provider_status=None;report=Provider_stated;raw="{}"};
    NDJSONError {message="provider failed";error_type=None;raw="{}"};
    SSEParseFailed {raw="broken";reason="invalid JSON"};
    NDJSONParseFailed {raw="broken";reason="invalid JSON"};
    Timeout "provider timeout";
    SSEUnknownEventType {event_type="unknown";raw="{}"};
    SSEUnsupportedPart {provider_kind=Agent_core.Llm_provider.Provider_kind.Gemini;
      part="unsupported";raw="{}"};
    SSEUnsupportedResponse {provider_kind=Agent_core.Llm_provider.Provider_kind.Gemini;
      response="unsupported";raw="{}"}] in
  List.iter (fun failure -> List.iter (fun with_tool ->
    let f = F.create () in
    let send = F.on_event f in
    F.start_runtime_attempt f ~runtime_id:"first-runtime" ~attempt_index:0;
    send (MessageStart {id="poisoned-response";model="fixture";usage=None});
    send (ContentBlockDelta {index=0;delta=TextDelta "answer\n"});
    send (ContentBlockDelta {index=1;delta=ThinkingDelta "reasoning\n"});
    if with_tool then send (ContentBlockStart {index=2;content_type="tool_use";
      tool_id=Some "pending-tool";tool_name=Some "Read"});
    send failure;
    let ended = List.filter_map (function
      | E.Model_content_activity activity when activity.state=E.Content_ended ->
          Some (activity.content_scope,activity.content_index,activity.channel)
      | _ -> None) (F.events f) in
    check bool "only actually observed blocks retire in their scope" true
      (ended=[0,0,E.Model_text;0,1,E.Model_thinking]);
    check bool "poison is not provider response or Keeper turn completion" false
      (List.exists (function E.Agent_core_stream_message_stop _ | E.Run_finished _ -> true | _ -> false) (F.events f));
    send (ContentBlockDelta {index=0;delta=TextDelta "late\n"});
    send (ContentBlockDelta {index=1;delta=ThinkingDelta "late\n"});
    let live,replay = F.snapshots f in
    List.iter (fun log ->
      let t = T.of_log ~now:2000. log in
      assert_signal t "model content ended";
      check bool "actual provider failure remains visible" true (Option.is_some (T.unreadable t));
      check string "authored answer preserved, late poisoned bytes rejected" "answer\n" (T.text t);
      check string "observed reasoning preserved" "reasoning\n" (T.thinking t)) [live;replay];
    check bool "live and durable failure activity agree" true
      (T.status_rows ~now:2000. (T.of_log ~now:2000. live)=T.status_rows ~now:2000. (T.of_log ~now:2000. replay));
    F.start_runtime_attempt f ~runtime_id:"retry-runtime" ~attempt_index:1;
    send (MessageStart {id="retry-response";model="fixture";usage=None});
    send (ContentBlockDelta {index=0;delta=TextDelta "retry\n"});
    let live,replay = F.snapshots f in
    List.iter (fun log -> assert_signal (T.of_log ~now:2000. log) "STREAMING") [live;replay]
  ) [false;true]) failures

let test_cut_scope_still_accepts_observed_content () =
  let open Agent_core.Types in
  List.iter (fun with_tool ->
    let f = F.create () in
    F.on_event f (ContentBlockDelta {index=0;delta=TextDelta "before\n"});
    if with_tool then F.on_event f (ContentBlockStart {index=2;content_type="tool_use";
      tool_id=Some "pending-tool";tool_name=Some "Read"});
    F.on_event f (StreamIncomplete {reason="max_output_tokens"});
    check bool "a cut scope can still accept its legal terminal sequence" false
      (List.exists (function E.Model_content_activity a when a.state=E.Content_ended -> true | _ -> false) (F.events f));
    F.on_event f (ContentBlockDelta {index=0;delta=TextDelta "after\n"});
    F.on_event f (ContentBlockStop {index=0});
    let live,replay = F.snapshots f in
    List.iter (fun log ->
      let t = T.of_log ~now:2000. log in
      assert_signal t "model content ended";
      check string "cut scope retains subsequent valid content" "before\nafter\n" (T.text t)) [live;replay]
  ) [false;true]

let test_fresh_worker_generation_in_same_journal () =
  let reversed = ref [] in
  let bus = E.create ~first_seq:17 ~on_publish:(fun ~seq ~ts event ->
    reversed := {J.seq; ts; event} :: !reversed) () in
  E.reader_gone bus;
  let publish = E.publish bus in
  let run_id="keeper-operation-run-r" in
  let worker text =
    let generation = E.publish_with_sequence bus (E.Run_started {run_id;thread_id="keeper:fixture"}) in
    let bridge = B.empty_state ~generation () in
    let translated = B.translate ~redact_text:Fun.id ~base_dir:"/unused" ~stream_scope:0 bridge
      (Agent_core.Types.ContentBlockDelta {index=0;delta=TextDelta text}) in
    List.iter publish translated.chat_events;
    generation in
  let old_generation = worker "first" in
  publish (E.Reply_details {reply="checkpoint";turn_outcome=Masc.Keeper_turn_outcome.Continuation_checkpoint;
    turn_ref=Ids.Turn_ref.make ~trace_id:"content-generation" ~absolute_turn:1; terminal_stream_scope=None});
  publish (E.Run_finished {run_id});
  let generation = worker "second" in
  check bool "fresh worker owns a later durable generation" true (generation > old_generation);
  publish (E.Model_content_activity (activity ~generation:old_generation E.Content_ended));
  let stale_stop = B.translate ~redact_text:Fun.id ~base_dir:"/unused" ~stream_scope:0
    (B.empty_state ~generation:old_generation ()) Agent_core.Types.MessageStop in
  List.iter publish stale_stop.chat_events;
  let lines = List.rev !reversed |> List.map (fun line ->
    match J.journaled_event_of_json (J.journaled_event_to_json line) with
    | Ok line -> line | Error detail -> fail detail) in
  let replay = Log.create ~keeper_name:"fixture" ~request_id:"r" ~started_at:0. in
  ignore (Log.add_journaled replay lines);
  let _,wire = List.fold_left (fun (state,wire) (line:J.journaled_event) ->
    let state,event = Server_keeper_chat_agui_projection.project ~timestamp:line.ts ~redact_text:Fun.id state line.event in
    state,wire ^ Option.fold ~none:"" ~some:(Ag_ui.event_to_sse ~id:line.seq) event)
    (Server_keeper_chat_agui_projection.initial,"") lines in
  let live = Log.create ~keeper_name:"fixture" ~request_id:"r" ~started_at:0. in
  L.feed (L.create ()) wire |> List.iter (fun (item:L.observed_delta) ->
    ignore (Log.add ?at:item.at live ~seq:item.seq item.delta));
  List.iter (fun log ->
    let t = T.of_log ~now:2000. log in
    check string "fresh worker with reused scope/index keeps second segment body" "second" (T.text t);
    check bool "producer stop from old worker preserves current activity through both paths" true
      (T.model_activity t = Some T.Activity_answering);
    assert_signal t "STREAMING";
    T.apply ~now:2000. t (ended ~generation ());
    assert_signal t "model content ended";
    T.apply ~now:2001. t (L.Stream_model_stopped
      (Some {E.response_generation=generation;response_scope=0}));
    check bool "matching owned stop closes response through both paths" true
      (T.model_activity t = Some T.Activity_response_ended);
    check bool "response close retains run" true (T.phase t = T.Working)) [live;replay]

let test_strict_shared_codec () =
  let valid = E.model_content_activity_to_json (activity E.Content_observed) in
  let change key value = match valid with
    | `Assoc fields -> `Assoc ((key,value)::List.remove_assoc key fields)
    | _ -> fail "expected object" in
  let malformed = [`Null; change "generation" (`Int (-1)); change "stream_scope" (`Int (-1)); change "block_index" (`String "0");
    change "channel" (`String "tool"); change "state" (`String "success");
    change "provider_message_id" `Null; change "unexpected" (`Bool true);
    (match valid with `Assoc fields -> `Assoc (("state",`String "observed")::fields) | _ -> assert false)] in
  List.iter (fun json ->
    check bool "strict stream rejects malformed metadata" true
      (Result.is_error (P.validate_custom_value ~name:"KEEPER_MODEL_CONTENT_ACTIVITY" json));
    let wire = "data: " ^ Yojson.Safe.to_string (`Assoc ["type",`String "CUSTOM";
      "name",`String "KEEPER_MODEL_CONTENT_ACTIVITY";"value",json]) ^ "\n\n" in
    check bool "live reports malformed instead of activity" true
      (match L.feed (L.create ()) wire with [{delta=L.Undecodable _;_}] -> true | _ -> false);
    check bool "journal rejects same malformed metadata" true
      (Result.is_error (J.keeper_chat_event_of_json (`Assoc ["type",`String "model_content_activity";"activity",json])))) malformed

let test_activity_numeric_wire_boundary () =
  let valid = E.model_content_activity_to_json (activity E.Content_observed) in
  let with_field field wire = match valid with
    | `Assoc fields -> `Assoc ((field,Yojson.Safe.from_string wire)::List.remove_assoc field fields)
    | _ -> fail "activity must encode as an object" in
  List.iter (fun field ->
    List.iter (fun (wire,expected) ->
      let json = with_field field wire in
      let decoded = match E.model_content_activity_of_json json with
        | Ok value -> value | Error detail -> fail detail in
      let actual = match field with
        | "generation" -> decoded.content_generation
        | "stream_scope" -> decoded.content_scope
        | _ -> decoded.content_index in
      check int "same exact activity identity across numeric spellings" expected actual;
      check bool "live custom decoder admits the same numeric value" true
        (Result.is_ok (P.validate_custom_value ~name:"KEEPER_MODEL_CONTENT_ACTIVITY" json)))
      ["0",0;"-0.0",0;"1e0",1;"9007199254740991",9_007_199_254_740_991;
       "9007199254740991.0",9_007_199_254_740_991];
    List.iter (fun wire ->
      let json = with_field field wire in
      check bool "unsafe activity identity is rejected" true (Result.is_error (E.model_content_activity_of_json json));
      check bool "journal cannot admit an identity the browser cannot represent" true
        (Result.is_error (J.keeper_chat_event_of_json (`Assoc ["type",`String "model_content_activity";"activity",json]))))
      ["-1";"0.5";"9007199254740992";"9007199254740993";"1e309";"\"1\""])
    ["generation";"stream_scope";"block_index"]

let test_owned_response_stop () =
  let t = create () in
  let stop generation scope = L.Stream_model_stopped
    (Some {E.response_generation=generation; response_scope=scope}) in
  T.apply ~now:1. t (observed ~generation:2 ~scope:1 ~channel:E.Model_thinking ());
  List.iter (fun delta ->
    T.apply ~now:2. t delta;
    check bool "unowned and stale stops retain current reasoning" true
      (T.model_activity t = Some T.Activity_reasoning))
    [stop 1 99; stop 2 0; stop 2 2; L.Stream_model_stopped None];
  T.apply ~now:3. t (stop 2 1);
  check bool "matching response stop ends model activity" true
    (T.model_activity t = Some T.Activity_response_ended);
  check bool "response stop does not finish keeper turn" true (T.phase t = T.Working);
  T.apply ~now:4. t (stop 2 1);
  check bool "duplicate response stop is idempotent" true
    (T.model_activity t = Some T.Activity_response_ended);
  T.apply ~now:5. t (observed ~generation:3 ~scope:0 ());
  T.apply ~now:6. t (stop 2 1);
  check bool "previous generation stop cannot end resumed answer" true
    (T.model_activity t = Some T.Activity_answering);
  T.apply ~now:7. t (L.Text {text="next";response=Unobserved_scope (Some 1)});
  T.apply ~now:8. t (stop 3 0);
  check bool "known old owner cannot end newer unbound text" true
    (T.model_activity t = None);
  check string "unbound text body remains" "next" (T.text t)

let test_stop_identity_protocol () =
  let owner = {E.response_generation=7;response_scope=2} in
  let json = E.response_identity_to_json owner in
  check bool "stop identity round trip" true (E.response_identity_of_json json = Ok owner);
  let event = E.Agent_core_stream_message_stop (Some owner) in
  check bool "durable stop preserves complete identity" true
    (J.keeper_chat_event_of_json (J.keeper_chat_event_to_json event) = Ok event);
  List.iter (fun fields ->
    check bool "ambiguous durable owner rejected" true
      (Result.is_error (J.keeper_chat_event_of_json (`Assoc
        (("type",`String "agent_core_stream_message_stop")::fields)))))
    [["response",json;"response",json];["response",`Null;"response",json];["response",`Null]];
  let wire value = "data: " ^ Yojson.Safe.to_string (`Assoc
    ["type",`String "CUSTOM";"name",`String "KEEPER_STREAM_MESSAGE_STOP";"value",value]) ^ "\n\n" in
  check bool "live stop preserves complete identity" true
    (match L.feed (L.create ()) (wire json) with
     | [{delta=L.Stream_model_stopped (Some actual);_}] -> actual=owner | _ -> false);
  List.iter (fun malformed ->
    check bool "strict stop identity rejects malformed input" true
      (Result.is_error (E.response_identity_of_json malformed));
    check bool "projection rejects malformed stop" true
      (Result.is_error (P.validate_custom_value ~name:"KEEPER_STREAM_MESSAGE_STOP" malformed));
    check bool "live stop reports malformed identity" true
      (match L.feed (L.create ()) (wire malformed) with
       | [{delta=L.Undecodable _;_}] -> true | _ -> false))
    [`Assoc []; `Assoc ["content_generation",`Int 7];
     `Assoc ["content_generation",`Int 7;"stream_scope",`Int (-1)];
     `Assoc ["content_generation",`Int 7;"stream_scope",`Int 2;"stream_scope",`Int 2]]

let test_owned_response_details () =
  let t = create () in
  let details generation scope tokens = L.Stream_details {generation;stream_scope=Some scope;
    usage=Some {L.input_tokens=Some tokens;output_tokens=None;
      cache_read_input_tokens=None;cache_creation_input_tokens=None};stop_reason=Some Agent_core.Types.EndTurn} in
  T.apply ~now:1. t (observed ~generation:2 ~scope:0 ());
  T.apply ~now:2. t (details (Some 2) 0 7);
  check bool "current details keep model activity" true (T.model_activity t=Some T.Activity_answering);
  T.apply ~now:3. t (details (Some 1) 99 99);
  T.apply ~now:4. t (details None 0 99);
  let metadata = T.response_metadata t in
  check bool "stale and unbound details cannot overwrite current counters" true
    (Option.map (fun (usage:L.stream_usage) -> usage.input_tokens) metadata.usage=Some (Some 7));
  T.apply ~now:5. t (details (Some 3) 0 11);
  let metadata = T.response_metadata t in
  check bool "first surviving details own reused scope in new generation" true (metadata.owner=Some (3,0));
  check bool "new details retire prior activity" true (T.model_activity t=None);
  check bool "new details carry new counters" true
    (Option.map (fun (usage:L.stream_usage) -> usage.input_tokens) metadata.usage=Some (Some 11));
  T.apply ~now:6. t (L.Stream_model_stopped (Some {E.response_generation=2;response_scope=0}));
  check bool "old stop cannot end newly owned details" true (T.model_activity t=None);
  T.apply ~now:7. t (observed ~generation:3 ());
  check bool "content can follow details without start frame" true (T.model_activity t=Some T.Activity_answering);
  T.apply ~now:8. t (L.Text {text="next";response=Unobserved_scope (Some 2)});
  let unbound = T.response_metadata t in
  T.apply ~now:8. t (details (Some 3) 0 99);
  T.apply ~now:8. t (details (Some 3) 1 99);
  check bool "old details cannot rewind newer unbound response" true (T.response_metadata t=unbound);
  T.apply ~now:8. t L.Run_finished;
  let before = T.response_metadata t in
  let before_text = T.text t in
  T.apply ~now:9. t (details (Some 4) 0 99);
  check bool "terminal response metadata remains settled" true (T.response_metadata t=before);
  check string "terminal details preserve authored body" before_text (T.text t)

let test_details_production_identity () =
  let translated = B.translate ~redact_text:Fun.id ~base_dir:"/unused" ~stream_scope:0
    (B.empty_state ~generation:7 ())
    (Agent_core.Types.MessageDelta {stop_reason=None;usage=None}) in
  (match translated.chat_events with
    | [E.Agent_core_stream_message_delta {content_generation=Some generation;stream_scope;_} as event] ->
      check int "bridge details capture supplied run generation" 7 generation;
      check int "bridge details retain server scope" 0 stream_scope;
      check bool "journal round trip retains details identity" true
        (J.keeper_chat_event_of_json (J.keeper_chat_event_to_json event)=Ok event);
      check bool "empty owned details survive journal mapping" true
        (match Log.delta_of_journaled event with
         | Some (L.Stream_details {generation=Some 7;stream_scope=Some 0;_}) -> true | _ -> false);
      let _, projected = Server_keeper_chat_agui_projection.project ~timestamp:0.
        ~redact_text:Fun.id Server_keeper_chat_agui_projection.initial event in
      let wire = Option.fold ~none:"" ~some:(Ag_ui.event_to_sse ~id:1) projected in
      check bool "empty owned details survive producer live projection" true
        (match L.feed (L.create ()) wire with
         | [{delta=L.Stream_details {generation=Some 7;stream_scope=Some 0;_};_}] -> true | _ -> false)
    | _ -> fail "bridge did not publish owned response details");
  let malformed = `Assoc ["type",`String "agent_core_stream_message_delta";
    "stream_scope",`Int 0;"content_generation",`Null] in
  check bool "present invalid generation cannot become unbound details" true
    (Result.is_error (J.keeper_chat_event_of_json malformed));
  List.iter (fun fields ->
    let journal = `Assoc (("type",`String "agent_core_stream_message_delta")::fields) in
    check bool "malformed details ownership rejects durable admission" true
      (Result.is_error (J.keeper_chat_event_of_json journal));
    let wire = "data: " ^ Yojson.Safe.to_string (`Assoc ["type",`String "CUSTOM";
      "name",`String "KEEPER_STREAM_MESSAGE_DELTA";"value",`Assoc fields]) ^ "\n\n" in
    check bool "malformed details ownership reports live failure" true
      (match L.feed (L.create ()) wire with [{delta=L.Undecodable _;_}] -> true | _ -> false))
    [["content_generation",`Int 7];
     ["content_generation",`Int 7;"stream_scope",`Int (-1)];
     ["content_generation",`Int 7;"stream_scope",`Int 0;"stream_scope",`Int 1];
     ["content_generation",`Int 7;"stream_scope",`Int 9_007_199_254_740_992]]

let test_owned_thinking_lifecycle () =
  let t = create () in
  let think generation scope text = L.Thinking {text;content_index=None;
    response=Some {E.response_generation=generation;response_scope=scope}} in
  T.apply ~now:1. t (think 2 0 "current");
  check bool "owned reasoning establishes current response" true
    ((T.response_metadata t).owner=Some (2,0));
  T.apply ~now:2. t (think 1 99 "stale");
  check string "old reasoning cannot append to newer body" "current" (T.thinking t);
  T.apply ~now:3. t (L.Stream_model_stopped (Some {E.response_generation=2;response_scope=0}));
  T.apply ~now:4. t (L.Text {text="unbound";response=Unobserved_scope (None)});
  T.apply ~now:5. t (think 2 0 "after-stop");
  check string "mutable answer activity cannot reopen stopped reasoning" "current" (T.thinking t);
  T.apply ~now:6. t (L.Runtime_attempt_started {runtime_id=Some "retry";attempt_index=Some 1});
  let retry_body = T.thinking t in
  T.apply ~now:7. t (think 2 0 "after-retry");
  T.apply ~now:8. t (observed ~generation:2 ());
  T.apply ~now:9. t (L.Stream_model_started {generation=Some 2;stream_scope=Some 0;
    message_id=Some "reused";model="old";usage=None});
  check string "retry cannot reopen stopped owner body" retry_body (T.thinking t);
  check bool "closed header/content cannot reopen retry activity" true (T.model_activity t=None);
  T.apply ~now:10. t (think 3 0 "fresh");
  check string "new generation reasoning survives reused scope" (retry_body ^ "fresh") (T.thinking t);
  check bool "new generation reasoning is observed activity" true
    (T.model_activity t=Some T.Activity_reasoning);
  T.apply ~now:11. t (L.Thinking {text="unbound";response=None;content_index=None});
  check string "unobserved owner preserves authored bytes" (retry_body ^ "freshunbound") (T.thinking t);
  T.apply ~now:12. t L.Run_finished;
  T.apply ~now:13. t (think 4 0 "late");
  check string "terminal reasoning cannot append late bytes" (retry_body ^ "freshunbound") (T.thinking t)

let test_owned_thinking_protocol () =
  let translated = B.translate ~redact_text:Fun.id ~base_dir:"/unused" ~stream_scope:0
    (B.empty_state ~generation:7 ())
    (Agent_core.Types.ContentBlockDelta {index=0;delta=ThinkingDelta "reason"}) in
  let event = match List.find_opt (function E.Agent_core_thinking_delta _ -> true | _ -> false)
      translated.chat_events with
    | Some (E.Agent_core_thinking_delta {response=Some owner;_} as event) ->
      check int "thinking bridge captures generation" 7 owner.response_generation;
      check int "thinking bridge captures server scope" 0 owner.response_scope;
      event
    | Some _ | None -> fail "bridge did not publish owned thinking" in
  check bool "owned thinking durable roundtrip" true
    (J.keeper_chat_event_of_json (J.keeper_chat_event_to_json event)=Ok event);
  let _, projected = Server_keeper_chat_agui_projection.project ~timestamp:0.
    ~redact_text:Fun.id Server_keeper_chat_agui_projection.initial event in
  let wire = Option.fold ~none:"" ~some:(Ag_ui.event_to_sse ~id:1) projected in
  let expected = L.Thinking {text="reason";content_index=Some 0;response=Some {E.response_generation=7;response_scope=0}} in
  check bool "owned thinking journal/live identity agree" true
    (Log.delta_of_journaled event=Some expected
     && match L.feed (L.create ()) wire with [{delta;_}] -> delta=expected | _ -> false);
  List.iter (fun fields ->
    check bool "malformed thinking owner durable rejection" true
      (Result.is_error (J.keeper_chat_event_of_json (`Assoc
       (["type",`String "agent_core_thinking_delta";"index",`Int 0;"delta",`String "reason"]@fields))));
    let wire = "data: " ^ Yojson.Safe.to_string (`Assoc ["type",`String "CUSTOM";
      "name",`String "KEEPER_THINKING_DELTA";"value",`Assoc
      (["index",`Int 0;"delta",`String "reason"]@fields)]) ^ "\n\n" in
    check bool "malformed thinking owner live rejection" true
      (match L.feed (L.create ()) wire with [{delta=L.Undecodable _;_}] -> true | _ -> false))
    [["response",`Null];["response",`Assoc ["content_generation",`Int 7]];
     ["response",`Assoc ["content_generation",`Int 7;"stream_scope",`Int (-1)]];
     ["response",E.response_identity_to_json {response_generation=7;response_scope=0};
      "response",E.response_identity_to_json {response_generation=8;response_scope=0}]]

let test_owned_text_lifecycle () =
  let t = create () in
  let text generation scope text = L.Text {text;response=E.Observed_response
    {response_generation=generation;response_scope=scope}} in
  T.apply ~now:1. t (text 2 0 "current");
  T.apply ~now:2. t (text 1 99 "stale");
  check string "old generation text cannot append to latest response" "current" (T.text t);
  T.apply ~now:3. t (text 3 0 "new");
  check bool "reused text scope belongs to new generation" true ((T.response_metadata t).owner=Some (3,0));
  T.apply ~now:4. t (L.Stream_model_stopped (Some {E.response_generation=2;response_scope=0}));
  check bool "old stop cannot end newer owned text" true (T.model_activity t=Some T.Activity_answering);
  T.apply ~now:5. t (L.Stream_model_stopped (Some {E.response_generation=3;response_scope=0}));
  let closed_body = T.text t in
  T.apply ~now:6. t (text 3 0 "after-stop");
  check string "stopped text cannot reopen body" closed_body (T.text t);
  T.apply ~now:7. t (L.Runtime_attempt_started {runtime_id=Some "retry";attempt_index=Some 1});
  let retry_body = T.text t in
  T.apply ~now:8. t (text 3 0 "after-retry");
  check string "retry cannot reopen stopped text identity" retry_body (T.text t);
  T.apply ~now:9. t (text 4 0 "fresh");
  T.apply ~now:10. t (L.Text {text="unknown";response=E.Unobserved_scope (Some 0)});
  check bool "unknown same scope cannot inherit generation" true ((T.response_metadata t).owner=None);
  T.apply ~now:11. t (text 5 0 "");
  check bool "empty owned text retains response boundary" true ((T.response_metadata t).owner=Some (5,0));
  check bool "empty text does not fabricate model activity" true (T.model_activity t=None);
  T.apply ~now:12. t (L.Text {text="scope-two";response=E.Unobserved_scope (Some 2)});
  let unknown_owner = T.response_metadata t in
  List.iter (fun delta -> T.apply ~now:12. t delta;
    check bool "intermediate owned event cannot rewind partial response" true
      (T.response_metadata t=unknown_owner))
    [text 5 1 "intermediate";
     L.Stream_model_started {generation=Some 5;stream_scope=Some 1;message_id=None;model="stale";usage=None};
     observed ~generation:5 ~scope:1 ()];
  T.apply ~now:12. t L.Run_finished;
  let terminal_owner = T.response_metadata t in
  T.apply ~now:12. t (L.Stream_model_started {generation=Some 6;stream_scope=Some 0;message_id=None;model="late";usage=None});
  check bool "terminal header preserves settled metadata" true (T.response_metadata t=terminal_owner);
  let terminal_body = T.text t in
  T.apply ~now:13. t (text 6 0 "late");
  check string "terminal text preserves settled body" terminal_body (T.text t)

let test_owned_text_protocol () =
  let translated = B.translate ~redact_text:Fun.id ~base_dir:"/unused" ~stream_scope:0
    (B.empty_state ~generation:7 ())
    (Agent_core.Types.ContentBlockDelta {index=0;delta=TextDelta "answer"}) in
  let event = match List.find_opt (function E.Text_delta _ -> true | _ -> false) translated.chat_events with
    | Some (E.Text_delta {response=E.Observed_response owner;_} as event) ->
      check int "text captures run generation" 7 owner.response_generation;
      check int "text captures server scope" 0 owner.response_scope; event
    | Some _ | None -> fail "bridge did not emit owned text" in
  check bool "text durable identity roundtrip" true
    (J.keeper_chat_event_of_json (J.keeper_chat_event_to_json event)=Ok event);
  let _, projected = Server_keeper_chat_agui_projection.project ~timestamp:0.
    ~redact_text:Fun.id Server_keeper_chat_agui_projection.initial event in
  let wire = Option.fold ~none:"" ~some:(Ag_ui.event_to_sse ~id:1) projected in
  let expected = L.Text {text="answer";response=E.Observed_response
    {response_generation=7;response_scope=0}} in
  check bool "owned text live and journal agree" true
    (Log.delta_of_journaled event=Some expected
     && match L.feed (L.create ()) wire with [{delta;_}] -> delta=expected | _ -> false);
  let owner = E.response_identity_to_json {response_generation=7;response_scope=0} in
  List.iter (fun fields ->
    check bool "typed text owner rejects conflicting metadata" true
      (Result.is_error (E.text_response_of_fields ~owner_field:"response" ~scope_field:"stream_scope" fields));
    check bool "journal rejects conflicting text metadata" true
      (Result.is_error (J.keeper_chat_event_of_json (`Assoc
        (["type",`String "text_delta";"delta",`String "answer"]@fields)))))
    [["response",owner;"stream_scope",`Int 0];["response",`Null];
     ["response",owner;"response",owner];["stream_scope",`Int (-1)];
     ["stream_scope",`Int 9_007_199_254_740_992]]

let test_missing_start_retains_content_closure () =
  List.iter (fun with_open_piece ->
    let t = create () in
    T.apply ~now:1. t (L.Stream_model_started {generation=Some 7;stream_scope=Some 0;
      message_id=None;model="fixture";usage=None});
    if with_open_piece then T.apply ~now:2. t (observed ~generation:7 ~index:1 ());
    T.apply ~now:3. t (ended ~generation:7 ~index:0 ~channel:E.Model_thinking ());
    let expected = if with_open_piece then T.Activity_answering else T.Activity_content_ended in
    check bool "closure with missing start preserves other open activity" true
      (T.model_activity t=Some expected);
    T.apply ~now:4. t (observed ~generation:7 ~index:0 ~channel:E.Model_thinking ());
    T.apply ~now:5. t (L.Thinking {text="late exposed bytes";content_index=Some 0;
      response=Some {E.response_generation=7;response_scope=0}});
    check bool "late header and body cannot reopen the closed occurrence" true
      (T.model_activity t=Some expected);
    check string "late exposed body remains available" "late exposed bytes" (T.thinking t);
    T.apply ~now:6. t (ended ~generation:8 ~index:0 ~channel:E.Model_thinking ());
    check bool "future closure cannot admit a response" true
      ((T.response_metadata t).owner=Some (7,0));
    T.apply ~now:7. t (observed ~generation:8 ~index:0 ~channel:E.Model_thinking ());
    check bool "new response can reuse the content index" true
      (T.model_activity t=Some T.Activity_reasoning)
  ) [false;true]

let test_missing_start_closure_preserves_retry () =
  let t = create () in
  let retry : Masc.Runtime_claude_api_retry.t = {observation_id="retry";attempt=1;
    max_retries=10;retry_delay_ms=1000;error_status=None} in
  T.apply ~now:1. t (L.Runtime_attempt_started {runtime_id=Some "claude";attempt_index=Some 0});
  T.apply ~now:2. t (L.Stream_model_started {generation=Some 7;stream_scope=Some 0;
    message_id=None;model="fixture";usage=None});
  T.apply ~now:3. t (L.Provider_retry_observed {attempt={routing_run_id="run";
    runtime_id="claude";lane_attempt_index=0};retry});
  T.apply ~now:4. t (ended ~generation:7 ~index:0 ~channel:E.Model_thinking ());
  T.apply ~now:5. t (L.Thinking {text="late";content_index=Some 0;
    response=Some {E.response_generation=7;response_scope=0}});
  check bool "missing-start closure and late body preserve current retry" true
    (T.model_activity t=Some (T.Activity_provider_retry retry))

let test_thinking_index_wire_boundary () =
  let decode fields =
    let wire = "data: " ^ Yojson.Safe.to_string (`Assoc ["type",`String "CUSTOM";
      "name",`String "KEEPER_THINKING_DELTA";"value",`Assoc (("delta",`String "provided")::fields)]) ^ "\n\n" in
    L.feed (L.create ()) wire in
  check bool "reported content index survives the live boundary" true
    (match decode ["index",`Int 7] with
     | [{delta=L.Thinking {content_index=Some 7;_};_}] -> true | _ -> false);
  List.iter (fun fields ->
    check bool "invalid content index grants no occurrence authority" true
      (match decode fields with [{delta=L.Undecodable _;_}] -> true | _ -> false)
  ) [ []; ["index",`Int (-1)]; ["index",`Float 0.5];
      ["index",`Int 9_007_199_254_740_992]; ["index",`Int 0;"index",`Int 1] ]
;;

let () = run "model content activity"
  ["boundaries", [test_case "owned text lifecycle" `Quick test_owned_text_lifecycle;
    test_case "owned text protocol" `Quick test_owned_text_protocol;
    test_case "thinking content index wire" `Quick test_thinking_index_wire_boundary;
    test_case "missing content start retains closure" `Quick test_missing_start_retains_content_closure;
    test_case "missing-start closure preserves retry" `Quick test_missing_start_closure_preserves_retry;
    test_case "owned thinking lifecycle" `Quick test_owned_thinking_lifecycle;
    test_case "owned thinking protocol" `Quick test_owned_thinking_protocol;
    test_case "owned response details" `Quick test_owned_response_details;
    test_case "details production identity" `Quick test_details_production_identity;
    test_case "owned response stop admission" `Quick test_owned_response_stop;
    test_case "stop identity protocol" `Quick test_stop_identity_protocol;
    test_case "activity JSON safe-integer boundary" `Quick test_activity_numeric_wire_boundary;
    test_case "overlap uses event order" `Quick test_overlap_uses_event_order;
    test_case "scope, response, retry, legacy and late stop" `Quick test_scope_retry_and_fallback;
    test_case "production bridge through SSE and durable replay" `Quick test_bridge_live_and_journal;
    test_case "stop reason closes content only" `Quick test_stop_reason_closes_content_without_turn_completion;
    test_case "closed delta cannot reopen activity" `Quick test_closed_delta_cannot_reopen_activity;
    test_case "poisoned scope retires only observed activity" `Quick test_poisoned_scope_retires_observed_activity;
    test_case "cut scope keeps its activity until legal close" `Quick test_cut_scope_still_accepts_observed_content;
    test_case "fresh workers in the same journal" `Quick test_fresh_worker_generation_in_same_journal;
    test_case "strict shared codec" `Quick test_strict_shared_codec]]
