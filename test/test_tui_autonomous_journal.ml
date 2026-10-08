open Alcotest

module Log = Masc_tui_keeper_chat_log
module Journal = Masc.Keeper_chat_event_log
module E = Masc.Keeper_chat_events
module Types = Masc_tui_types
module Observer = Masc_tui_observer

let turn_ref = Ids.Turn_ref.make ~trace_id:"trace-journal-fixture" ~absolute_turn:7
let source = Log.Autonomous_turn turn_ref

let test_source_routes_and_decodes () =
  let raw = Ids.Turn_ref.to_string turn_ref in
  let page = `Assoc ["schema", `String "masc.keeper_turn_events.v1";
    "turn_ref", `String raw; "events", `List []; "has_more", `Bool false;
    "next_since_seq", `Null; "next_since_offset", `Int 0] in
  (match Log.decode_events_page page with
   | Ok decoded -> check bool "autonomous source retained" true (decoded.source = source)
   | Error detail -> fail detail);
  check string "autonomous URL has no operation query"
    ("/api/v1/keepers/alpha/turns/" ^ raw ^ "/events?limit=20&since_seq=4")
    (Log.journal_path ~encode_value:Fun.id ~keeper_name:"alpha" ~source
       ~since_seq:(Journal.After_seq 4) ~since_offset:Journal.first_row ~limit:20);
  check string "operation URL remains separate"
    "/api/v1/keepers/alpha/chat/events?operation_id=op-1&since_seq=4&limit=20"
    (Log.journal_path ~encode_value:Fun.id ~keeper_name:"alpha" ~source:(Log.Operation "op-1")
       ~since_seq:(Journal.After_seq 4) ~since_offset:Journal.first_row ~limit:20);
  let log = Log.create_for_source ~keeper_name:"alpha" ~source ~started_at:10. in
  check bool "log retains typed provenance" true (Log.source log = source);
  check string "display key joins persisted turn rows" raw (Log.request_id log)

let test_notification_only_triggers_journal_read () =
  let wire = "data: " ^ Yojson.Safe.to_string (`Assoc [
    "type", `String "keeper_turn_stream_event"; "name", `String "alpha";
    "turn_ref", `String (Ids.Turn_ref.to_string turn_ref);
    "seq", `Int 2; "ts_unix", `Float 12.]) ^ "\n\n" in
  let events = Observer.feed (Observer.create ()) wire in
  (match events with
   | [{Observer.decoded=Event (Keeper_turn_stream_frame {keeper="alpha"; turn_ref=observed; seq=2; at=12.}); _}] ->
       check bool "exact autonomous turn observed" true (observed = turn_ref)
   | _ -> fail "autonomous journal growth was not decoded");
  let state = Types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2. () in
  let log = Types.turn_log_create_for_source ~keeper_name:"alpha" ~source ~started_at:10. in
  let line seq ts event : Journal.journaled_event = {seq; ts; event} in
  let lines = [line 0 10. (E.Run_started {run_id="autonomous-run"; thread_id="keeper:alpha"});
    line 1 11. (E.Text_delta "first")] in
  ignore (Types.turn_log_add_journaled log lines);
  Types.hold_settled_log state log;
  (match Types.journal_follow_for_source state ~keeper_name:"alpha" ~source
      ~seq:(Some 2) ~at:12. with
   | Types.Follow_read {since_seq=Journal.After_seq 1; _} -> ()
   | _ -> fail "notification did not resume after the last journal position");
  check int "notice itself appended no content" 2 (List.length (Log.entries log.tl_log));
  ignore (Types.turn_log_add_journaled log (lines @ [line 2 12. (E.Text_delta " second")]));
  let texts = Log.entries log.tl_log |> List.filter_map (fun entry ->
    match entry.Log.delta with Masc_tui_keeper_chat_live.Text text -> Some text | _ -> None) in
  check (list string) "journal overlap keeps ordered text once" ["first"; " second"] texts

let test_cold_open_discovery () =
  let running : Masc.Tui_decode.keeper_turn_row =
    {ktr_keeper_name="alpha"; ktr_chat_control_token=None;
     ktr_state=Keeper_turn_running {lane=Turn_lane_autonomous; started_at_unix=10.;
       interrupt_token="stop-token"; turn_ref=Some turn_ref; preview=None}} in
  check bool "current turn discovered without observer event" true
    (Types.autonomous_journal_candidates ~keeper_name:"alpha" [running] = [source, 10.]);
  check int "other keeper excluded" 0
    (List.length (Types.autonomous_journal_candidates ~keeper_name:"other" [running]));
  let json = `List [`Assoc ["role", `String "assistant";
    "autonomous_turn", `Assoc ["turn_id", `String (Ids.Turn_ref.to_string turn_ref)];
    "content", `String "done"; "ts", `Float 12.;
    "turn_ref", `String (Ids.Turn_ref.to_string turn_ref)]] in
  (match Masc_tui_keeper_chat_history.rows_of_json json with
   | Error detail -> fail detail
   | Ok decoded ->
       check bool "history names its autonomous journal" true
         (List.mem source (List.filter_map Types.journal_source_of_history decoded.rows)));
  check int "held source not fetched twice" 0
    (List.length (Types.journal_source_fetch_targets ~keeper_name:"alpha" ~held:["alpha", source]
       ~unavailable:[] [source, 10.; source, 12.]))

let test_poll_excerpt_defers_only_to_exact_journal_text () =
  let check_case ~journal_turn ~delta ~expected =
    let state = Types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2. () in
    state.view <- Types.Keepers Types.Keeper_message;
    state.msg_target_keeper_name <- Some "alpha";
    state.roster_pane_preference <- Masc_tui_roster_pane.Hidden;
    state.keeper_turns <- [{Masc.Tui_decode.ktr_keeper_name="alpha"; ktr_chat_control_token=None;
      ktr_state=Keeper_turn_running {lane=Turn_lane_autonomous; started_at_unix=10.;
        interrupt_token="stop-token"; turn_ref=Some turn_ref;
        preview=Some {ktp_status_text="working"; ktp_updated_at_unix=12.;
          ktp_text_tail="latest answer"; ktp_last_tool=None}}}];
    let log = Types.turn_log_create_for_source ~keeper_name:"alpha"
        ~source:(Log.Autonomous_turn journal_turn) ~started_at:10. in
    Types.turn_log_add ~now:10. log ~seq:(Some 0) Masc_tui_keeper_chat_live.Run_started;
    Types.turn_log_add ~now:11. log ~seq:(Some 1) delta;
    Types.hold_settled_log state log;
    let frame, _ = Masc_tui_render_chat.render_keeper_message state in
    check bool "polled excerpt respects exact turn identity and text availability" (expected = 1)
      (List.exists (Astring.String.is_infix ~affix:"최근 출력 발췌") frame.Masc_tui_frame_presenter.lines)
  in
  let cache = Masc_tui_ansi.terminal_size_cache in
  let previous = Masc_tui_ansi.get_terminal_size () in
  let set_size size = ignore (Masc_tui_render_schedule.Terminal_size_cache.refresh
      cache ~probe:(fun () -> Some size)) in
  Fun.protect ~finally:(fun () -> set_size previous) (fun () ->
    set_size (50, 120);
    check_case ~journal_turn:turn_ref ~delta:(Masc_tui_keeper_chat_live.Text "latest answer") ~expected:0;
    check_case ~journal_turn:(Ids.Turn_ref.make ~trace_id:"other-trace" ~absolute_turn:7)
      ~delta:(Masc_tui_keeper_chat_live.Text "another turn") ~expected:1;
    check_case ~journal_turn:turn_ref ~delta:(Masc_tui_keeper_chat_live.Thinking "considering") ~expected:1)

let test_autonomous_checkpoint_closes_its_source () =
  let state = Types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2. () in
  let log = Types.turn_log_create_for_source ~keeper_name:"alpha" ~source ~started_at:10. in
  Types.turn_log_add ~now:10. log ~seq:(Some 0) Masc_tui_keeper_chat_live.Run_started;
  Types.turn_log_add ~now:11. log ~seq:(Some 1)
    (Masc_tui_keeper_chat_live.Reply_details {reply="";
      turn_outcome=Masc.Keeper_turn_outcome.Continuation_checkpoint;
      turn_ref=Ids.Turn_ref.to_string turn_ref});
  Types.turn_log_add ~now:12. log ~seq:(Some 2) Masc_tui_keeper_chat_live.Run_finished;
  Log.commit log.tl_log;
  Types.hold_settled_log state log;
  check bool "autonomous checkpoint has ended" true
    (Masc_tui_keeper_chat_transcript.phase log.tl_transcript = Stream_ended);
  check bool "recorded end owns the completed turn" true (Types.turn_log_holds_the_turn log);
  check bool "not an open operation awaiting continuation" false
    (Masc_tui_keeper_chat_transcript.awaiting_continuation log.tl_transcript);
  (match Types.journal_follow_for_source state ~keeper_name:"alpha"
      ~source ~seq:None ~at:13. with
   | Types.Follow_nothing -> ()
   | _ -> fail "ended autonomous checkpoint requested another journal read")

let () =
  run "TUI autonomous journal"
    ["consumer", [test_case "typed sources select separate routes" `Quick test_source_routes_and_decodes;
      test_case "observer only triggers ordered journal reads" `Quick test_notification_only_triggers_journal_read;
      test_case "cold open discovers current and historical journals" `Quick test_cold_open_discovery;
      test_case "polled excerpt yields only to exact journal text" `Quick test_poll_excerpt_defers_only_to_exact_journal_text;
      test_case "autonomous checkpoint closes its journal source" `Quick test_autonomous_checkpoint_closes_its_source]]
