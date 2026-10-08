open Alcotest
module F = Native_tool_outcome_fixture
module E = Masc.Keeper_chat_events
module Native = Runtime_native_tools
module Bridge = Masc.Keeper_chat_agent_core_stream_bridge
module Journal = Masc.Keeper_chat_event_log
module Live = Masc_tui_keeper_chat_live
module Log = Masc_tui_keeper_chat_log
module T = Masc_tui_keeper_chat_transcript

let start_message id = Agent_core.Types.MessageStart {id;model="fixture";usage=None}
let tool_start ~native index id = Agent_core.Types.ContentBlockStart
  {index;content_type=(if native then Native.stream_content_type else "tool_use");
   tool_id=Some id;tool_name=Some "Read"}
let output count = Native.Output_observed {byte_count=count}
let text value = Agent_core.Types.ContentBlockDelta {index=0;delta=TextDelta value}

let test_replayed_sequence_and_model_signal () =
  let f = F.create () in
  F.on_event f (start_message "response");
  F.on_event f (tool_start ~native:true 1 "native");
  F.on_event f (text "Authored text\n");
  F.on_progress f ~block_index:1 ~tool_call_id:(Some "native") (output 3);
  F.on_progress f ~block_index:1 ~tool_call_id:(Some "native") (output 3);
  F.check_progress f ~running:true ~expected_text:"Authored text\n"
    ~expected:["native",Some 6,None];
  let live,replay = F.snapshots f in
  List.iter (fun log ->
    let before = T.of_log ~now:2000. log in
    List.iter (fun (entry:Log.entry) ->
      check bool "overlapping seq is not applied twice" false
        (Log.add ?at:entry.at log ~seq:entry.seq entry.delta)) (Log.entries log);
    let after = T.of_log ~now:2000. log in
    check bool "replay retains exact byte total and timestamp" true (T.tool_calls before=T.tool_calls after)) [live;replay];
  List.iter (fun (speech,label) ->
    let create () = T.create ~keeper_name:"fixture" ~request_id:"signal" ~started_at:0. in
    let t = create () and control = create () in
    let occurrence : Live.tool_occurrence = {stream_scope=0;block_index=1;provider_message_id=None;tool_call_id=Some "native"} in
    let both ~now delta = List.iter (fun t -> T.apply ~now t delta) [t;control] in
    both ~now:1. Live.Run_started;
    both ~now:1. (Live.Native_tool_started {occurrence;tool_name=Some "Read"});
    both ~now:2. speech;
    T.apply ~now:3. t (Live.Native_tool_progress {occurrence;progress=output 1});
    (* Pending tools hide model activity. Close both calls before comparing the
       visible signal and the silence measured from the original speech time. *)
    both ~now:4. (Live.Native_tool_ended {occurrence;completion=Native.end_observed});
    let observed = T.status_rows ~now:10. t and expected = T.status_rows ~now:10. control in
    check bool "progress cannot change answering/thinking phase or silence age" true (observed=expected);
    let rows = String.concat "\n" (List.map snd observed) in
    check bool "original model signal is visible after native end" true
      (Astring.String.is_infix ~affix:label rows);
    check bool "silence belongs to speech rather than progress" true
      (Astring.String.is_infix ~affix:"nothing back" rows);
    let before = T.tool_calls t in
    T.apply ~now:11. t Live.Run_finished;
    T.apply ~now:12. t (Live.Native_tool_progress {occurrence;progress=output 1});
    check bool "turn terminal rejects new progress" true
      ((List.hd before).native_progress=(List.hd (T.tool_calls t)).native_progress))
    [Live.Text "Answer","STREAMING";Live.Thinking "Reason","THINKING"]

let test_heartbeat_reported_time_is_not_local_elapsed () =
  let t = T.create ~keeper_name:"fixture" ~request_id:"heartbeat-time" ~started_at:0. in
  let control = T.create ~keeper_name:"fixture" ~request_id:"heartbeat-time" ~started_at:0. in
  let occurrence : Live.tool_occurrence = {stream_scope=0;block_index=1;provider_message_id=None;tool_call_id=Some "native"} in
  let both ~now delta = List.iter (fun t -> T.apply ~now t delta) [t;control] in
  both ~now:1. Live.Run_started;
  both ~now:10. (Live.Native_tool_started {occurrence;tool_name=Some "Read"});
  both ~now:11. (Live.Text "answer");
  List.iter (fun (now,elapsed_seconds) ->
    T.apply ~now t (Live.Native_tool_progress {occurrence;progress=Native.Heartbeat_reported {elapsed_seconds}}))
    [50.,30;51.,3];
  (match T.tool_calls t with
   | [call] ->
       check bool "heartbeat leaves the native call running" true (call.outcome=T.Native_running);
       check (option string) "heartbeat supplies no execution identity" None call.execution_id;
       (match call.native_progress with
        | Some p ->
            check (option int) "latest provider seconds may decrease" (Some 3) p.provider_elapsed_seconds;
            check (option (float 0.)) "local observation elapsed stays separate" (Some 41.) p.elapsed;
            check (float 0.) "event time remains local metadata" 51. p.updated_at
        | None -> fail "heartbeat vanished");
       let details = T.project_tool_block T.Full (T.tool_block [call]) in
       check bool "tool detail labels provider elapsed explicitly" true
         (Astring.String.is_infix ~affix:"provider elapsed 3s" (String.concat "\n" details.details))
   | _ -> fail "native occurrence missing");
  both ~now:52. (Live.Native_tool_ended {occurrence;completion=Native.end_observed});
  check bool "model signal and original silence age are unaffected" true
    (T.status_rows ~now:60. t=T.status_rows ~now:60. control);
  check string "authored bytes remain unchanged" "answer" (T.text t)

let test_exact_active_scope_only () =
  List.iter (fun progress ->
  let translate scope state event = Bridge.translate ~redact_text:Fun.id ~base_dir:"/unused-no-media" ~stream_scope:scope state event in
  let first = translate 0 (Bridge.empty_state ()) (start_message "first") in
  let first = translate 0 first.bridge_state (tool_start ~native:true 1 "same-id") in
  let finish = Bridge.finish_native_tool ~redact_text:Fun.id ~stream_scope:0
    ~block_index:1 ~tool_call_id:(Some "same-id") Native.end_observed first.bridge_state in
  let assert_rejected ~scope ~index ~id state =
    let result = Bridge.progress_native_tool ~redact_text:Fun.id ~stream_scope:scope
      ~block_index:index ~tool_call_id:(Some id) progress state in
    check bool "non-owner progress cannot update tools" false
      (List.exists (function E.Native_tool_progress _ -> true | _ -> false) result.chat_events);
    check bool "mapping error is visible" true
      (List.exists (function E.Agent_core_stream_protocol_error _ -> true | _ -> false) result.chat_events);
    result.bridge_state in
  ignore (assert_rejected ~scope:0 ~index:1 ~id:"same-id" finish.bridge_state);
  let second = translate 1 finish.bridge_state (start_message "second") in
  let second = translate 1 second.bridge_state (tool_start ~native:true 1 "same-id") in
  let state = assert_rejected ~scope:0 ~index:1 ~id:"same-id" second.bridge_state in
  let state = assert_rejected ~scope:1 ~index:1 ~id:"wrong-id" state in
  let state = assert_rejected ~scope:1 ~index:9 ~id:"not-started" state in
  let mascot = translate 1 state (tool_start ~native:false 2 "masc") in
  let state = assert_rejected ~scope:1 ~index:2 ~id:"masc" mascot.bridge_state in
  let accepted = Bridge.progress_native_tool ~redact_text:Fun.id ~stream_scope:1
    ~block_index:1 ~tool_call_id:(Some "same-id") progress state in
  check bool "same id/index belongs to its current scope only" true
    (List.exists (function E.Native_tool_progress (native,_) -> native.occurrence.stream_scope=1 | _ -> false) accepted.chat_events);
  let failed = Bridge.fail_stream accepted.bridge_state ~reason:"cancelled" in
  ignore (assert_rejected ~scope:1 ~index:1 ~id:"same-id" failed.bridge_state);
  let stopped = translate 1 accepted.bridge_state Agent_core.Types.MessageStop in
  ignore (assert_rejected ~scope:1 ~index:1 ~id:"same-id" stopped.bridge_state)) [output 3;Native.Heartbeat_reported {elapsed_seconds=30}]

let test_strict_nested_wire_and_journal () =
  let native : E.native_tool = {occurrence={stream_scope=0;provider_message_id=None;block_index=1};tool_call_id=Some "native";tool_call_name=None} in
  let event = E.Native_tool_progress (native,output 1) in
  let replace progress = function
    | `Assoc fields -> `Assoc (("progress",progress)::List.remove_assoc "progress" fields)
    | _ -> fail "expected object" in
  List.iter (fun progress ->
    check bool "malformed journal rejects progress" true
      (Result.is_error (Journal.keeper_chat_event_of_json
        (replace progress (Journal.keeper_chat_event_to_json event))));
    let _, projected = Server_keeper_chat_agui_projection.project ~timestamp:1000.
      ~redact_text:Fun.id Server_keeper_chat_agui_projection.initial event in
    let wire = match projected with
      | Some event ->
          let malformed = Ag_ui.make_event ~timestamp:event.timestamp
            ~run_id:event.run_id ~custom_name:event.custom_name
            ~custom_value:(Option.map (replace progress) event.custom_value)
            ~thread_id:event.thread_id event.event_type in
          Ag_ui.event_to_sse ~id:1 malformed
      | None -> fail "missing progress" in
    check bool "malformed wire is unreadable, never a tool update" true
      (match Live.feed (Live.create ()) wire with
       | [{delta=Live.Undecodable _;_}] -> true | _ -> false))
    [`Null;
     `Assoc ["kind",`String "output_observed";"byte_count",`Int (-1)];
     `Assoc ["kind",`String "output_observed";"byte_count",`Int 0];
     `Assoc ["kind",`String "output_observed";"byte_count",`Int 1;"byte_count",`Int 1];
     `Assoc ["kind",`String "output_observed";"byte_count",`Int 1;"byte_count",`Int 9];
     `Assoc ["kind",`String "output_observed";"byte_count",`Int 1;"message",`String "conflict"];
     `Assoc ["kind",`String "message_reported";"message",`String "one";"message",`String "two"];
     `Assoc ["kind",`String "message_reported";"message",`Bool false];
     `Assoc ["kind",`String "heartbeat_reported";"elapsed_seconds",`Int (-1)];
     `Assoc ["kind",`String "heartbeat_reported";"elapsed_seconds",`Float 1.5];
     `Assoc ["kind",`String "heartbeat_reported";"elapsed_seconds",`Int 1;"elapsed_seconds",`Int 1];
     `Assoc ["kind",`String "heartbeat_reported";"elapsed_seconds",`Int 1;"message",`String "wrong variant"]]

let rec remove_tree path =
  if Sys.is_directory path then begin
    Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  end else Sys.remove path

let test_autonomous_progress_journal_matches_direct_projection () =
  let module Stream = Masc.Keeper_autonomous_stream in
  let base_path = Filename.temp_dir "masc-native-progress-" "" in
  Fun.protect ~finally:(fun () -> remove_tree base_path) (fun () ->
    Eio_main.run (fun _ ->
      let turn_ref = Ids.Turn_ref.make ~trace_id:"native-progress" ~absolute_turn:1 in
      let stream = Stream.create ~base_path ~keeper_name:"fixture" ~turn_ref in
      let direct = F.create () in
      let send event = Stream.on_event stream event; F.on_event direct event in
      let progress value =
        Stream.on_tool_stream_observation stream (Masc.Keeper_hooks_agent_core.Native_tool_progress
          {block_index=1;tool_call_id=Some "native";progress=value});
        F.on_progress direct ~block_index:1 ~tool_call_id:(Some "native") value in
      send (start_message "response"); send (tool_start ~native:true 1 "native");
      progress (output 3); send (text "Authored text\n"); progress (output 3);
      Stream.on_tool_stream_observation stream (Masc.Keeper_hooks_agent_core.Native_tool_completion
        {block_index=1;tool_call_id=Some "native";completion=Native.end_observed});
      F.on_completion direct ~block_index:1 ~tool_call_id:(Some "native") Native.end_observed;
      send (Agent_core.Types.ContentBlockStop {index=1});
      Stream.finish stream (Stream.Completed {reply="Authored text";turn_outcome=Masc.Keeper_turn_outcome.Visible_reply});
      let path = Journal.turn_journal_path ~base_dir:base_path ~keeper_name:"fixture" ~turn_ref in
      let read () = match Journal.read_journal_path_result path with Ok entries -> entries | Error _ -> fail "journal not readable" in
      let before = read () in
      Stream.on_tool_stream_observation stream (Masc.Keeper_hooks_agent_core.Native_tool_progress
        {block_index=1;tool_call_id=Some "native";progress=output 100});
      check bool "closed autonomous journal cannot grow from late progress" true (before=read ());
      let native_events events = List.filter (function
        | E.Native_tool_start _ | E.Native_tool_progress _ | E.Native_tool_end _ -> true | _ -> false) events in
      check bool "actual autonomous callbacks and direct bridge share identity/order/content" true
        (native_events (List.map (fun (line:Journal.journaled_event) -> line.event) before)=native_events (F.events direct));
      let log = Log.create_for_source ~keeper_name:"fixture" ~source:(Log.Autonomous_turn turn_ref) ~started_at:0. in
      ignore (Log.add_journaled log before);
      match T.tool_calls (T.of_log ~now:2000. log) with
      | [call] -> check (option int) "autonomous replay retains byte sum" (Some 6)
          (Option.bind call.native_progress (fun value -> value.output_bytes))
      | _ -> fail "native autonomous row lost"))

type side_observation =
  | Progress of Native.progress
  | Completion

let test_split_secret_held_across_native_side_events () =
  let module Stream = Masc.Keeper_autonomous_stream in
  let module Secret = Masc.Keeper_secret_redaction in
  List.iter (fun thinking ->
    List.iter (fun observation ->
      let base_path = Filename.temp_dir "masc-progress-redaction-" "" in
      Fun.protect ~finally:(fun () -> remove_tree base_path) (fun () ->
        Eio_main.run (fun _ ->
          let keeper_name = "fixture" in
          let secret = "forest-cobalt-window-private-value" in
          let prefix = "forest-cobalt-" in
          let suffix = String.sub secret (String.length prefix) (String.length secret - String.length prefix) in
          let secret_file = Secret.ssh_remote_token_file ~base_path ~keeper_name in
          Fs_compat.mkdir_p (Filename.dirname secret_file);
          Out_channel.with_open_bin secret_file (fun channel -> output_string channel secret);
          let redaction = Secret.snapshot ~base_path ~keeper_name in
          let expected_text = Secret.redact_text redaction (secret ^ "\n") in
          check bool "fixture has a configured exact secret" false (expected_text=secret ^ "\n");
          let direct = F.create ~redaction () in
          let turn_ref = Ids.Turn_ref.make ~trace_id:"split-secret-progress" ~absolute_turn:1 in
          let stream = Stream.create ~base_path ~keeper_name ~turn_ref in
          let journal_path = Journal.turn_journal_path ~base_dir:base_path ~keeper_name ~turn_ref in
          let read () = match Journal.read_journal_path_result journal_path with
            | Ok lines -> List.map (fun (line:Journal.journaled_event) -> line.event) lines
            | Error _ -> fail "autonomous journal not readable" in
          let send event = F.on_event direct event; Stream.on_event stream event in
          let delta value = Agent_core.Types.ContentBlockDelta {index=0;
            delta=(if thinking then ThinkingDelta value else TextDelta value)} in
          let fragments events = List.filter_map (function
            | E.Text_delta value | E.Agent_core_thinking_delta {delta=value; _} -> Some value
            | _ -> None) events in
          let check_held events =
            check (list string) "native progress cannot release a secret prefix" [] (fragments events);
            check bool "side observation remains visible while text is withheld" true
              (List.exists (function E.Native_tool_progress _ | E.Native_tool_end _ -> true | _ -> false) events) in
          send (start_message "response");
          send (delta prefix);
          send (tool_start ~native:true 1 "native");
          (match observation with
           | Progress progress ->
             F.on_progress direct ~block_index:1 ~tool_call_id:(Some "native") progress;
             Stream.on_tool_stream_observation stream (Masc.Keeper_hooks_agent_core.Native_tool_progress
               {block_index=1;tool_call_id=Some "native";progress})
           | Completion ->
             F.on_completion direct ~block_index:1 ~tool_call_id:(Some "native") Native.end_observed;
             Stream.on_tool_stream_observation stream (Masc.Keeper_hooks_agent_core.Native_tool_completion
               {block_index=1;tool_call_id=Some "native";completion=Native.end_observed});
             (* All official adapters follow the native outcome with this
                indexed generic stop. It must not close model index zero. *)
             send (Agent_core.Types.ContentBlockStop {index=1}));
          check_held (F.events direct); check_held (read ());
          send (delta (suffix ^ "\n"));
          List.iter (fun events ->
            check string "same content channel redacts across side progress" expected_text
              (String.concat "" (fragments events));
            check bool "concatenated released content cannot reconstruct the secret" false
              (Astring.String.is_infix ~affix:secret (String.concat "" (fragments events)));
            let serialized = `List (List.map Journal.keeper_chat_event_to_json events) |> Yojson.Safe.to_string in
            check bool "secret is absent from persisted event payloads" false
              (Astring.String.is_infix ~affix:secret serialized);
            let order = List.filter_map (function
              | E.Native_tool_progress _ | E.Native_tool_end _ -> Some "native-observation"
              | E.Text_delta _ | E.Agent_core_thinking_delta _ -> Some "safe-content"
              | _ -> None) events in
            check bool "native observations remain visible before safely released content" true
              (match order with
               | "native-observation" :: (_ :: _ as content) ->
                   List.for_all (String.equal "safe-content") content
               | _ -> false)) [F.events direct;read ()];
          let live,replay = F.snapshots direct in
          List.iter (fun log ->
            let transcript = T.of_log ~now:2000. log in
            let visible = if thinking then String.concat "\n" (T.thinking_lines transcript)
              else T.text transcript in
            check bool "neither live nor replay reconstructs the secret" false
              (Astring.String.is_infix ~affix:secret visible)) [live;replay];
          Stream.finish stream (Stream.Completed
            {reply="Safe final response";turn_outcome=Masc.Keeper_turn_outcome.Visible_reply}))))
      [Progress (output 3); Progress (Native.Message_reported {message="still working"});
       Progress (Native.Heartbeat_reported {elapsed_seconds=30}); Completion]) [false;true]

let test_held_content_reserves_its_index_before_native_headers () =
  let module Stream = Masc.Keeper_autonomous_stream in
  List.iter (fun thinking ->
    let base_path = Filename.temp_dir "masc-content-occupancy-" "" in
    Fun.protect ~finally:(fun () -> remove_tree base_path) (fun () -> Eio_main.run (fun _ ->
      let turn_ref = Ids.Turn_ref.make ~trace_id:"held-occupancy" ~absolute_turn:1 in
      let stream = Stream.create ~base_path ~keeper_name:"fixture" ~turn_ref in
      let direct = F.create () in
      let send event = F.on_event direct event; Stream.on_event stream event in
      send (start_message "response");
      send (Agent_core.Types.ContentBlockDelta {index=0;
        delta=(if thinking then ThinkingDelta "still pending" else TextDelta "still pending")});
      send (tool_start ~native:true 0 "wrong-owner");
      let path = Journal.turn_journal_path ~base_dir:base_path ~keeper_name:"fixture" ~turn_ref in
      let journal = match Journal.read_journal_path_result path with
        | Ok lines -> List.map (fun (line:Journal.journaled_event) -> line.event) lines
        | Error _ -> fail "missing occupancy journal" in
      List.iter (fun events ->
        check bool "a withheld model index cannot become a native tool row" false
          (List.exists (function E.Native_tool_start _ -> true | _ -> false) events);
        check bool "the model prefix stays undisclosed" false
          (List.exists (function E.Text_delta _ | E.Agent_core_thinking_delta _ -> true | _ -> false) events))
        [F.events direct; journal];
      Stream.finish stream Stream.Cancelled))) [false;true]

let test_progress_numeric_wire_boundary () =
  let decode kind field wire = Native.progress_of_json
      (`Assoc ["kind",`String kind;field,Yojson.Safe.from_string wire]) in
  List.iter (fun (wire,expected) ->
    (match decode "output_observed" "byte_count" wire with
     | Ok (Native.Output_observed {byte_count}) -> check int "exact byte count" expected byte_count
     | Ok _ | Error _ -> fail ("safe byte count rejected: " ^ wire));
    (match decode "heartbeat_reported" "elapsed_seconds" wire with
     | Ok (Native.Heartbeat_reported {elapsed_seconds}) -> check int "exact provider seconds" expected elapsed_seconds
     | Ok _ | Error _ -> fail ("safe provider seconds rejected: " ^ wire)))
    ["1",1;"1.0",1;"1e0",1;"9007199254740991",9_007_199_254_740_991;
     "9007199254740991.0",9_007_199_254_740_991];
  check bool "zero is not an output byte observation" true
    (Result.is_error (decode "output_observed" "byte_count" "0.0"));
  check bool "zero provider seconds is valid" true
    (decode "heartbeat_reported" "elapsed_seconds" "-0.0" = Ok (Native.Heartbeat_reported {elapsed_seconds=0}));
  List.iter (fun wire -> List.iter (fun (kind,field) ->
    check bool (field ^ " rejects " ^ wire) true (Result.is_error (decode kind field wire)))
    ["output_observed","byte_count";"heartbeat_reported","elapsed_seconds"])
    ["-1";"0.5";"9007199254740992";"9007199254740992.0";
     "9007199254740993";"9223372036854775808";"1e309";"\"1\"";"null"]

let test_native_occurrence_numeric_live_and_projection () =
  let module Projection = Masc_tui_keeper_chat_projection in
  let request = Projection.create_request ~keeper_name:"fixture" ~message:"numeric" () in
  let run_id = "keeper-operation-run-" ^ request.request_id in
  let acceptance = "data: " ^ Yojson.Safe.to_string (`Assoc [
      "type",`String "CUSTOM";"threadId",`String "default";"timestamp",`Float 1000.;
      "name",`String "KEEPER_CHAT_OPERATION_ACCEPTED";"value",`Assoc [
        "operation_id",`String request.request_id;"state",`String "Running";"queued_count",`Int 0]]) ^ "\n\n" in
  let native : E.native_tool = {occurrence={stream_scope=1;block_index=2;provider_message_id=None};
      tool_call_id=Some "native-numeric";tool_call_name=Some "Read"} in
  let events = [E.Run_started {run_id;thread_id="keeper:fixture"};
      E.Text_message_start {message_id="keeper-operation-message-" ^ request.request_id;role=E.Assistant};
      E.Text_delta "body"; E.Native_tool_start native;
      E.Native_tool_progress (native,output 1); E.Native_tool_end (native,Native.end_observed);
      E.Reply_details {reply="body";turn_outcome=Masc.Keeper_turn_outcome.Visible_reply;
        turn_ref=Ids.Turn_ref.make ~trace_id:"numeric-wire" ~absolute_turn:1};
      E.Text_message_end; E.Run_finished {run_id}] in
  let wire scope index =
    let _,wire = List.fold_left (fun (state,wire) source ->
      let state,event = Server_keeper_chat_agui_projection.project ~timestamp:1000.
          ~redact_text:Fun.id state source in
      match event with
      | None -> fail "missing projected fixture event"
      | Some event ->
          let event = match source with
            | E.Native_tool_start _ | E.Native_tool_progress _ | E.Native_tool_end _ ->
                let custom_value = Option.map (function
                  | `Assoc fields -> `Assoc (("toolStreamScope",scope)::("toolCallBlockIndex",index)::
                      List.remove_assoc "toolStreamScope" (List.remove_assoc "toolCallBlockIndex" fields))
                  | _ -> fail "native event must have an object payload") event.Ag_ui.custom_value in
                {event with Ag_ui.custom_value}
            | _ -> event in
          state,wire ^ Ag_ui.event_to_sse event)
      (Server_keeper_chat_agui_projection.initial,acceptance) events in wire in
  List.iter (fun (scope,index,expected_scope,expected_index) ->
    let wire = wire scope index in
    (match Projection.decode_response ~request wire with
     | Ok (Projection.Turn_completed {reply="body";_}) -> ()
     | Ok _ -> fail "numeric occurrence lost terminal reply"
     | Error error -> fail (Projection.stream_error_to_string error));
    let deltas = Live.feed (Live.create ()) wire in
    check bool "live feed accepts the same occurrence numeric values" false
      (List.exists (fun (item:Live.observed_delta) -> match item.delta with Live.Undecodable _ -> true | _ -> false) deltas);
    let identities = List.filter_map (fun (item:Live.observed_delta) -> match item.delta with
      | Live.Native_tool_started {occurrence;_}
      | Live.Native_tool_progress {occurrence;_}
      | Live.Native_tool_ended {occurrence;_} -> Some (occurrence.stream_scope,occurrence.block_index)
      | _ -> None) deltas in
    check (list (pair int int)) "start, progress and end retain one exact numeric occurrence"
      [expected_scope,expected_index;expected_scope,expected_index;expected_scope,expected_index] identities)
    [`Float 1.,`Float 2.,1,2;
     Yojson.Safe.from_string "1e0",Yojson.Safe.from_string "2e0",1,2;
     `Int 9_007_199_254_740_991,`Float 9_007_199_254_740_991.,9_007_199_254_740_991,9_007_199_254_740_991];
  List.iter (fun invalid -> List.iter (fun (scope,index) ->
    let wire = wire scope index in
    check bool "strict response rejects unsafe or nonintegral native identity" true
      (Result.is_error (Projection.decode_response ~request wire));
    let deltas = Live.feed (Live.create ()) wire in
    check int "each native event is unreadable" 3
      (List.length (List.filter (fun (item:Live.observed_delta) -> match item.delta with Live.Undecodable _ -> true | _ -> false) deltas));
    check bool "invalid occurrence never reaches native activity" false
      (List.exists (fun (item:Live.observed_delta) -> match item.delta with
        | Live.Native_tool_started _ | Live.Native_tool_progress _ | Live.Native_tool_ended _ -> true
        | _ -> false) deltas)) [invalid,`Int 2;`Int 1,invalid])
    [`Int 9_007_199_254_740_992;`Float 9_007_199_254_740_992.;`Float 1.5;`Int (-1);`String "1"]

let () = run "native tool progress" ["contract",[
  test_case "native occurrence numeric parity through actual wire consumers" `Quick test_native_occurrence_numeric_live_and_projection;
  test_case "progress JSON safe-integer boundary" `Quick test_progress_numeric_wire_boundary;
  test_case "same deltas count twice, same journal seq once" `Quick test_replayed_sequence_and_model_signal;
  test_case "exact current active native scope" `Quick test_exact_active_scope_only;
     test_case "heartbeat provider time and model noninterference" `Quick test_heartbeat_reported_time_is_not_local_elapsed;
  test_case "split secrets stay held across native lifecycle and progress" `Quick test_split_secret_held_across_native_side_events;
  test_case "held model content reserves its index" `Quick test_held_content_reserves_its_index_before_native_headers;
  test_case "strict nested progress payload" `Quick test_strict_nested_wire_and_journal;
  test_case "autonomous actual journal matches direct projection" `Quick test_autonomous_progress_journal_matches_direct_projection]]
