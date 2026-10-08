open Alcotest

module T = Masc_tui_types
module Live = Masc_tui_keeper_chat_live
module Log = Masc_tui_keeper_chat_log

let test_response_order_in_every_reasoning_view () =
  let cache = Masc_tui_ansi.terminal_size_cache in
  let previous = Masc_tui_ansi.get_terminal_size () in
  let size value = ignore (Masc_tui_render_schedule.Terminal_size_cache.refresh
      cache ~probe:(fun () -> Some value)) in
  Fun.protect ~finally:(fun () -> size previous) (fun () ->
    List.iter (fun columns ->
    size (60, columns);
    List.iter (fun origin ->
    List.iter (fun visibility ->
      let state = T.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2. () in
      state.view <- T.Keepers T.Keeper_message;
      state.msg_target_keeper_name <- Some "alpha";
      state.roster_pane_preference <- Masc_tui_roster_pane.Hidden;
      state.msg_reasoning_visibility <- visibility;
      state.msg_origin_display <- origin;
      let log = T.turn_log_create ~keeper_name:"alpha" ~request_id:"response" ~started_at:1. in
      let occurrence = Live.{stream_scope=0;block_index=1;
        provider_message_id=Some "before-tool";tool_call_id=Some "read"} in
      let events = [Live.Run_started;
        Live.Runtime_attempt_started {runtime_id=Some "first";attempt_index=Some 0};
        Live.Thinking "EARLIER_ATTEMPT_THOUGHT";
        Live.Text "EARLIER_ATTEMPT_SPEECH";
        Live.Runtime_attempt_started {runtime_id=Some "second";attempt_index=Some 1};
        Live.Text "EARLIER_COMMENTARY";
        Live.Tool_started {occurrence;tool_name="read_file"};
        Live.Tool_ended {occurrence};
        Live.Tool_result {occurrence;execution_id="exec-read"};
        Live.Stream_model_started {message_id=Some "final";model="observed";usage=None};
        Live.Text "RESPONSE_PREFIX";
        Live.Thinking "RESPONSE_THOUGHT";
        Live.Text "RESPONSE_SUFFIX";
        Live.Reply_details {reply="RESPONSE_PREFIX\nRESPONSE_SUFFIX";
          turn_outcome=Masc.Keeper_turn_outcome.Visible_reply;turn_ref="trace#1"};
        Live.Run_finished] in
      List.iteri (fun seq delta -> T.turn_log_add ~now:(1. +. float_of_int seq)
          log ~seq:(Some seq) delta) events;
      Log.commit log.tl_log;
      T.hold_settled_log state log;
      let frame, _ = Masc_tui_render_chat.render_keeper_message state in
      let screen = frame.Masc_tui_frame_presenter.lines
        |> List.map Masc_tui_theme.strip_sgr |> String.concat "\n" in
      let count marker = List.length (Astring.String.cuts ~sep:marker screen) - 1 in
      check int "earlier commentary stays outside final-response observation" 1
        (count "EARLIER_COMMENTARY");
      List.iter (fun marker -> check int ("observed and canonical sections: " ^ marker) 2 (count marker))
        ["RESPONSE_PREFIX";"RESPONSE_SUFFIX"];
      check bool "canonical authority has a gutter label" true (count "FINAL" > 0);
      check bool "streamed fragments have an observation label" true (count "SAYING" > 0);
      (match origin with
       | Masc_tui_message_layout.Origin_row ->
           check int "retry origin is named once without repeated anonymous headings" 1
             (count "↺1")
       | Origin_inline | Origin_bare -> ());
      let positions marker =
        let rec walk offset = function
          | [] | [_] -> []
          | part :: rest -> let position = offset + String.length part in
              position :: walk (position + String.length marker) rest in
        walk 0 (Astring.String.cuts ~sep:marker screen) in
      let first marker = List.hd (positions marker) in
      check bool "observed text remains before the final area" true
        (first "RESPONSE_PREFIX" < first "RESPONSE_SUFFIX"
         && first "RESPONSE_SUFFIX" < first "FINAL");
      (match visibility with
       | T.Reasoning_hidden -> ()
       | Reasoning_folded | Reasoning_full ->
           check bool "observed A/thinking/B order is retained" true
             (first "RESPONSE_PREFIX" < first "RESPONSE_THOUGHT"
              && first "RESPONSE_THOUGHT" < first "RESPONSE_SUFFIX"));
      check int "thinking visibility preserves other response stretches"
        (match visibility with T.Reasoning_hidden -> 0 | Reasoning_folded | Reasoning_full -> 1)
        (count "RESPONSE_THOUGHT"))
      [T.Reasoning_hidden;Reasoning_folded;Reasoning_full])
      [Masc_tui_message_layout.Origin_inline; Origin_row; Origin_bare]) [80;140])

let () = run "chat response origins"
    ["render", [test_case "observed response across reasoning modes" `Quick
      test_response_order_in_every_reasoning_view]]
