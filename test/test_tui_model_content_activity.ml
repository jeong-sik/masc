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
let start = L.Stream_model_started {stream_scope=None; message_id=Some "reusable"; model="fixture"; usage=None}
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
    [90.,L.Text {text="A"; stream_scope=None}; 90.,observed (); 80.,L.Thinking "R";
     80.,observed ~index:1 ~channel:E.Model_thinking ();
     70.,L.Text {text="B"; stream_scope=None}; 70.,observed ~index:2 ()];
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
  T.apply ~now:1. t L.Stream_model_stopped; assert_signal t "model response ended"

let test_scope_retry_and_fallback () =
  let t = create () in
  T.apply ~now:1. t (observed ());
  T.apply ~now:2. t start;
  T.apply ~now:3. t (observed ()); assert_signal t "model started";
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
  T.apply ~now:12. t (L.Text {text="legacy"; stream_scope=None});
  T.apply ~now:13. t (ended ~scope:2 ~channel:E.Model_thinking ()); assert_signal t "STREAMING";
  T.apply ~now:14. t L.Stream_model_stopped;
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
    assert_signal t "STREAMING";
    T.apply ~now:2000. t (ended ~generation ());
    assert_signal t "model content ended") [live;replay]

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

let () = run "model content activity"
  ["boundaries", [test_case "activity JSON safe-integer boundary" `Quick test_activity_numeric_wire_boundary;
    test_case "overlap uses event order" `Quick test_overlap_uses_event_order;
    test_case "scope, response, retry, legacy and late stop" `Quick test_scope_retry_and_fallback;
    test_case "production bridge through SSE and durable replay" `Quick test_bridge_live_and_journal;
    test_case "stop reason closes content only" `Quick test_stop_reason_closes_content_without_turn_completion;
    test_case "closed delta cannot reopen activity" `Quick test_closed_delta_cannot_reopen_activity;
    test_case "fresh workers in the same journal" `Quick test_fresh_worker_generation_in_same_journal;
    test_case "strict shared codec" `Quick test_strict_shared_codec]]
