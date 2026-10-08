open Alcotest

module T = Masc_tui_types
module Live = Masc_tui_keeper_chat_live
module Log = Masc_tui_keeper_chat_log
module Chat = Masc_tui_keeper_chat_projection
module Render = Masc_tui_render_chat
module Layout = Masc_tui_message_layout

let row ?(keeper = "alpha") ~id ~request_id ~role ~text at : T.msg_entry =
  { me_keeper_name = keeper; me_role = role; me_identity = T.Persisted_row id;
    me_turn_phase = T.chat_turn_phase_of_role role; me_turn_sequence = None;
    me_operation_seq = 0; me_text = text; me_image = Masc_tui_image_preview.No_image;
    me_memory_summary = None; me_journal = []; me_memory_pass = Layout.No_pass;
    me_gate = None; me_submitted_at = None; me_tool_block = None;
    me_skill_block = []; me_timestamp = "00:00:00"; me_request_id = request_id;
    me_at = at }

let user = T.Message_user (T.Sent_by_operator {surface=None})

let state origin =
  let state = T.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2. () in
  state.view <- T.Keepers T.Keeper_message;
  state.msg_target_keeper_name <- Some "alpha";
  state.msg_loaded_keeper <- Some "alpha";
  state.roster_pane_preference <- Masc_tui_roster_pane.Hidden;
  state.msg_origin_display <- origin;
  state

let reply text = Live.Reply_details {
  reply=text; turn_outcome=Masc.Keeper_turn_outcome.Visible_reply; turn_ref="search#1" }

let log state ~id ~at deltas =
  let log = T.turn_log_create ~keeper_name:"alpha" ~request_id:id ~started_at:at in
  List.iteri (fun seq delta ->
    T.turn_log_add ~now:(at +. float_of_int seq) log ~seq:(Some seq) delta) deltas;
  Log.commit log.tl_log;
  T.hold_settled_log state log;
  log

let frame_lines state =
  let frame, clamped = Render.render_keeper_message state in
  Option.iter (T.apply_clamped_scroll state) clamped;
  frame.Masc_tui_frame_presenter.lines
  |> List.map Masc_tui_theme.strip_sgr

let screen state = String.concat "\n" (frame_lines state)

let count text needle = List.length (Astring.String.cuts ~sep:needle text) - 1

let find ?older state needle =
  match Render.keeper_message_find_scroll state ~keeper_name:"alpha"
      ~needle ~older_than:older with
  | None -> fail ("visible conversation match missing: " ^ needle)
  | Some (position, cursor) -> T.apply_clamped_scroll state (T.Message_scroll position); cursor

let at_sizes run =
  let cache = Masc_tui_ansi.terminal_size_cache in
  let previous = Masc_tui_ansi.get_terminal_size () in
  let size value = ignore (Masc_tui_render_schedule.Terminal_size_cache.refresh
      cache ~probe:(fun () -> Some value)) in
  Fun.protect ~finally:(fun () -> size previous) (fun () ->
    List.iter (fun columns ->
      size (26, columns);
      List.iter run [Layout.Origin_inline; Origin_row; Origin_bare]) [80;140])

let test_settled_reply_and_complete_suffix () = at_sizes (fun origin ->
  let state = state origin in
  state.msg_loaded <- [
    row ~id:"question" ~request_id:"first" ~role:user ~text:"OLDER_USER_NEEDLE" 1.;
    row ~id:"reply" ~request_id:"first" ~role:T.Message_keeper
      ~text:"HELD_REPLY_NEEDLE" 3. ];
  ignore (log state ~id:"first" ~at:1.
    [Live.Run_started; Live.Text "HELD_REPLY_NEEDLE"; reply "HELD_REPLY_NEEDLE"; Live.Run_finished]);
  check int "held reply replaces its durable copy exactly once" 1
    (count (screen state) "HELD_REPLY_NEEDLE");
  ignore (find state "HELD_REPLY_NEEDLE");
  check int "search locates the held reply on the actual frame" 1
    (count (screen state) "HELD_REPLY_NEEDLE");
  for index = 1 to 4 do
    let id = Printf.sprintf "later-%d" index in
    let text = String.concat "\n" (List.init 10 (fun line ->
      Printf.sprintf "later answer %d line %d" index line)) in
    ignore (log state ~id ~at:(10. *. float_of_int index)
      [Live.Run_started; Live.Text text; reply text; Live.Run_finished])
  done;
  state.msg_loaded <- state.msg_loaded @ [row ~id:"broadcast" ~request_id:"outside"
    ~role:(T.Message_user (T.Sent_by_other {speaker="beta"; surface=Some "broadcast"}))
    ~text:"EXTERNAL_BROADCAST" 70.];
  let pending = Chat.create_request ~keeper_name:"alpha" ~message:"PENDING_INPUT" () in
  (match Masc_tui_keeper_chat_queue.push state.msg_queued ~submitted_at:80. pending with
   | Error detail -> fail detail
   | Ok (queue, _) -> state.msg_queued <- queue);
  ignore (find state "OLDER_USER_NEEDLE");
  check int "held answers, broadcast and pending heights count in search scroll" 1
    (count (screen state) "OLDER_USER_NEEDLE"))

let test_repeat_survives_reasoning_visibility_and_backfill () = at_sizes (fun origin ->
  let state = state origin in
  state.msg_reasoning_visibility <- T.Reasoning_full;
  state.msg_loaded <- [row ~id:"old" ~request_id:"old" ~role:user
    ~text:"MATCH_HISTORY" 1.];
  let held = log state ~id:"running" ~at:10.
    [Live.Run_started; Live.Text "MATCH_PROGRESS";
     Live.Thinking "MATCH_REASONING"; Live.Text "MATCH_REPLY"] in
  let latest = find state "MATCH_" in
  let thought = find ~older:latest state "MATCH_" in
  check bool "repeating search visits a distinct journal stretch" true
    (latest.matched_anchor <> thought.matched_anchor);
  state.msg_loaded <- row ~id:"backfill" ~request_id:"backfill" ~role:user
    ~text:"old backfill without the search term" 0. :: state.msg_loaded;
  state.msg_reasoning_visibility <- T.Reasoning_hidden;
  let progress = find ~older:thought state "MATCH_" in
  check bool "hidden matched thought continues to the older stretch" true
    (progress.matched_anchor <> latest.matched_anchor);
  let history = find ~older:progress state "MATCH_" in
  (match history.matched_anchor with
   | T.Search_history _ -> ()
   | T.Search_journal _ | T.Search_admission _ -> fail "search repeated a newer journal item");
  check bool "no older match ends the walk" true
    (Option.is_none (Render.keeper_message_find_scroll state ~keeper_name:"alpha"
       ~needle:"MATCH_" ~older_than:(Some history)));
  T.turn_log_add ~now:20. held ~seq:(Some 4) (reply "MATCH_REPLY canonical");
  T.turn_log_add ~now:21. held ~seq:(Some 5) Live.Run_finished;
  Log.commit held.tl_log;
  let settled = find state "MATCH_REPLY" in
  (match settled.matched_anchor, latest.matched_anchor with
   | T.Search_journal settled, T.Search_journal latest ->
       check bool "multi-stretch final has separate authority in the same source" true
         (settled.canonical_reply && settled.origin <> latest.origin
          && settled.source = latest.source)
   | _ -> fail "journal reply lost its source anchor");
  let observed = find ~older:settled state "MATCH_REPLY" in
  (match observed.matched_anchor, latest.matched_anchor with
   | T.Search_journal observed, T.Search_journal latest ->
       check bool "the observed stretch keeps its identity after the final arrives" true
         (not observed.canonical_reply && observed.origin = latest.origin
          && observed.source = latest.source)
   | _ -> fail "observed response lost its source anchor");
  check bool "hidden reasoning cannot be found as visible speech" true
    (Option.is_none (Render.keeper_message_find_scroll state ~keeper_name:"alpha"
       ~needle:"MATCH_REASONING" ~older_than:None)))

let test_repeat_across_history_journal_replacement () = at_sizes (fun origin ->
  let state = state origin in
  state.msg_loaded <- [
    row ~id:"a" ~request_id:"a" ~role:T.Message_keeper ~text:"MATCH_A" 1.;
    row ~id:"b" ~request_id:"b" ~role:T.Message_keeper ~text:"MATCH_B" 10. ];
  let latest = find state "MATCH_" in
  List.iter (fun (id, at, text) -> ignore (log state ~id ~at
    [Live.Run_started; Live.Text text; reply text; Live.Run_finished]))
    ["a", 1., "MATCH_A"; "b", 10., "MATCH_B"];
  let older = find ~older:latest state "MATCH_" in
  (match older.matched_anchor with
   | T.Search_journal {source=Log.Operation "a"; _} -> ()
   | _ -> fail "history replacement skipped the older journal answer");
  let journal_latest = find state "MATCH_" in
  state.msg_settled_logs <- [];
  let older = find ~older:journal_latest state "MATCH_" in
  (match older.matched_anchor with
   | T.Search_history {reply_source=Some (Log.Operation "a"); _} -> ()
   | _ -> fail "journal replacement skipped the older history answer");
  state.workspace_authority <- T.Workspace_authority 1;
  state.msg_loaded <- [row ~id:"workspace-b" ~request_id:"new"
    ~role:user ~text:"MATCH_NEW_WORKSPACE" 20.];
  ignore (find ~older state "MATCH_");
  check int "same Keeper in another workspace starts its own search" 1
    (count (screen state) "MATCH_NEW_WORKSPACE"))

let test_frame_feedback_consumes_arrival_compensation () = at_sizes (fun origin ->
  let state = state origin in
  state.msg_loaded <- List.init 30 (fun index ->
    row ~id:(string_of_int index) ~request_id:(string_of_int index) ~role:user
      ~text:(Printf.sprintf "ORIGINAL_ROW_%d" index) (float_of_int index));
  T.set_msg_scroll state 8;
  ignore (screen state);
  state.msg_loaded <- state.msg_loaded @ [row ~id:"arrival" ~request_id:"arrival"
    ~role:user ~text:"NEW_ARRIVAL" 50.];
  ignore (screen state);
  let adjusted = state.msg_scroll in
  List.iter (fun _ ->
    ignore (screen state);
    check int "a repaint does not count the same arrival twice" adjusted state.msg_scroll)
    [(); (); ()];
  ignore (find state "ORIGINAL_ROW_0");
  List.iter (fun _ -> check int "absolute search remains visible through frame feedback" 1
    (count (screen state) "ORIGINAL_ROW_0")) [(); (); ()])

let long_answer prefix =
  String.concat "\n" (List.init 100 (fun index -> Printf.sprintf "%s%03d" prefix index))

let visible_line lines needle =
  match List.find_mapi (fun index line ->
    if Astring.String.is_infix ~affix:needle line then Some index else None) lines with
  | Some index -> index
  | None -> fail ("matched physical row not on screen: " ^ needle)

let assert_still_reading state needle =
  let initial = visible_line (frame_lines state) needle in
  let scroll = state.msg_scroll in
  List.iter (fun _ ->
    check int "frame feedback retains the physical row" initial
      (visible_line (frame_lines state) needle);
    check int "frame feedback does not accumulate arrival height" scroll state.msg_scroll)
    [(); (); ()]

let test_long_answer_match_location () = at_sizes (fun origin ->
  List.iter (fun journal ->
    let state = state origin in
    let text = long_answer "LONG_NEEDLE_" in
    if journal then ignore (log state ~id:"long" ~at:1.
      [Live.Run_started; Live.Text text; reply text; Live.Run_finished])
    else state.msg_loaded <- [row ~id:"long" ~request_id:"long"
      ~role:T.Message_keeper ~text 1.];
    List.iter (fun index ->
      let needle = Printf.sprintf "LONG_NEEDLE_%03d" index in
      ignore (find state needle);
      assert_still_reading state needle) [0; 49; 99]) [false; true])

let test_word_wrapped_match_location () = at_sizes (fun origin ->
  let state = state origin in
  (* A single paragraph spans many physical rows at both pane widths. *)
  let words = List.init 300 (fun index -> Printf.sprintf "token%03d" index) in
  let text = String.concat " " words in
  ignore (log state ~id:"wrapped" ~at:1.
    [Live.Run_started; Live.Text text; reply text; Live.Run_finished]);
  List.iter (fun index ->
    let needle = Printf.sprintf "token%03d" index in
    ignore (find state needle);
    assert_still_reading state needle) [0; 149; 299];
  (* Longer than either body's width: the end of a matched phrase must also
     be on screen, not below the viewport's bottom row. *)
  let phrase = String.concat " " (words |> List.drop 140 |> List.take 18) in
  ignore (find state phrase);
  let lines = frame_lines state in
  let first = visible_line lines "token140" and last = visible_line lines "token157" in
  check bool "the matched phrase crosses actual wrapped rows" true (last > first);
  assert_still_reading state "token157";
  let unbroken = "HARDSTART" ^ String.make 180 'x' ^ "HARDEND" in
  let wrapped_word = text ^ "\n" ^ unbroken ^ "\n" ^ text in
  ignore (log state ~id:"hard-wrap" ~at:200.
    [Live.Run_started; Live.Text wrapped_word; reply wrapped_word; Live.Run_finished]);
  ignore (find state unbroken);
  let lines = frame_lines state in
  check bool "a hard-wrapped token retains both ends of its match" true
    (visible_line lines "HARDEND" > visible_line lines "HARDSTART"))

let test_search_matches_rendered_words () = at_sizes (fun origin ->
  let state = state origin in
  let text = "Visible **styled** text\nVISIBLE\nBOUNDARY\n" ^ long_answer "TAIL_" in
  ignore (log state ~id:"markdown" ~at:1.
    [Live.Run_started; Live.Text text; reply text; Live.Run_finished]);
  ignore (find state "Visible styled text");
  assert_still_reading state "Visible styled text";
  (* Search treats physical breaks as presentation boundaries, including an
     explicit source newline: their hard/soft provenance is not in row.text. *)
  List.iter (fun needle ->
    ignore (find state needle);
    let lines = frame_lines state in
    check bool "a rendered line boundary may separate a visible phrase" true
      (visible_line lines "BOUNDARY" > visible_line lines "VISIBLE"))
    ["VISIBLE BOUNDARY"; "VISIBLEBOUNDARY"])

let test_journal_only_pin_survives_all_arrivals () = at_sizes (fun origin ->
  let state = state origin in
  let text = long_answer "READ_A_" in
  ignore (log state ~id:"a" ~at:1.
    [Live.Run_started; Live.Text text; reply text; Live.Run_finished]);
  ignore (find state "READ_A_035");
  check bool "search pins the journal before a frame can arrive" true
    (Option.is_some state.msg_scroll_pin);
  let before = visible_line (frame_lines state) "READ_A_035" in
  let later = long_answer "NEW_C_" in
  ignore (log state ~id:"c" ~at:100.
    [Live.Run_started; Live.Text later; reply later; Live.Run_finished]);
  check int "a large journal arrival cannot move the reading row" before
    (visible_line (frame_lines state) "READ_A_035");
  assert_still_reading state "READ_A_035";
  state.msg_loaded <- [row ~id:"outside" ~request_id:"outside"
    ~role:(T.Message_user (T.Sent_by_other {speaker="beta"; surface=Some "broadcast"}))
    ~text:(long_answer "BROADCAST_") 200.];
  assert_still_reading state "READ_A_035";
  let pending = Chat.create_request ~keeper_name:"alpha"
    ~message:(long_answer "PENDING_") () in
  (match Masc_tui_keeper_chat_queue.push state.msg_queued ~submitted_at:250. pending with
   | Error detail -> fail detail
   | Ok (queue, _) -> state.msg_queued <- queue);
  assert_still_reading state "READ_A_035";
  let live = T.turn_log_create ~keeper_name:"alpha" ~request_id:"live" ~started_at:300. in
  T.turn_log_add ~now:300. live ~seq:(Some 0) Live.Run_started;
  T.turn_log_add ~now:301. live ~seq:(Some 1) (Live.Text (long_answer "LIVE_"));
  state.msg_live <- Some live;
  assert_still_reading state "READ_A_035";
  T.turn_log_add ~now:302. live ~seq:(Some 2) (Live.Text ("\n" ^ long_answer "GROWTH_"));
  assert_still_reading state "READ_A_035";
  T.turn_log_add ~now:303. live ~seq:(Some 3)
    (reply (long_answer "LIVE_" ^ "\n" ^ long_answer "GROWTH_"));
  T.turn_log_add ~now:304. live ~seq:(Some 4) Live.Run_finished;
  Log.commit live.tl_log;
  T.hold_settled_log state live;
  state.msg_live <- None;
  assert_still_reading state "READ_A_035")

let test_pin_aliases_history_and_canonical_reply () = at_sizes (fun origin ->
  let state = state origin in
  let text = long_answer "ALIASED_" in
  state.msg_loaded <- [row ~id:"answer" ~request_id:"alias" ~role:T.Message_keeper
    ~text 1.];
  ignore (find state "ALIASED_040");
  ignore (frame_lines state);
  ignore (log state ~id:"alias" ~at:1.
    [Live.Run_started; Live.Text text; reply text; Live.Run_finished]);
  let later = long_answer "LATER_" in
  let tail = log state ~id:"tail" ~at:100.
    [Live.Run_started; Live.Text later; reply later; Live.Run_finished] in
  assert_still_reading state "ALIASED_040";
  state.msg_settled_logs <- [tail];
  assert_still_reading state "ALIASED_040";
  (* Removing all tail content clamps this long history entry without losing
     its physical row. The next paint consumes the clamp exactly once. *)
  state.msg_settled_logs <- [];
  assert_still_reading state "ALIASED_040")

let test_search_pin_before_first_frame_and_at_tail () = at_sizes (fun origin ->
  List.iter (fun paint_before_arrival ->
    List.iter (fun draft ->
      let state = state origin in
      state.keeper_message_focus <- T.Right_pane;
      Masc_tui_message_input.insert state.msg_input draft;
      ignore (log state ~id:"short" ~at:1.
        [Live.Run_started; Live.Text "SHORT_MATCH"; reply "SHORT_MATCH"; Live.Run_finished]);
      ignore (find state "SHORT_MATCH");
      if paint_before_arrival then ignore (frame_lines state);
      check int "short-answer search starts at the live edge" 0 state.msg_scroll;
      let tail = long_answer "ARRIVED_BEFORE_PAINT_" in
      ignore (log state ~id:"tail" ~at:50.
        [Live.Run_started; Live.Text tail; reply tail; Live.Run_finished]);
      let first_frame, feedback = Render.render_keeper_message state in
      check int "render returns scroll feedback without changing the stored position" 0
        state.msg_scroll;
      Option.iter (T.apply_clamped_scroll state) feedback;
      check bool "the first frame restores the pin away from the live edge" true
        (state.msg_scroll > 0);
      let first_row = visible_line
          (List.map Masc_tui_theme.strip_sgr first_frame.Masc_tui_frame_presenter.lines)
          "SHORT_MATCH" in
      check int "the restored pin budgets chrome on its first frame" first_row
        (visible_line (frame_lines state) "SHORT_MATCH");
      assert_still_reading state "SHORT_MATCH";
      T.set_msg_scroll state 0;
      check bool "explicitly returning to the bottom releases the search pin" true
        (Option.is_none state.msg_scroll_pin);
      ignore (frame_lines state);
      check bool "live-edge frame feedback does not recreate a pin" true
        (Option.is_none state.msg_scroll_pin)) [""; "/"])
    [false; true])

let admission_log state ~id ~at =
  log state ~id ~at [Live.Accepted {
    admission=Live.Queued; queue_length=3;
    interactive=Some {Chat.outcome=Chat.Paused; chat_control_token="paused-control";
      signalled=false; resumed=false; interrupt_error=None} }]

let bind_admission_batch logs =
  List.iter (fun (log : T.turn_log) ->
    T.turn_log_add ~now:30. log ~seq:(Some 0) Live.Run_started;
    T.turn_log_add ~now:31. log ~seq:(Some 1)
      (Live.Batch_bound {operation_id=Log.request_id log.tl_log; execution_id="canonical"})) logs

let test_admission_repeat_survives_batch_binding () = at_sizes (fun origin ->
  let state = state origin in
  (* Identical display prefixes must not alias the full request identities. *)
  let older_id="tui-request-identical-prefix-A" and newer_id="tui-request-identical-prefix-B" in
  let older_log = admission_log state ~id:older_id ~at:10. in
  let newer_log = admission_log state ~id:newer_id ~at:20. in
  let query="Message queued:" in
  let newer = find state query in
  check bool "newest receipt has the full request anchor" true
    (newer.matched_anchor = T.Search_admission newer_id);
  bind_admission_batch [older_log; newer_log];
  check bool "follower changed its execution source" true
    (T.turn_log_execution_source newer_log = Log.Operation "canonical");
  let older = find ~older:newer state query in
  check bool "repeat finds the older receipt after both sources change" true
    (older.matched_anchor = T.Search_admission older_id);
  check bool "older receipt is present in the actual frame" true
    (Astring.String.is_infix ~affix:query (screen state));
  check bool "repeat stops after each receipt has been visited" true
    (Option.is_none (Render.keeper_message_find_scroll state ~keeper_name:"alpha"
       ~needle:query ~older_than:(Some older))))

let test_admission_pin_survives_batch_reply_arrival () = at_sizes (fun origin ->
  List.iter (fun paint_before_arrival ->
    let state = state origin in
    let held = admission_log state ~id:"follower" ~at:10. in
    ignore (find state "Message queued:");
    if paint_before_arrival then ignore (frame_lines state);
    (* Run_started precedes binding on the actual wire. A long canonical
       answer can arrive before the searched receipt's first paint. *)
    bind_admission_batch [held];
    let text = long_answer "BATCH_REPLY_" in
    T.turn_log_add ~now:32. held ~seq:(Some 2) (Live.Text text);
    T.turn_log_add ~now:33. held ~seq:(Some 3) (reply text);
    T.turn_log_add ~now:34. held ~seq:(Some 4) Live.Run_finished;
    Log.commit held.tl_log;
    check bool "request-owned receipt stays visible through binding and answer growth" true
      (Astring.String.is_infix ~affix:"Message queued:" (screen state));
    assert_still_reading state "Message queued:";
    T.set_msg_scroll state 0;
    check bool "explicit live-edge navigation releases the receipt pin" true
      (Option.is_none state.msg_scroll_pin)) [false; true])

let () = run "chat search projection" [
  "rendered conversation", [
    test_case "held replies and full suffix geometry" `Quick test_settled_reply_and_complete_suffix;
    test_case "repeat across visibility, backfill and finalization" `Quick
      test_repeat_survives_reasoning_visibility_and_backfill;
    test_case "repeat across source and workspace replacement" `Quick
      test_repeat_across_history_journal_replacement;
    test_case "frame feedback consumes arrival compensation" `Quick
      test_frame_feedback_consumes_arrival_compensation;
    test_case "long history and journal matches land on their physical row" `Quick
      test_long_answer_match_location;
    test_case "word wrapped matches include the whole phrase" `Quick
      test_word_wrapped_match_location;
    test_case "search matches rendered markup and presentation line boundaries" `Quick
      test_search_matches_rendered_words;
    test_case "journal-only pin survives settled, broadcast, input and live arrivals" `Quick
      test_journal_only_pin_survives_all_arrivals;
    test_case "scroll pin follows history and canonical reply aliases" `Quick
      test_pin_aliases_history_and_canonical_reply;
    test_case "search pins before the first frame and releases at the live edge" `Quick
      test_search_pin_before_first_frame_and_at_tail;
    test_case "receipt repeat preserves request identity through batch binding" `Quick
      test_admission_repeat_survives_batch_binding;
    test_case "receipt pin survives binding before paint and long reply arrival" `Quick
      test_admission_pin_survives_batch_reply_arrival ] ]
