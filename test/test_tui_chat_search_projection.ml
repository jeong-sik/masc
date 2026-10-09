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
    me_execution_source = Some (Log.Operation request_id); me_at = at }

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
      ~needle ~older_than:older |> fun result -> result.match_result with
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
    [Live.Run_started; Live.Text {text="HELD_REPLY_NEEDLE"; stream_scope=None}; reply "HELD_REPLY_NEEDLE"; Live.Run_finished]);
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
      [Live.Run_started; Live.Text {text=text; stream_scope=None}; reply text; Live.Run_finished])
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

let test_repeated_matches_within_entry () = at_sizes (fun origin ->
  let state = state origin in
  let body = List.init 100 (fun line ->
    match line with
    | 0 -> "MATCH_OLDER"
    | 45 -> "MATCH_MIDDLE"
    | 90 -> "MATCH_NEWEST"
    | _ -> Printf.sprintf "plain line %d" line) |> String.concat "\n" in
  state.msg_loaded <- [row ~id:"repeated" ~request_id:"repeated" ~role:user ~text:body 1.];
  let newest = find state "MATCH_" in
  check bool "newest occurrence has an original source position" true
    (match newest.matched_position with Masc_tui_chat_search.Body_byte _ -> true | _ -> false);
  check int "newest physical match is visible" 1 (count (screen state) "MATCH_NEWEST");
  let middle = find ~older:newest state "MATCH_" in
  check bool "repeat remains within the same durable entry" true
    (newest.matched_anchor = middle.matched_anchor);
  check bool "middle occurrence precedes newest source" true
    (Masc_tui_chat_search.compare_position middle.matched_position newest.matched_position<0);
  check int "middle physical match is visible" 1 (count (screen state) "MATCH_MIDDLE");
  let oldest = find ~older:middle state "MATCH_" in
  check bool "oldest occurrence precedes middle source" true
    (Masc_tui_chat_search.compare_position oldest.matched_position middle.matched_position<0);
  check int "oldest physical match is visible" 1 (count (screen state) "MATCH_OLDER");
  check bool "all occurrences exhausted" true
    (Option.is_none ((Render.keeper_message_find_scroll state ~keeper_name:"alpha"
      ~needle:"MATCH_" ~older_than:(Some oldest)).match_result));
  state.msg_loaded <- [row ~id:"same-row" ~request_id:"same-row" ~role:user
    ~text:"SAME SAME" 2.];
  let newest = find state "SAME" in
  let older = find ~older:newest state "SAME" in
  check bool "two occurrences on one physical row remain separate" true
    (Masc_tui_chat_search.compare_position older.matched_position newest.matched_position<0))

let test_repeat_cursor_across_reflow () = at_sizes (fun origin ->
  let set_cols columns=ignore(Masc_tui_render_schedule.Terminal_size_cache.refresh
    Masc_tui_ansi.terminal_size_cache ~probe:(fun () -> Some(26,columns))) in
  let state=state origin in
  state.msg_loaded <- [row ~id:"reflow" ~request_id:"reflow" ~role:user
    ~text:"foobar\nfoo bar foobar" 1.];
  set_cols 42;
  let newest=find state "FOOBAR" in
  set_cols 160;
  let older=find ~older:newest state "FOOBAR" in
  check bool "reflow advances to distinct older original literal" true
    (Masc_tui_chat_search.compare_position older.matched_position newest.matched_position<0);
  check bool "two original literals exhaust after resize" true
    ((Render.keeper_message_find_scroll state ~keeper_name:"alpha" ~needle:"foobar" ~older_than:(Some older)).match_result=None);
  state.msg_loaded <- [row ~id:"table" ~request_id:"table" ~role:user
    ~text:"OLDER_TARGET\n| Header |\n| --- |\n| long padding before TARGET |" 2.];
  set_cols 160;
  let cell=find state "TARGET" in
  set_cols 42;
  let earlier=find ~older:cell state "TARGET" in
  check bool "clipped current table match still advances" true
    (Masc_tui_chat_search.compare_position earlier.matched_position cell.matched_position<0);
  set_cols 160;
  check bool "widening cannot restart after older original match" true
    ((Render.keeper_message_find_scroll state ~keeper_name:"alpha" ~needle:"TARGET" ~older_than:(Some earlier)).match_result=None);
  state.msg_loaded <- [row ~id:"diagram" ~request_id:"diagram" ~role:user
    ~text:"repeat\n```mermaid\nflowchart LR\nA[repeat] --> B[repeat]\n```" 3.];
  let diagram=find state "repeat" in
  set_cols 42;
  let fallback=find ~older:diagram state "repeat" in
  check bool "diagram to source fallback keeps original occurrence order" true
    (Masc_tui_chat_search.compare_position fallback.matched_position diagram.matched_position<0);
  set_cols 160;
  let oldest=find ~older:fallback state "repeat" in
  check bool "source fallback to diagram advances to older prose" true
    (Masc_tui_chat_search.compare_position oldest.matched_position fallback.matched_position<0);
  check bool "diagram/source switching does not repeat any literal" true
    ((Render.keeper_message_find_scroll state ~keeper_name:"alpha" ~needle:"repeat" ~older_than:(Some oldest)).match_result=None))

let test_preview_and_journal_search_reflow () = at_sizes (fun origin ->
  let set_cols columns=ignore(Masc_tui_render_schedule.Terminal_size_cache.refresh
    Masc_tui_ansi.terminal_size_cache ~probe:(fun () -> Some(26,columns))) in
  let state=state origin in
  let url="https://example.test/reflow-search" in
  let preview=Masc_tui_link_preview.synthesize_preview url in
  Masc_tui_link_preview.cache_store {preview with has_metadata=true;site_name=Some "Fixture";
    title=Some "**titlehit** titlehit";description=Some "plain description"};
  List.iter (fun mode ->
    state.link_previews_mode <- mode;
    state.msg_loaded <- [row ~id:"preview" ~request_id:"preview" ~role:user
      ~text:("titlehit\n" ^ url) 1.];
    set_cols 180;
    let newest=find state "titlehit" in
    check bool "preview title has formatter-owned source identity" true
      (match newest.matched_position with Masc_tui_chat_search.Preview_byte _ -> true | _ -> false);
    set_cols 60;
    let older=find ~older:newest state "titlehit" in
    check bool "second Markdown pass retains earlier field identity after reflow" true
      (Masc_tui_chat_search.compare_position older.matched_position newest.matched_position<0);
    set_cols 180;
    let remaining=Render.keeper_message_find_scroll state ~keeper_name:"alpha"
      ~needle:"titlehit" ~older_than:(Some older) in
    check int "complete preview provenance is available" 0 remaining.unavailable_entries;
    Option.iter (fun (_,cursor) -> check bool "further search never repeats the widened later title" true
      (Masc_tui_chat_search.compare_position cursor.T.matched_position older.matched_position<0)) remaining.match_result)
    [`Compact;`Rich];
  state.link_previews_mode <- `Off;
  state.msg_memory_visibility <- T.Memory_full;
  let memory=row ~id:"memory" ~request_id:"memory" ~role:T.Message_memory ~text:"memory revision" 2. in
  state.msg_loaded <- [{memory with me_journal=[Layout.Journal_fact {
    sign=Journal_added;category="fact";tone=Tone_fact;claim="journalhit middle journalhit"}]}];
  set_cols 180;
  let newest=find state "journalhit" in
  set_cols 45;
  let older=find ~older:newest state "journalhit" in
  check bool "journal hanging columns preserve source occurrence order" true
    (Masc_tui_chat_search.compare_position older.matched_position newest.matched_position<0);
  check bool "journal search exhausts without repeating a field" true
    ((Render.keeper_message_find_scroll state ~keeper_name:"alpha" ~needle:"journalhit" ~older_than:(Some older)).match_result=None))

let test_search_freezes_preview_lookup () = at_sizes (fun origin ->
  let state=state origin in
  state.link_previews_mode <- `Rich;
  let url="https://example.test/frozen-search" in
  let base=Masc_tui_link_preview.synthesize_preview url in
  let calls=ref 0 in
  let preview_lookup requested =
    check string "lookup receives the visible URL" url requested;
    incr calls;
    {base with has_metadata=true;site_name=Some "Fixture";
      title=Some (if !calls=1 then "FROZEN_NEEDLE" else "changed metadata");
      description=(if !calls=1 then None else Some "extra metadata changes card height")} in
  state.msg_loaded <- [row ~id:"frozen" ~request_id:"frozen" ~role:user ~text:url 1.];
  let found=Render.keeper_message_find_scroll ~preview_lookup state ~keeper_name:"alpha"
    ~needle:"FROZEN_NEEDLE" ~older_than:None in
  check bool "first metadata snapshot supplies a search result" true (Option.is_some found.match_result);
  check int "mapping and suffix measurement share one preview read" 1 !calls)

let test_folded_thinking_search_identity () = at_sizes (fun origin ->
  let state=state origin in
  state.msg_reasoning_visibility <- T.Reasoning_folded;
  state.msg_loaded <- [row ~id:"thinking-identity" ~request_id:"thinking-identity"
    ~role:T.Message_thinking ~text:("Reasoning " ^ String.make 100 'x' ^ "\nsecond reasoning line") 1.];
  state.msg_reasoning_visibility <- T.Reasoning_folded;
  let summary=find state "Reasoning" in
  check bool "fold producer marks generated summary identity" true
    (match summary.matched_position with Masc_tui_chat_search.Thinking_summary_byte _ -> true | _ -> false);
  state.msg_reasoning_visibility <- T.Reasoning_full;
  let source=find ~older:summary state "Reasoning" in
  check bool "unfolded original is a distinct source occurrence" true
    (match source.matched_position with Masc_tui_chat_search.Body_byte _ -> true | _ -> false);
  state.msg_reasoning_visibility <- T.Reasoning_folded;
  check bool "returning to summary cannot cycle to its prior match" true
    ((Render.keeper_message_find_scroll state ~keeper_name:"alpha" ~needle:"Reasoning" ~older_than:(Some source)).match_result=None);
  state.msg_reasoning_visibility <- T.Reasoning_full;
  let source=find state "Reasoning" in
  state.msg_reasoning_visibility <- T.Reasoning_folded;
  check bool "source-to-summary transition respects the same fixed order" true
    ((Render.keeper_message_find_scroll state ~keeper_name:"alpha" ~needle:"Reasoning" ~older_than:(Some source)).match_result=None))

let test_indexed_scroll_anchors () = at_sizes (fun origin ->
  let state = state origin in
  state.msg_loaded <- List.init 500 (fun i -> row ~id:(string_of_int i)
    ~request_id:(string_of_int i) ~role:user ~text:"anchor text" (float_of_int i));
  let projection = Render.keeper_message_projection state ~keeper_name:"alpha" ~chat_cols:80 in
  let index = Render.scroll_anchor_index projection in
  check bool "unchanged projection reuses indexed anchors" true
    (index == Render.scroll_anchor_index projection);
  List.iteri (fun i (tag, _) ->
    check bool "indexed anchor equals typed source" true
      (Render.scroll_anchor_at projection i =
       Option.map (fun anchor -> T.Scroll_durable anchor) (Render.search_anchor_of_tag tag));
    Option.iter (fun anchor ->
      check (option int) "reverse lookup agrees with typed matching" (Some i)
        (Render.projection_index_of_anchor projection anchor)) (Render.search_anchor_of_tag tag))
    projection.tagged_entries;
  check bool "out of range has no anchor" true
    (Option.is_none (Render.scroll_anchor_at projection 500));
  check bool "negative index has no anchor" true
    (Option.is_none (Render.scroll_anchor_at projection (-1))))

let test_repeat_survives_reasoning_visibility_and_backfill () = at_sizes (fun origin ->
  let state = state origin in
  state.msg_reasoning_visibility <- T.Reasoning_full;
  state.msg_loaded <- [row ~id:"old" ~request_id:"old" ~role:user
    ~text:"MATCH_HISTORY" 1.];
  let held = log state ~id:"running" ~at:10.
    [Live.Run_started; Live.Text {text="MATCH_PROGRESS"; stream_scope=None};
     Live.Thinking "MATCH_REASONING"; Live.Text {text="MATCH_REPLY"; stream_scope=None}] in
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
   | T.Search_journal _ -> fail "search repeated a newer journal item");
  check bool "no older match ends the walk" true
    (Option.is_none ((Render.keeper_message_find_scroll state ~keeper_name:"alpha"
       ~needle:"MATCH_" ~older_than:(Some history)).match_result));
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
    (Option.is_none ((Render.keeper_message_find_scroll state ~keeper_name:"alpha"
       ~needle:"MATCH_REASONING" ~older_than:None).match_result)))

let test_repeat_across_history_journal_replacement () = at_sizes (fun origin ->
  let state = state origin in
  state.msg_loaded <- [
    row ~id:"a" ~request_id:"a" ~role:T.Message_keeper ~text:"MATCH_A" 1.;
    row ~id:"b" ~request_id:"b" ~role:T.Message_keeper ~text:"MATCH_B" 10. ];
  let latest = find state "MATCH_" in
  List.iter (fun (id, at, text) -> ignore (log state ~id ~at
    [Live.Run_started; Live.Text {text=text; stream_scope=None}; reply text; Live.Run_finished]))
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
      [Live.Run_started; Live.Text {text=text; stream_scope=None}; reply text; Live.Run_finished])
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
    [Live.Run_started; Live.Text {text=text; stream_scope=None}; reply text; Live.Run_finished]);
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
    [Live.Run_started; Live.Text {text=wrapped_word; stream_scope=None}; reply wrapped_word; Live.Run_finished]);
  ignore (find state unbroken);
  let lines = frame_lines state in
  check bool "a hard-wrapped token retains both ends of its match" true
    (visible_line lines "HARDEND" > visible_line lines "HARDSTART"))

let test_search_matches_rendered_words () = at_sizes (fun origin ->
  let state = state origin in
  let text = "Visible **styled** text\nVISIBLE\nBOUNDARY\n" ^ long_answer "TAIL_" in
  ignore (log state ~id:"markdown" ~at:1.
    [Live.Run_started; Live.Text {text=text; stream_scope=None}; reply text; Live.Run_finished]);
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
    [Live.Run_started; Live.Text {text=text; stream_scope=None}; reply text; Live.Run_finished]);
  ignore (find state "READ_A_035");
  check bool "search pins the journal before a frame can arrive" true
    (Option.is_some state.msg_scroll_pin);
  let before = visible_line (frame_lines state) "READ_A_035" in
  let later = long_answer "NEW_C_" in
  ignore (log state ~id:"c" ~at:100.
    [Live.Run_started; Live.Text {text=later; stream_scope=None}; reply later; Live.Run_finished]);
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
  T.turn_log_add ~now:301. live ~seq:(Some 1) (Live.Text {text=long_answer "LIVE_"; stream_scope=None});
  state.msg_live <- Some live;
  assert_still_reading state "READ_A_035";
  T.turn_log_add ~now:302. live ~seq:(Some 2) (Live.Text {text=("\n" ^ long_answer "GROWTH_"); stream_scope=None});
  assert_still_reading state "READ_A_035";
  T.turn_log_add ~now:303. live ~seq:(Some 3)
    (reply (long_answer "LIVE_" ^ "\n" ^ long_answer "GROWTH_"));
  T.turn_log_add ~now:304. live ~seq:(Some 4) Live.Run_finished;
  Log.commit live.tl_log;
  T.hold_settled_log state live;
  state.msg_live <- None;
  assert_still_reading state "READ_A_035")

let test_pending_pin_survives_run_start () = at_sizes (fun origin ->
  let state = state origin in
  let text = long_answer "PROMOTED_INPUT_" in
  let request = Chat.create_request ~keeper_name:"alpha" ~message:text () in
  let live = T.turn_log_create ~keeper_name:"alpha" ~request_id:request.request_id ~started_at:1. in
  let inflight : T.inflight = {sent_request=request;submitted_at=1.;sent_at=1.;
    control_generation=0;phase=T.Turn_streaming;log=live} in
  state.msg_inflight <- [inflight];
  let input = row ~id:"session-input" ~request_id:request.request_id ~role:user ~text 1. in
  state.msg_history <- [{input with me_identity=T.Session_row {request_id=request.request_id;
    turn_phase=T.Turn_input;operation_seq=0}}];
  T.set_msg_scroll state 40;
  let before = frame_lines state in
  let needle = List.init 100 (Printf.sprintf "PROMOTED_INPUT_%03d")
    |> List.find (fun needle -> List.exists (Astring.String.is_infix ~affix:needle) before) in
  let position = visible_line before needle in
  check bool "the waiting input owns the physical reading pin" true
    (Option.exists (fun pin -> List.exists (fun point ->
       point.T.scroll_anchor = T.Scroll_pending request.request_id) pin.T.pin_points)
       state.msg_scroll_pin);
  T.turn_log_add ~now:2. live ~seq:(Some 0) Live.Run_started;
  T.turn_log_add ~now:3. live ~seq:(Some 1)
    (Live.Text {text=long_answer "NEW_EXECUTION_";stream_scope=None});
  check int "promotion and new output keep the pending input row in place" position
    (visible_line (frame_lines state) needle);
  assert_still_reading state needle)

let test_reply_alias_uses_recorded_execution_source () = at_sizes (fun origin ->
  let state = state origin in
  let text = long_answer "BATCH_REPLY_" in
  let history = row ~id:"batch-reply" ~request_id:"delivery-request"
      ~role:T.Message_keeper ~text 1. in
  state.msg_loaded <- [{history with me_execution_source=Some (Log.Operation "execution-owner")}];
  let cursor = find state "BATCH_REPLY_040" in
  (match cursor.T.matched_anchor with
   | T.Search_history {reply_source=Some (Log.Operation "execution-owner");_} -> ()
   | _ -> fail "history reply inferred the delivery request instead of recorded execution");
  ignore (frame_lines state);
  ignore (log state ~id:"execution-owner" ~at:1.
    [Live.Run_started;Live.Text {text;stream_scope=None};reply text;Live.Run_finished]);
  ignore (log state ~id:"later" ~at:200.
    [Live.Run_started;Live.Text {text=long_answer "NEW_AFTER_ALIAS_";stream_scope=None};
     reply (long_answer "NEW_AFTER_ALIAS_");Live.Run_finished]);
  assert_still_reading state "BATCH_REPLY_040")

let test_pin_aliases_history_and_canonical_reply () = at_sizes (fun origin ->
  let state = state origin in
  let text = long_answer "ALIASED_" in
  state.msg_loaded <- [row ~id:"answer" ~request_id:"alias" ~role:T.Message_keeper
    ~text 1.];
  ignore (find state "ALIASED_040");
  ignore (frame_lines state);
  ignore (log state ~id:"alias" ~at:1.
    [Live.Run_started; Live.Text {text=text; stream_scope=None}; reply text; Live.Run_finished]);
  let later = long_answer "LATER_" in
  let tail = log state ~id:"tail" ~at:100.
    [Live.Run_started; Live.Text {text=later; stream_scope=None}; reply later; Live.Run_finished] in
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
        [Live.Run_started; Live.Text {text="SHORT_MATCH"; stream_scope=None}; reply "SHORT_MATCH"; Live.Run_finished]);
      ignore (find state "SHORT_MATCH");
      if paint_before_arrival then ignore (frame_lines state);
      check int "short-answer search starts at the live edge" 0 state.msg_scroll;
      let tail = long_answer "ARRIVED_BEFORE_PAINT_" in
      ignore (log state ~id:"tail" ~at:50.
        [Live.Run_started; Live.Text {text=tail; stream_scope=None}; reply tail; Live.Run_finished]);
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
      let follows_live () = match state.msg_scroll_pin with
        | None | Some { T.pin_mode = T.Follow_live; _ } -> true
        | Some { T.pin_mode = (T.Hold_scroll | T.Hold_search); _ } -> false in
      check bool "explicitly returning to the bottom releases active search holding" true
        (follows_live ());
      let newest = long_answer "AFTER_RELEASE_" in
      ignore (log state ~id:"after-release" ~at:300.
        [Live.Run_started; Live.Text {text=newest; stream_scope=None}; reply newest; Live.Run_finished]);
      let lines = frame_lines state in
      check int "new arrivals after End keep the live edge" 0 state.msg_scroll;
      ignore (visible_line lines "AFTER_RELEASE_099");
      check bool "frame feedback retains only a passive live-edge snapshot" true
        (follows_live ())) [""; "/"])
    [false; true])

(* The layout keeps its row counts for the list it measured. A settled
   conversation hands it that same list on the next frame; only pending or
   polled entries make a new one. *)
let test_a_settled_conversation_keeps_its_measured_list () =
  let state = state Layout.Origin_inline in
  state.msg_loaded <- [
    row ~id:"question" ~request_id:"first" ~role:user ~text:"SETTLED_QUESTION" 1.;
    row ~id:"reply" ~request_id:"first" ~role:T.Message_keeper ~text:"SETTLED_REPLY" 3. ];
  let settled = Render.keeper_message_layout_entries state ~keeper_name:"alpha" ~chat_cols:80 in
  check bool "the fixture has settled entries" true (List.length settled > 0);
  check bool "nothing transient: the measured list itself, not a copy" true
    (Render.with_transient_tail settled ~transient:[] == settled);
  let pending = Chat.create_request ~keeper_name:"alpha" ~message:"PENDING_INPUT" () in
  (match Masc_tui_keeper_chat_queue.push state.msg_queued ~submitted_at:80. pending with
   | Error detail -> fail detail
   | Ok (queue, _) -> state.msg_queued <- queue);
  let tail = Render.chat_tail_entries state ~keeper_name:"alpha"
      ~role_label_column:(Layout.chat_role_label_width ~pane_cells:80) in
  check bool "the fixture has a pending input" true (List.length tail > 0);
  let joined = Render.with_transient_tail settled ~transient:tail in
  check int "a transient tail follows every settled entry"
    (List.length settled + List.length tail) (List.length joined);
  check bool "and keeps their order" true (List.for_all2 ( == ) (settled @ tail) joined)

let test_empty_projection_does_not_hold_future_arrivals () = at_sizes (fun origin ->
  List.iter (fun requested ->
    let state = state origin in
    ignore (frame_lines state);
    check bool "empty frame records an explicit live-follow snapshot" true
      (match state.msg_scroll_pin with
       | Some {T.pin_mode=Follow_live;pin_points=[];_} -> true
       | Some _ | None -> false);
    T.set_msg_scroll state requested;
    check int "empty scroll request cannot defer onto future speech" 0 state.msg_scroll;
    state.msg_loaded <- [row ~id:"first-arrival" ~request_id:"first-arrival" ~role:user
      ~text:(long_answer "FIRST_ARRIVAL_") 1.];
    let lines = frame_lines state in
    check bool "first arrival remains at the live tail" true
      (List.exists (Astring.String.is_infix ~affix:"FIRST_ARRIVAL_099") lines);
    check int "future arrival did not inherit a stale scroll count" 0 state.msg_scroll)
    [1; 40; max_int])

let test_semantic_search_repetitive_prefix_and_boundaries () =
  let module Search = Masc_tui_chat_search in
  let run ?(joins_previous=false) ~offset text : Search.run =
    {text;joins_previous;
     positions=Array.init (String.length text) (fun byte ->
       Some (Search.Body_byte {offset=offset+byte;expansion=0}));
     visible_rows=[0,[{Masc_tui_markdown.start_byte=0;end_byte=String.length text}]]} in
  let search ?before needle runs = Search.find ~needle ~before ~body_rows:1 runs in
  let position = function
    | Some {Search.position=Body_byte {offset;_};_} -> offset
    | Some _ | None -> fail "expected an original source-byte match" in
  let overlapping=[run ~offset:0 "aaaaa"] in
  let newest=search "aaa" overlapping in
  check int "newest overlapping prefix" 2 (position newest);
  let middle=search ~before:(Search.Body_byte {offset=2;expansion=0}) "aaa" overlapping in
  check int "repeat retains middle overlapping prefix" 1 (position middle);
  check int "repeat retains oldest overlapping prefix" 0
    (position (search ~before:(Search.Body_byte {offset=1;expansion=0}) "aaa" overlapping));
  let lines=[run ~offset:0 "VISIBLE";run ~joins_previous:true ~offset:8 "BOUNDARY"] in
  List.iter (fun needle -> check int "optional logical boundary preserves source occurrence" 0
    (position (search needle lines))) ["VISIBLEBOUNDARY";"VISIBLE BOUNDARY";"VISIBLE\nBOUNDARY"];
  check bool "ordinary authored spaces cannot disappear" true
    (search "foobar" [run ~offset:0 "foo bar"] = None);
  let text=String.make 50000 'a' and needle=String.make 5000 'a' ^ "b" in
  check bool "a long repetitive near-match terminates without candidate replay" true
    (search needle [run ~offset:0 text] = None);
  let lines = List.init 50 (fun line -> run ~joins_previous:(line > 0)
    ~offset:(line * 1001) (String.make 1000 'a')) in
  check bool "multiline repetitive near-match skips only marked boundaries" true
    (search needle lines = None);
  let complete = lines @ [run ~joins_previous:true ~offset:50050 "b"] in
  let found = search needle complete in
  check int "multiline KMP retains newest original source occurrence" 45045 (position found);
  check bool "multiline match owns its actual endpoint source" true
    (match found with
     | Some {Search.ending_position=Body_byte {offset=50050;_};_} -> true
     | Some _ | None -> false)

let test_search_pin_retains_query_endpoint_through_reflow () = at_sizes (fun origin ->
  let set_cols columns = ignore (Masc_tui_render_schedule.Terminal_size_cache.refresh
    Masc_tui_ansi.terminal_size_cache ~probe:(fun () -> Some (26, columns))) in
  let state = state origin in
  let words = List.init 300 (fun i -> Printf.sprintf "token%03d" i) in
  state.msg_loaded <- [row ~id:"endpoint-reflow" ~request_id:"endpoint-reflow"
    ~role:user ~text:(String.concat " " words) 1.];
  set_cols 160;
  ignore (find state "token148 token149 token150");
  let original = Option.bind state.msg_scroll_pin (fun pin ->
    List.find_map (fun point -> point.T.source_position) pin.pin_points) in
  check bool "search pin owns an exact semantic endpoint" true (Option.is_some original);
  ignore (frame_lines state);
  List.iter (fun columns ->
    set_cols columns;
    List.iter (fun display ->
      state.msg_origin_display <- display;
      (* No second /find: rendering and feedback must resolve the original byte. *)
      List.iter (fun _ ->
        ignore (visible_line (frame_lines state) "token150");
        let held = Option.bind state.msg_scroll_pin (fun pin ->
          List.find_map (fun point -> point.T.source_position) pin.pin_points) in
        check bool "frame feedback retains the actual searched endpoint" true (held = original))
        [(); (); ()]) [Layout.Origin_inline; Origin_bare; Origin_row]) [42; 160; 60])

let test_idle_search_pin_reuses_semantic_index () = at_sizes (fun origin ->
  let state = state origin in
  state.link_previews_mode <- `Rich;
  let url = "https://example.test/idle-source-index" in
  let preview = Masc_tui_link_preview.synthesize_preview url in
  Masc_tui_link_preview.cache_store {preview with has_metadata=true;title=Some "cached preview"};
  let body = long_answer "CACHE_LINE_" ^ "\n" ^ url in
  state.msg_loaded <- [row ~id:"idle-source-index" ~request_id:"idle-source-index"
    ~role:user ~text:body 1.];
  ignore (find state "CACHE_LINE_050");
  ignore (frame_lines state);
  let builds = Render.For_testing.source_index_build_count () in
  let discoveries = Render.For_testing.source_url_discovery_count () in
  List.iter (fun _ ->
    ignore (visible_line (frame_lines state) "CACHE_LINE_050");
    check int "idle paints reuse source visibility index" builds
      (Render.For_testing.source_index_build_count ());
    check int "idle paints poll known URLs without rediscovering source" discoveries
      (Render.For_testing.source_url_discovery_count ())) [(); (); ()];
  Masc_tui_link_preview.cache_store {preview with has_metadata=true;title=Some "changed preview"};
  ignore (frame_lines state);
  check bool "changed actual preview metadata rebuilds the source map" true
    (Render.For_testing.source_index_build_count () > builds))

let test_polled_source_survives_tail_and_journal_takeover () = at_sizes (fun origin ->
  let state = state origin in
  let text = String.concat "\n" (List.init 60 (fun index ->
    Printf.sprintf "OBSERVED_%03d 글\226\128\174\027" index)) in
  let preview generation start text : Masc.Tui_decode.keeper_turn_row =
    {ktr_keeper_name="alpha";ktr_chat_control_token=None;
     ktr_state=Keeper_turn_running {lane=Turn_lane_maintenance;
       started_at_unix=120.;interrupt_token="exact-polled";turn_ref=None;
       preview=Some {ktp_status_text="working";ktp_updated_at_unix=121.;
         ktp_text_position={kpp_generation=generation;kpp_start_byte=start};
         ktp_text_tail=text;ktp_last_tool=None}}} in
  state.keeper_turns <- [preview 3 120 text];
  ignore (frame_lines state);
  T.set_msg_scroll state 5;
  let before = frame_lines state in
  let observed = List.find_map (fun line ->
    if Astring.String.is_infix ~affix:"OBSERVED_" line then Some line else None) before
    |> Option.value ~default:"" in
  check bool "actual polled row is visible while reading" true (observed <> "");
  let pin = Option.get state.msg_scroll_pin in
  check bool "polled pin owns producer absolute bytes" true
    (List.exists (fun point -> match point.T.source_position with
      | Some (T.Polled_body_byte {offset;_}) -> offset >= 120 | _ -> false) pin.pin_points);
  check int "pin holds one immutable observed source" 1 (List.length pin.held_transients);
  state.keeper_turns <- [preview 3 400 "NEW_ROLLING_TAIL"];
  check bool "expired rolling bytes retain exact observed viewport" true
    (List.mem observed (frame_lines state));
  state.keeper_turns <- [];
  ignore (log state ~id:"journal-takeover" ~at:130.
    [Live.Run_started;Live.Text {text="ACTUAL_JOURNAL_TAKEOVER";stream_scope=None};
     reply "ACTUAL_JOURNAL_TAKEOVER";Live.Run_finished]);
  check bool "journal takeover preserves polled-only viewport" true
    (List.mem observed (frame_lines state));
  T.set_msg_scroll state 0;
  check bool "End releases held source immediately" true
    (Option.fold ~none:true ~some:(fun pin -> pin.T.held_transients=[]) state.msg_scroll_pin);
  let live = screen state in
  check bool "End shows actual journal" true
    (Astring.String.is_infix ~affix:"ACTUAL_JOURNAL_TAKEOVER" live);
  check bool "End removes frozen excerpt" true
    (not (Astring.String.is_infix ~affix:"OBSERVED_" live)))

let () = run "chat search projection" [
  "rendered conversation", [
    test_case "empty projection follows future arrivals" `Quick test_empty_projection_does_not_hold_future_arrivals;
    test_case "polled absolute source survives rolling and journal takeover" `Quick test_polled_source_survives_tail_and_journal_takeover;
    test_case "idle search pin reuses semantic and URL indexes" `Quick test_idle_search_pin_reuses_semantic_index;
    test_case "search pin preserves query endpoint through width and gutters" `Quick test_search_pin_retains_query_endpoint_through_reflow;
    test_case "semantic search repetitive prefixes and optional boundaries" `Quick test_semantic_search_repetitive_prefix_and_boundaries;
    test_case "scroll anchors reuse typed indexed lookup" `Quick test_indexed_scroll_anchors;
    test_case "a settled conversation keeps its measured list" `Quick
      test_a_settled_conversation_keeps_its_measured_list;
    test_case "held replies and full suffix geometry" `Quick test_settled_reply_and_complete_suffix;
    test_case "repeated matches within one entry are newest first" `Quick
      test_repeated_matches_within_entry;
    test_case "repeat across visibility, backfill and finalization" `Quick
      test_repeat_survives_reasoning_visibility_and_backfill;
    test_case "repeat across source and workspace replacement" `Quick
      test_repeat_across_history_journal_replacement;
    test_case "frame feedback consumes arrival compensation" `Quick
      test_frame_feedback_consumes_arrival_compensation;
    test_case "long history and journal matches land on their physical row" `Quick
      test_long_answer_match_location;
    test_case "folded thinking has a distinct search identity" `Quick test_folded_thinking_search_identity;
    test_case "search freezes preview lookup across measurement" `Quick test_search_freezes_preview_lookup;
    test_case "preview and journal search survive reflow" `Quick test_preview_and_journal_search_reflow;
    test_case "source cursor survives actual layout reflow" `Quick test_repeat_cursor_across_reflow;
    test_case "word wrapped matches include the whole phrase" `Quick
      test_word_wrapped_match_location;
    test_case "search matches rendered markup and presentation line boundaries" `Quick
      test_search_matches_rendered_words;
    test_case "journal-only pin survives settled, broadcast, input and live arrivals" `Quick
      test_journal_only_pin_survives_all_arrivals;
    test_case "pending pin survives run start" `Quick test_pending_pin_survives_run_start;
    test_case "reply alias uses recorded execution source" `Quick test_reply_alias_uses_recorded_execution_source;
    test_case "scroll pin follows history and canonical reply aliases" `Quick
      test_pin_aliases_history_and_canonical_reply;
    test_case "search pins before the first frame and releases at the live edge" `Quick
      test_search_pin_before_first_frame_and_at_tail ] ]
