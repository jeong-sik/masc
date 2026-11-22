(* #35986: a failed provider attempt must leave the same consumer able to
   receive the next candidate's answer and the turn's authoritative terminal. *)
open Alcotest

module E = Masc.Keeper_chat_events
module Bridge = Masc.Keeper_chat_agent_core_stream_bridge
module Signal = Masc.Keeper_chat_run_signal
module Journal = Masc.Keeper_chat_event_log
module Audit = Masc.Keeper_chat_journal_audit
module Store = Masc.Keeper_chat_store
module Projection = Server_keeper_chat_agui_projection

type failure = Provider_error | Provider_timeout

type retry_stream =
  { failed_attempt : E.keeper_chat_event list
  ; next_response : E.keeper_chat_event list
  ; completion : E.keeper_chat_event list
  ; turn_ref : Ids.Turn_ref.t
  }

let answer = "answer from candidate one"

let retry_stream failure =
  let open Agent_core.Types in
  let translate ~stream_scope state events =
    let state, reversed = List.fold_left (fun (state, reversed) event ->
      let translated = Bridge.translate ~redact_text:Fun.id
        ~base_dir:(Filename.get_temp_dir_name ()) ~stream_scope state event in
      translated.bridge_state, List.rev_append translated.chat_events reversed)
      (state, []) events in
    state, List.rev reversed
  in
  let failure = match failure with
    | Provider_error -> SSEError
        { message = "candidate unavailable"; error_type = Some "insufficient_quota"
        ; provider_status = None; report = Provider_stated; raw = "{}" }
    | Provider_timeout -> Timeout "provider stream stopped producing" in
  let failed, failed_events = translate ~stream_scope:0 (Bridge.empty_state ())
    [MessageStart {id="candidate-zero"; model="model-zero"; usage=None}; failure] in
  let next = Bridge.start_runtime_attempt ~runtime_id:"candidate-one" ~attempt_index:1
    ~previous_scope:E.Abandon_previous_scope failed in
  let finished, response_events = translate ~stream_scope:1 next.bridge_state
    [ MessageStart {id="candidate-one"; model="model-one"; usage=None}
    ; ContentBlockStart {index=0; content_type="text"; tool_id=None; tool_name=None}
    ; ContentBlockDelta {index=0; delta=TextDelta answer}
    ; ContentBlockStop {index=0}
    ; MessageDelta {stop_reason=Some EndTurn; usage=None}
    ; MessageStop ] in
  let turn_ref = Ids.Turn_ref.make ~trace_id:"retry-consumers" ~absolute_turn:1 in
  { failed_attempt =
      E.Run_started {run_id="retry-run"; thread_id="retry-thread"}
      :: E.Text_message_start {message_id="retry-run:assistant"; role=E.Assistant}
      :: failed_events
  ; next_response = next.chat_events @ response_events
  ; completion =
      [ E.Reply_details
          {reply=answer; turn_outcome=Masc.Keeper_turn_outcome.Visible_reply; turn_ref
          ; terminal_stream_scope=Bridge.terminal_text_scope finished}
      ; E.Text_message_end
      ; E.Run_finished {run_id="retry-run"} ]
  ; turn_ref }

let consume fixture run =
  Eio_main.run @@ fun _ ->
  let events = E.create () in
  List.iter (E.publish events)
    (fixture.failed_attempt @ fixture.next_response @ fixture.completion);
  E.close events;
  let outcomes = ref [] in
  run events (fun result -> outcomes := result :: !outcomes);
  List.rev !outcomes

let test_slack failure () =
  let fixture = retry_stream failure in
  let delivered = ref [] in
  let diagnostics = ref 0 in
  let outcomes = consume fixture (fun events settle ->
    Masc.Keeper_chat_slack.For_testing.adapter_loop ~events
      ~send_plain:(fun ~content:_ -> incr diagnostics; Ok ())
      ~send_blocks:(fun ~content ~blocks:_ -> delivered := content :: !delivered; Ok ())
      ~on_send_result:(fun result ->
        check (list string) "the next answer is delivered before settlement" [answer] !delivered;
        settle result)
      ()) in
  check int "the same adapter observed the failed candidate" 1 !diagnostics;
  check bool "one successful terminal settlement" true (outcomes = [Ok ()]);
  check (list string) "the next candidate is delivered once" [answer] !delivered

let test_discord failure () =
  let fixture = retry_stream failure in
  let delivered = ref None in
  let posts = ref 0 in
  let diagnostics = ref 0 in
  let outcomes = consume fixture (fun events settle ->
    Masc.Keeper_chat_discord.For_testing.adapter_loop ~token:"test-token"
      ~channel_id:"test-channel" ~events
      ~post_message:(fun ~nonce:_ ~content ->
        incr posts; delivered := Some content; Ok "reply-message")
      ~edit_message:(fun ~message_id:_ ~content -> delivered := Some content; Ok ())
      ~send_message:(fun ~content:_ -> incr diagnostics; Ok ())
      ~on_send_result:(fun result ->
        check (option string) "the next answer is delivered before settlement" (Some answer) !delivered;
        settle result)
      ()) in
  check int "the same adapter observed the failed candidate" 1 !diagnostics;
  check bool "one successful terminal settlement" true (outcomes = [Ok ()]);
  check int "the next candidate owns one reply message" 1 !posts;
  check (option string) "the reply holds the complete next answer" (Some answer) !delivered

let rec remove_tree path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path
    end else Sys.remove path

let with_base f =
  let base = Filename.temp_file "keeper-retry-consumers" "" in
  Sys.remove base;
  Unix.mkdir base 0o700;
  Fun.protect ~finally:(fun () -> remove_tree base) (fun () -> f base)

let test_tui_and_journal failure () =
  with_base @@ fun base_dir ->
  Eio_main.run @@ fun _ ->
  let fixture = retry_stream failure in
  let keeper_name = "retry-consumers" and operation_id = "retry-operation" in
  let journal = Journal.open_journal ~base_dir ~keeper_name ~operation_id () in
  let projection = ref Projection.initial in
  let wire_frames = ref [] in
  let events = E.create ~on_publish:(fun ~seq ~ts event ->
    Journal.append journal ~seq ~ts event;
    let next, projected = Projection.project ~timestamp:ts ~redact_text:Fun.id !projection event in
    projection := next;
    Option.iter (fun ev ->
      let sse = Ag_ui.event_to_sse ~id:seq ev in
      Sse_wire.data_payloads_of_stream sse
      |> List.iter (fun payload ->
        wire_frames := Yojson.Safe.from_string payload :: !wire_frames))
      projected) () in
  let frames () = List.rev !wire_frames in
  let entries () = match Journal.read_journal journal with
    | Ok entries -> entries
    | Error _ -> fail "the published journal could not be read" in
  let frame_type json = Yojson.Safe.Util.(json |> member "type" |> to_string) in
  let custom_name json =
    if String.equal (frame_type json) "CUSTOM" then
      Some Yojson.Safe.Util.(json |> member "name" |> to_string)
    else None in
  let terminals () = frames () |> List.filter_map (fun json ->
    match frame_type json with
    | "RUN_FINISHED" -> Some true
    | "RUN_ERROR" -> Some false
    | _ -> None) in
  let replies () = frames () |> List.filter_map (fun json ->
    if custom_name json = Some "KEEPER_REPLY_DETAILS" then
      Some Yojson.Safe.Util.(json |> member "value" |> member "reply" |> to_string)
    else None) in
  let before_completion label =
    check (list bool) (label ^ ": wire remains open") [] (terminals ());
    check (list string) (label ^ ": no final reply invented") [] (replies ());
    check (testable Audit.pp_verdict Audit.equal_verdict)
      (label ^ ": journal has no turn terminal") Audit.Journal_truncated
      (Audit.compare (entries ()) []);
    match Journal.next_sequence ~require_existing:true journal with
    | Error (Journal.Journal_corrupt _) -> ()
    | Error _ -> fail "the journal refused continuation for an unrelated read failure"
    | Ok _ -> fail "the unfinished turn was admitted as a completed journal segment" in
  List.iter (E.publish events) fixture.failed_attempt;
  before_completion "candidate failure";
  let diagnostics = frames () |> List.filter (fun json ->
    custom_name json = Some "KEEPER_STREAM_PROTOCOL_ERROR") in
  check int "the same wire consumer observed the failed candidate" 1 (List.length diagnostics);
  List.iter (E.publish events) fixture.next_response;
  before_completion "next candidate MessageStop";
  List.iter (E.publish events) fixture.completion;
  E.close events;
  check (list bool) "wire sees one successful authoritative terminal" [true] (terminals ());
  check (list string) "wire receives the next candidate's final answer" [answer] (replies ());
  let wire_attempts = frames () |> List.filter_map (fun json ->
    if custom_name json = Some "KEEPER_RUNTIME_ATTEMPT_STARTED" then
      Some Yojson.Safe.Util.(json |> member "value" |> member "attempt_index" |> to_int)
    else None) in
  check (list int) "the same wire consumer advanced to the next attempt" [1] wire_attempts;
  let persisted = entries () in
  let journal_replies = persisted |> List.filter_map (fun (entry : Journal.journaled_event) ->
    match entry.event with E.Reply_details {reply; _} -> Some reply | _ -> None) in
  check (list string) "journal records the same final answer" [answer] journal_replies;
  let terminal_count = List.fold_left (fun count (entry : Journal.journaled_event) ->
    if Signal.is_terminal entry.event then count + 1 else count) 0 persisted in
  check int "the journal records one turn settlement" 1 terminal_count;
  (match Journal.next_sequence ~require_existing:true journal with
   | Ok seq -> check int "continuation starts after the completed segment" (List.length persisted) seq
   | Error _ -> fail "the authoritative completion did not close the journal segment");
  let delivery_key = match Keeper_chat_delivery_identity.Request_id.of_string operation_id with
    | Ok request_id -> Keeper_chat_delivery_identity.Operation request_id
    | Error detail -> fail detail in
  let require = function Ok _ -> () | Error detail -> fail detail in
  require (Store.append_user_message_once ~base_dir ~keeper_name ~delivery_key ~content:"answer" ());
  require (Store.append_assistant_message_once ~base_dir ~keeper_name ~delivery_key
    ~content:answer ~turn_ref:fixture.turn_ref
    ~stream_lifecycle:[Store.Run_started; Store.Text_message_start; Store.Text_message_end; Store.Run_finished] ());
  check (testable Audit.pp_verdict Audit.equal_verdict)
    "the next answer and successful terminal agree with the persisted transcript"
    Audit.Match (Audit.audit_operation ~base_dir ~keeper_name ~operation_id)

let () =
  let cases name test =
    [ test_case (name ^ " after provider error") `Quick (test Provider_error)
    ; test_case (name ^ " after provider timeout") `Quick (test Provider_timeout) ] in
  run "Keeper stream retry consumers"
    [ "Slack", cases "the same adapter receives the next answer" test_slack
    ; "Discord", cases "the same adapter receives the next answer" test_discord
    ; "TUI and journal", cases "only authoritative completion settles the turn" test_tui_and_journal ]
