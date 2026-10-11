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
    me_operation_seq = 0; me_text = text; me_image = Masc_tui_image_preview.No_image; me_media = [];
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
  reply=text; turn_outcome=Masc.Keeper_turn_outcome.Visible_reply; turn_ref="search#1";
  terminal_stream_scope=None }

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
  let set_cols columns=ignore(Masc_tui_render_schedule.Terminal_size_cache.refresh
    Masc_tui_ansi.terminal_size_cache ~probe:(fun () -> Some(26,columns))) in
  let state=state origin in
  state.msg_reasoning_visibility <- T.Reasoning_folded;
  state.msg_loaded <- [row ~id:"thinking-identity" ~request_id:"thinking-identity"
    ~role:T.Message_thinking ~text:("Reasoning " ^ String.make 100 'x') 1.];
  set_cols 45;
  let summary=find state "Reasoning" in
  check bool "fold producer marks generated summary identity" true
    (match summary.matched_position with Masc_tui_chat_search.Thinking_summary_byte _ -> true | _ -> false);
  set_cols 180;
  let source=find ~older:summary state "Reasoning" in
  check bool "unfolded original is a distinct source occurrence" true
    (match source.matched_position with Masc_tui_chat_search.Body_byte _ -> true | _ -> false);
  set_cols 45;
  check bool "returning to summary cannot cycle to its prior match" true
    ((Render.keeper_message_find_scroll state ~keeper_name:"alpha" ~needle:"Reasoning" ~older_than:(Some source)).match_result=None);
  set_cols 180;
  let source=find state "Reasoning" in
  set_cols 45;
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
   | T.Search_child _ | T.Search_journal _ | T.Search_admission _ -> fail "search repeated a newer journal item");
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

let test_bottom_up_diagram_repeat_follows_drawn_rows () = at_sizes (fun origin ->
  let state = state origin in
  let text = "MATCH_PROSE\n```mermaid\nflowchart BT\nA[MATCH_LOWER] --> B[MATCH_UPPER]\n```" in
  state.msg_loaded <- [row ~id:"bottom-up" ~request_id:"bottom-up" ~role:user ~text 1.];
  let lines = frame_lines state in
  check bool "the bottom-up drawing puts the later label above the earlier one" true
    (visible_line lines "MATCH_UPPER" < visible_line lines "MATCH_LOWER");
  let source label = match Astring.String.find_sub ~sub:label text with
    | Some offset -> offset
    | None -> fail ("label missing from source: " ^ label) in
  let offset (cursor : T.chat_search_cursor) = match cursor.matched_position with
    | Masc_tui_chat_search.Body_byte {offset;_} -> offset
    | Body_label _ | Thinking_summary_byte _ | Thinking_summary_label _ | Projected_byte _
    | Projected_label _ | Preview_byte _ | Journal_byte _ | Request_byte _ ->
        fail "expected an original source-byte match" in
  let lowest = find state "MATCH_" in
  check int "the first match is the label drawn lowest" (source "MATCH_LOWER") (offset lowest);
  let upper = find ~older:lowest state "MATCH_" in
  check int "the repeat moves up to the label drawn above it" (source "MATCH_UPPER") (offset upper);
  let prose = find ~older:upper state "MATCH_" in
  check int "the repeat then leaves the drawing for the prose above it" 0 (offset prose);
  check bool "each occurrence is visited once" true
    (Option.is_none ((Render.keeper_message_find_scroll state ~keeper_name:"alpha"
      ~needle:"MATCH_" ~older_than:(Some prose)).match_result)))

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

let admission_log (state : T.state) ~id ~at =
  let sent_request = { (Chat.create_request ~keeper_name:"alpha" ~message:"input" ()) with
      Chat.request_id=id } in
  let held = T.turn_log_create ~keeper_name:"alpha" ~request_id:id ~started_at:at in
  T.turn_log_add ~now:at held ~seq:None (Live.Accepted {
    admission=Live.Queued; queue_length=3;
    interactive=Some {Chat.outcome=Chat.Paused; chat_control_token="paused-control";
      signalled=false; resumed=false; interrupt_error=None} });
  let entry : T.inflight = {sent_request; submitted_at=at; sent_at=at;
    control_generation=0; phase=T.Turn_streaming; log=held} in
  state.msg_inflight <- state.msg_inflight @ [entry];
  held

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
    (Option.is_none ((Render.keeper_message_find_scroll state ~keeper_name:"alpha"
       ~needle:query ~older_than:(Some older)).match_result)))

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
    T.turn_log_add ~now:32. held ~seq:(Some 2) (Live.Text {text=text; stream_scope=None});
    T.turn_log_add ~now:33. held ~seq:(Some 3) (reply text);
    T.turn_log_add ~now:34. held ~seq:(Some 4) Live.Run_finished;
    (* The terminal callback retains the source before removing its watcher. *)
    let completed = List.find (fun (entry : T.inflight) -> entry.log == held)
        state.msg_inflight in
    T.settle_turn_log state completed;
    state.msg_inflight <- List.filter (fun (entry : T.inflight) ->
      not (Chat.same_request_identity entry.sent_request completed.sent_request))
      state.msg_inflight;
    check bool "request-owned receipt stays visible through binding and answer growth" true
      (Astring.String.is_infix ~affix:"Message queued:" (screen state));
    assert_still_reading state "Message queued:";
    T.set_msg_scroll state 0;
    (* Returning to the live edge stops holding. What may remain is the
       passive live-edge snapshot that seeds the next scroll key. *)
    check bool "explicit live-edge navigation releases the receipt pin" true
      (match state.msg_scroll_pin with
       | None | Some { T.pin_mode = T.Follow_live; _ } -> true
       | Some { T.pin_mode = (T.Hold_scroll | T.Hold_search); _ } -> false)) [false; true])

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
  let body = Search.body_identity "fixture" in
  let run ?(joins_previous=false) ~offset text : Search.run =
    {text;joins_previous;reading=Masc_tui_markdown.Source_order;
     positions=Array.init (String.length text) (fun byte ->
       Some (Search.Body_byte {body;offset=offset+byte;expansion=0}));
     visible_rows=[0,[{Masc_tui_markdown.start_byte=0;end_byte=String.length text}]]} in
  let search ?before needle runs = Search.find ~needle ~before ~body_rows:1 runs in
  let position = function
    | Some {Search.position=Body_byte {offset;_};_} -> offset
    | Some _ | None -> fail "expected an original source-byte match" in
  let overlapping=[run ~offset:0 "aaaaa"] in
  let newest=search "aaa" overlapping in
  check int "newest overlapping prefix" 2 (position newest);
  let middle=search ~before:(Search.Body_byte {body;offset=2;expansion=0}) "aaa" overlapping in
  check int "repeat retains middle overlapping prefix" 1 (position middle);
  check int "repeat retains oldest overlapping prefix" 0
    (position (search ~before:(Search.Body_byte {body;offset=1;expansion=0}) "aaa" overlapping));
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

let test_search_folds_unicode_case () =
  let module Search = Masc_tui_chat_search in
  let body = Search.body_identity "fixture" in
  let run text : Search.run =
    {text;joins_previous=false;reading=Masc_tui_markdown.Source_order;
     positions=Array.init (String.length text) (fun byte ->
       Some (Search.Body_byte {body;offset=byte;expansion=0}));
     visible_rows=[0,[{Masc_tui_markdown.start_byte=0;end_byte=String.length text}]]} in
  let search ?before needle text = Search.find ~needle ~before ~body_rows:1 [run text] in
  let span ?before needle text =
    match search ?before needle text with
    | Some {Search.position=Body_byte {offset=first;_};ending_position=Body_byte {offset=last;_};_} ->
        first,last
    | Some _ | None -> fail ("expected a case-folded source match for " ^ needle) in
  let check_span label expected needle text = check (pair int int) label expected (span needle text) in
  check_span "accented Latin capitals match small letters" (0,5) "école" "ÉCOLE";
  check_span "Cyrillic capitals match small letters" (0,11) "привет" "ПРИВЕТ";
  check_span "a sharp s matches a doubled capital S" (0,6) "STRASSE" "Straße";
  check_span "a doubled S matches a sharp s in the query" (0,6) "straße" "STRASSE";
  (* The Kelvin sign is three bytes and folds to the one byte [k]; the match
     after it must still land on the source bytes of ÉCOLE. *)
  check_span "a scalar folding shorter keeps later source offsets" (4,9) "école" "\xE2\x84\xAA ÉCOLE";
  check_span "a match on a shortened scalar covers all its source bytes" (0,2) "k" "\xE2\x84\xAA ÉCOLE";
  (* U+0390 is two bytes and folds to three scalars of six bytes. *)
  check_span "a scalar folding longer keeps later source offsets" (3,8) "école" "\xCE\x90 ÉCOLE";
  check_span "a query inside one folded scalar reports the whole scalar" (0,1) "s" "ß";
  check bool "both folded halves of one scalar are one occurrence" true
    (search ~before:(Search.Body_byte {body;offset=0;expansion=0}) "s" "ß" = None);
  check_span "a byte that is not UTF-8 is matched unchanged" (1,3) "abc" "\xFFABC"

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

let test_live_edge_seed_owns_source_position () = at_sizes (fun origin ->
  let state=state origin in
  state.msg_loaded <- [row ~id:"seed-source" ~request_id:"seed-source" ~role:user
    ~text:("\n\n" ^ long_answer "SEED_") 1.];
  ignore(frame_lines state);
  let pin=Option.get state.msg_scroll_pin in
  check bool "live-edge snapshot has at least one mapped source point" true
    (pin.pin_points<>[] && List.for_all (fun point -> Option.is_some point.T.source_position) pin.pin_points))

let test_live_edge_seed_survives_first_scroll_with_reflow () = at_sizes (fun origin ->
  let set_cols columns=ignore(Masc_tui_render_schedule.Terminal_size_cache.refresh
    Masc_tui_ansi.terminal_size_cache ~probe:(fun () -> Some(26,columns))) in
  let state=state origin in
  let body=String.concat "\n" (List.init 40 (fun n ->
    Printf.sprintf "LIVE_%03d %s END%03d" n (String.make 80 'x') n)) ^ " TAIL_END" in
  state.msg_loaded <- [row ~id:"live-seed-reflow" ~request_id:"live-seed-reflow"
    ~role:user ~text:body 1.];
  set_cols 160;
  let initial=frame_lines state in
  check bool "actual live-edge gap keeps latest output" true
    (List.exists (Astring.String.is_infix ~affix:"TAIL_END") initial);
  let pin=Option.get state.msg_scroll_pin in
  (match pin.pin_points with
   | [{T.source_position=Some(T.Durable_position(Masc_tui_chat_search.Body_byte {offset;_}));rows_below;_}] ->
       check int "seed owns actual visible tail endpoint" (String.length body-1) offset;
       check bool "seed distance is inside actual viewport" true (rows_below < List.length initial)
   | _ -> fail "live edge must seed one actual mapped tail endpoint");
  (* The input gesture precedes the next paint after resize. No narrow frame
     replaces the wide seed; the actual source endpoint must own recovery. *)
  set_cols 42;
  T.set_msg_scroll state 1;
  let shown=frame_lines state in
  check int "first scroll remains one row after reflow" 1 state.msg_scroll;
  check bool "scroll stays by the same latest output" true
    (List.exists (Astring.String.is_infix ~affix:"END038") shown))

let test_unmapped_blank_does_not_override_typed_pin () = at_sizes (fun origin ->
  let set_cols columns=ignore(Masc_tui_render_schedule.Terminal_size_cache.refresh
    Masc_tui_ansi.terminal_size_cache ~probe:(fun () -> Some(26,columns))) in
  let state=state origin in
  let paragraph=String.concat " " (List.init 100 (fun n -> Printf.sprintf "before%03d" n)) in
  state.msg_loaded <- [row ~id:"blank-reflow" ~request_id:"blank-reflow" ~role:user
    ~text:(paragraph ^ "\n\nPIN_HIT\n" ^ long_answer "TAIL_") 1.];
  set_cols 160;
  ignore(find state "PIN_HIT");
  let pin=Option.get state.msg_scroll_pin in
  let mapped=List.hd pin.pin_points in
  check bool "fixture's blank follows a physically wrapped paragraph" true (mapped.body_row>1);
  (* The two oldest visible points produced before this fix can be the blank
     immediately before the mapped row. Keep their genuine source/row values,
     then resize without a second find. The blank must not win by old ordinal. *)
  let blank={mapped with T.body_row=mapped.body_row-1;source_position=None;rows_below=1} in
  state.msg_scroll_pin <- Some {pin with pin_mode=T.Hold_scroll;pin_points=[blank;mapped]};
  set_cols 42;
  ignore(visible_line (frame_lines state) "PIN_HIT");
  check bool "feedback keeps only source-backed positions" true
    (List.for_all (fun point -> Option.is_some point.T.source_position)
       (Option.get state.msg_scroll_pin).pin_points))

let test_lost_source_points_release_numeric_scroll () = at_sizes (fun origin ->
  let state=state origin in
  state.msg_loaded <- [row ~id:"replaced" ~request_id:"replaced" ~role:user
    ~text:(long_answer "OLD_") 1.];
  ignore(find state "OLD_050");
  ignore(frame_lines state);
  state.msg_loaded <- [row ~id:"replaced" ~request_id:"replaced" ~role:user ~text:"replacement" 1.;
    row ~id:"arrival" ~request_id:"arrival" ~role:T.Message_keeper
      ~text:(long_answer "NEW_") 2.];
  let shown=screen state in
  check int "all removed source positions explicitly return to live edge" 0 state.msg_scroll;
  check bool "new arrival does not inherit the old numeric offset" true
    (Astring.String.is_infix ~affix:"NEW_099" shown);
  check bool "lost search pin is released" true
    (match state.msg_scroll_pin with None | Some {T.pin_mode=T.Follow_live;_} -> true | Some _ -> false))

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
  let module Preview = Masc.Keeper_turn_preview in
  let state = state origin in
  let writer = Preview.reset ~keeper_name:"alpha" ~now:120.
    ~redaction:Masc.Keeper_secret_redaction.empty in
  let stream delta = Preview.note_stream ~writer:(Some writer) ~now:121.
    (Agent_core.Types.ContentBlockDelta {index=0;delta}) in
  Preview.note_attempt ~writer:(Some writer) ~now:120. ~runtime_id:"fixture-runtime";
  let poll () =
    let preview = match Preview.current ~keeper_name:"alpha" with
      | Some preview -> preview | None -> fail "real preview writer disappeared" in
    check bool "actual producer suffix obeys its byte bound" true
      (String.length preview.text_tail <= Preview.tail_bytes);
    let wire = `Assoc ["schema",`String "masc.keeper_turns.v1";
      "keepers",`List [`Assoc ["keeper_name",`String "alpha";"status",`String "ok";
        "turn",`Assoc ["lane",`String "maintenance";
          "started_at_unix",`Float 120.;"interrupt_token",`String "exact-polled";
          "preview",Preview.to_json preview]]]] in
    state.keeper_turns <- (match Masc.Tui_decode.decode_keeper_turns wire with
      | Ok rows -> rows | Error detail -> fail detail);
    preview in
  (* Short released records provide enough real suffix rows for scrollback.
     ESC also exercises the shared sanitizer's visible expansion provenance. *)
  stream (Agent_core.Types.TextDelta
    (String.concat "" (List.init 100 (fun index -> Printf.sprintf "R%02d\027\n" index))));
  let initial = poll () in
  check bool "real writer dropped an earlier released prefix" true
    (initial.text_position.start_byte > 0);
  ignore (frame_lines state);
  let has_status_pin pin=List.exists (fun point -> match point.T.scroll_anchor with
    | T.Scroll_polled (_,_,T.Polled_status) -> true | _ -> false) pin.T.pin_points in
  check bool "live-edge seed excludes mutable polled status text" false
    (has_status_pin (Option.get state.msg_scroll_pin));
  T.set_msg_scroll state 5;
  let before = frame_lines state in
  let observed = List.init 100 (fun index -> Printf.sprintf "R%02d\\x1B" index)
    |> List.find (fun token -> List.exists (Astring.String.is_infix ~affix:token) before) in
  let pin = Option.get state.msg_scroll_pin in
  check bool "held viewport excludes mutable polled status text" false (has_status_pin pin);
  check bool "polled pin owns actual producer absolute bytes" true
    (List.exists (fun point -> match point.T.source_position with
      | Some (T.Polled_body_byte {offset;_}) -> offset >= initial.text_position.start_byte
      | _ -> false) pin.pin_points);
  check int "pin holds one immutable observed source" 1 (List.length pin.held_transients);
  stream (Agent_core.Types.TextDelta
    (String.concat "" (List.init 100 (fun index -> Printf.sprintf "N%02d\n" index))));
  let later = poll () in
  check bool "actual rolling prefix moved forward" true
    (later.text_position.start_byte > initial.text_position.start_byte);
  ignore (visible_line (frame_lines state) observed);
  stream (Agent_core.Types.TextSnapshot "SNAPSHOT_REPLACEMENT\n");
  let replacement = poll () in
  check bool "actual snapshot establishes a new generation" true
    (replacement.text_position.generation > initial.text_position.generation);
  ignore (visible_line (frame_lines state) observed);
  List.iter (fun columns ->
    ignore (Masc_tui_render_schedule.Terminal_size_cache.refresh
      Masc_tui_ansi.terminal_size_cache ~probe:(fun () -> Some (26,columns)));
    List.iter (fun display -> state.msg_origin_display <- display;
      ignore (visible_line (frame_lines state) observed))
      [Layout.Origin_inline;Origin_bare;Origin_row]) [42;140;60];
  state.keeper_turns <- [];
  ignore (log state ~id:"journal-takeover" ~at:130.
    [Live.Run_started;Live.Text {text="ACTUAL_JOURNAL_TAKEOVER";stream_scope=None};
     reply "ACTUAL_JOURNAL_TAKEOVER";Live.Run_finished]);
  ignore (visible_line (frame_lines state) observed);
  T.set_msg_scroll state 0;
  check bool "End releases held source immediately" true
    (Option.fold ~none:true ~some:(fun pin -> pin.T.held_transients=[]) state.msg_scroll_pin);
  let live = screen state in
  check bool "End shows actual journal" true
    (Astring.String.is_infix ~affix:"ACTUAL_JOURNAL_TAKEOVER" live);
  check bool "End removes frozen excerpt" true
    (not (Astring.String.is_infix ~affix:observed live)))

let test_rich_card_repeat_follows_interleaved_source_order () = at_sizes (fun origin ->
  let set_cols columns = ignore (Masc_tui_render_schedule.Terminal_size_cache.refresh
    Masc_tui_ansi.terminal_size_cache ~probe:(fun () -> Some (26,columns))) in
  let state=state origin in
  state.link_previews_mode <- `Rich;
  let url="https://example.test/interleaved-card" in
  let preview=Masc_tui_link_preview.synthesize_preview url in
  Masc_tui_link_preview.cache_store {preview with has_metadata=true;
    title=Some "WEB LINK";description=Some "source ordering"};
  state.msg_loaded <- [row ~id:"card-order" ~request_id:"card-order" ~role:user ~text:url 1.];
  set_cols 180;
  let newest=find state "WEB LINK" in
  check bool "initial find chooses lower primary title" true
    (match newest.matched_position with
     | Masc_tui_chat_search.Preview_byte {field=Card_title;_} -> true | _ -> false);
  let older=find ~older:newest state "WEB LINK" in
  check bool "repeat moves upward to the header banner" true
    (match older.matched_position with
     | Masc_tui_chat_search.Preview_byte {field=Banner_brand;_} -> true | _ -> false);
  set_cols 42;
  check bool "narrow reflow cannot revisit newer title after banner cursor" true
    ((Render.keeper_message_find_scroll state ~keeper_name:"alpha" ~needle:"WEB LINK"
      ~older_than:(Some older)).match_result=None);
  set_cols 180;
  check bool "widening cannot restart exhausted interleaved sources" true
    ((Render.keeper_message_find_scroll state ~keeper_name:"alpha" ~needle:"WEB LINK"
      ~older_than:(Some older)).match_result=None))

(* The OpenGraph fetch replaces a synthesized title in place. The repeat cursor
   taken inside the old title names no byte of the new one: the replaced title
   is searched whole, and its occurrence keeps the new text as its identity. *)
let test_replaced_preview_title_is_searched_whole () = at_sizes (fun origin ->
  let state=state origin in
  state.link_previews_mode <- `Rich;
  let url="https://example.test/renamed-card" in
  let preview=Masc_tui_link_preview.synthesize_preview url in
  let store title = Masc_tui_link_preview.cache_store {preview with has_metadata=true;
    title=Some title;description=Some "plain description"} in
  store "REPLACED first";
  state.msg_loaded <- [row ~id:"replaced" ~request_id:"replaced" ~role:user ~text:url 1.];
  let first=find state "REPLACED" in
  let title_value (cursor : T.chat_search_cursor) = match cursor.matched_position with
    | Masc_tui_chat_search.Preview_byte {field=Card_title;value;byte;_} -> Some (value,byte)
    | Preview_byte _ | Body_byte _ | Body_label _ | Thinking_summary_byte _
    | Thinking_summary_label _ | Projected_byte _ | Projected_label _ | Journal_byte _
    | Request_byte _ -> None in
  check (option (pair string int)) "first find is in the original title"
    (Some ("REPLACED first",0)) (title_value first);
  store "later REPLACED";
  let after=find ~older:first state "REPLACED" in
  check (option (pair string int)) "repeat reaches the replaced title, not an offset into the old one"
    (Some ("later REPLACED",6)) (title_value after))

(* A recorded reply stands where the streamed text was, under the same anchor.
   A repeat cursor taken in the streamed text names no byte of the reply, so
   the reply is searched whole from its newest occurrence. The fixture texts
   are chosen so the streamed text's identity orders before the reply's: an
   offset comparison alone would skip every occurrence of the reply. *)
let test_replaced_body_is_searched_whole () =
  let module Search = Masc_tui_chat_search in
  let run body text : Search.run =
    {text;joins_previous=false;reading=Masc_tui_markdown.Source_order;
     positions=Array.init (String.length text) (fun offset ->
       Some (Search.Body_byte {body;offset;expansion=0}));
     visible_rows=[0,[{Masc_tui_markdown.start_byte=0;end_byte=String.length text}]]} in
  let streamed=Search.body_identity "streamed hit" in
  let reply_text="hit recorded hit" in
  let reply=Search.body_identity reply_text in
  let cursor=Search.Body_byte {body=streamed;offset=9;expansion=0} in
  match Search.find ~needle:"hit" ~before:(Some cursor) ~body_rows:1 [run reply reply_text] with
  | Some {Search.position=Body_byte {body;offset;_};_} ->
      check int "the newest occurrence of the reply" 13 offset;
      check bool "the occurrence names the reply's text" true (body=reply)
  | Some _ | None -> fail "the replaced body was not searched"

(* A Mermaid diagnostic is regenerated for the current width while the body
   stays the same. A repeat cursor in the old diagnostic names no byte of the
   new one, so the new diagnostic is searched from its newest occurrence. The
   old text orders before the new: an offset comparison alone would skip it. *)
let test_regenerated_label_is_searched_whole () =
  let module Search = Masc_tui_chat_search in
  let prose="```mermaid\nflowchart LR\nA-->B\n```" in
  let body=Search.body_identity prose in
  let runs value =
    let label : Masc_tui_markdown.semantic_run = {
      joins_previous=false; semantic_text=value;
      origins=Array.init (String.length value) (fun byte ->
        Some (Masc_tui_markdown.Generated {block_start=0;field=Mermaid_diagnostic;byte}));
      visible_rows=[0,[{start_byte=0;end_byte=String.length value}]];
      reading=Source_order } in
    fst (Search.of_document ~presentation:Layout.Source_body ~body ~body_length:(String.length prose)
      ~origins:(Array.make (String.length prose) None)
      {document_rows=[value];semantic_runs=[label];mapping=Complete_document}) in
  let label_of = function
    | Some {Search.position=Body_label {value;byte;_};_} -> Some (value,byte)
    | Some _ | None -> None in
  let cursor = match Search.find ~needle:"hit" ~before:None ~body_rows:1 (runs "hit at 120 columns") with
    | Some found -> found.position
    | None -> fail "the first diagnostic has a match" in
  check (option (pair string int)) "the regenerated diagnostic is searched from its newest occurrence"
    (Some ("hit at 80 columns, hit",19))
    (label_of (Search.find ~needle:"hit" ~before:(Some cursor) ~body_rows:1 (runs "hit at 80 columns, hit")))

(* The status row an unavailable observed journal leaves has no search anchor.
   Its text is drawn, so a search that cannot read it reports the entry as
   unsearched instead of reporting nothing. *)
let test_unanchored_status_row_counts_as_unsearched () =
  let state=state Layout.Origin_inline in
  let journal=log state ~id:"unavailable-journal" ~at:10.
    [Live.Run_started;Live.Text {text="STREAMED_TEXT";stream_scope=None}] in
  state.msg_journal_unavailable <- [T.turn_log_journal_key journal];
  let result=Render.keeper_message_find_scroll state ~keeper_name:"alpha"
    ~needle:"받은 기록" ~older_than:None in
  check bool "the status row has no searchable match" true (result.match_result=None);
  check int "the status row counts as unsearched" 1 result.unavailable_entries

(* A reply whose drawing left a label unmapped keeps its mapped runs: they are
   searched, and the omitted label still makes the entry incomplete. *)
let test_partially_mapped_document_keeps_its_mapped_runs () =
  let prose="PARTIAL prose" in
  let mapped_run : Masc_tui_markdown.semantic_run = {
    joins_previous=false; semantic_text=prose;
    origins=Array.init (String.length prose) (fun byte ->
      Some (Masc_tui_markdown.Original {start_byte=byte;end_byte=byte+1}));
    visible_rows=[0,[{start_byte=0;end_byte=String.length prose}]];
    reading=Source_order } in
  let label="lang" in
  let unmapped_run : Masc_tui_markdown.semantic_run = {
    joins_previous=false; semantic_text=label;
    origins=Array.init (String.length label) (fun byte ->
      Some (Masc_tui_markdown.Generated {block_start=String.length prose;field=Fence_language;byte}));
    visible_rows=[1,[{start_byte=0;end_byte=String.length label}]];
    reading=Source_order } in
  let document : Masc_tui_markdown.document_render = {
    document_rows=[prose;label]; semantic_runs=[mapped_run;unmapped_run];
    mapping=Incomplete_document [0,[]] } in
  let body=Masc_tui_chat_search.body_identity prose in
  let origins=Array.init (String.length prose) (fun offset ->
    Some (Masc_tui_chat_search.Body_byte {body;offset;expansion=0})) in
  let runs,unavailable=Masc_tui_chat_search.of_document ~presentation:Layout.Source_body
    ~body ~body_length:(String.length prose) ~origins document in
  check bool "the omitted portions keep the entry incomplete" true unavailable;
  check (list string) "only the completely mapped run is retained" [prose]
    (List.map (fun (run : Masc_tui_chat_search.run) -> run.text) runs);
  check bool "the mapped prose is found" true
    (Option.is_some (Masc_tui_chat_search.find ~needle:"PARTIAL" ~before:None ~body_rows:2 runs))

let test_search_executor_owns_frozen_source () = at_sizes (fun origin ->
  let state=state origin in
  state.link_previews_mode <- `Off;
  let original=row ~id:"executor-owned" ~request_id:"executor-owned" ~role:user
    ~text:"OLDER_MATCH newest MATCH" 1. in
  state.msg_loaded <- [original];
  let work=Render.prepare_keeper_message_search state ~keeper_name:"alpha"
    ~needle:"MATCH" ~older_than:None in
  Eio_main.run (fun env -> Eio.Switch.run (fun sw ->
    let pool=Domain_pool.create ~sw ~domain_count:1 (Eio.Stdenv.domain_mgr env) in
    let started,started_resolver=Eio.Promise.create () in
    let release,release_resolver=Eio.Promise.create () in
    let completed,completed_resolver=Eio.Promise.create () in
    let owner=Domain.self () in
    Eio.Fiber.fork ~sw (fun () ->
      let result=Domain_pool.submit_cpu pool (fun () ->
        Eio.Promise.resolve started_resolver (Domain.self () <> owner);
        Eio.Promise.await release;
        Render.run_keeper_message_search work) in
      Eio.Promise.resolve completed_resolver result);
    check bool "matching is admitted on an actual different executor domain" true
      (Eio.Promise.await started);
    (* The UI domain resumes while its search waits independently. Arrivals
       cannot mutate the already-owned producer runs in that worker. *)
    state.link_previews_mode <- `Rich;
    check bool "changed card presentation rejects the frozen job" false
      (Render.keeper_message_search_is_current state work);
    state.link_previews_mode <- `Off;
    state.msg_loaded <- [{original with me_text="REPLACED_SOURCE"}];
    check bool "source replacement rejects the frozen job's admission" false
      (Render.keeper_message_search_is_current state work);
    Eio.Promise.resolve release_resolver ();
    let answer=Eio.Promise.await completed in
    let result=Render.complete_keeper_message_search work answer in
    let _,cursor=Option.get result.match_result in
    check bool "worker searched the actual frozen original occurrence" true
      (match cursor.T.matched_position with Masc_tui_chat_search.Body_byte {offset;_} ->
        offset=19 | _ -> false);
    state.msg_loaded <- [original];
    let execution=T.turn_log_create ~keeper_name:"alpha" ~request_id:"metadata-only" ~started_at:2. in
    let occurrence : Live.tool_occurrence = {stream_scope=0;block_index=1;
      provider_message_id=None;tool_call_id=Some "metadata-only-native"} in
    T.turn_log_add ~now:2. execution ~seq:(Some 0) Live.Run_started;
    T.turn_log_add ~now:3. execution ~seq:(Some 1)
      (Live.Native_tool_started {occurrence;tool_name=Some "Execute"});
    state.msg_live <- Some execution;
    let admitted=Render.admit_keeper_message_search state work answer in
    check bool "unchanged settled speech survives new live tool metadata/suffix" true
      (Option.is_some admitted);
    let current=Option.get admitted in
    check bool "reprojection preserves exact original occurrence" true
      (match current.match_result with Some (_,held) -> held.T.matched_position=cursor.matched_position | None -> false);
    T.apply_clamped_scroll state (T.Message_scroll (fst (Option.get current.match_result)));
    check bool "reprojected current frame shows actual matched speech" true
      (Astring.String.is_infix ~affix:"newest MATCH" (screen state));
    let before_retarget=Atomic.get state.msg_search_generation in
    state.msg_target_keeper_name <- Some "beta";
    T.restore_keeper_chat_page state "beta";
    state.msg_target_keeper_name <- Some "alpha";
    T.restore_keeper_chat_page state "alpha";
    state.msg_loaded <- [original];
    check bool "actual page restore retires alpha/beta/alpha generation" true
      (Atomic.get state.msg_search_generation > before_retarget);
    check bool "returned alpha cannot admit the old owned search" true
      (Option.is_none (Render.admit_keeper_message_search state work answer));
    T.suspend_workspace_readings state;
    check bool "retired workspace generation cannot admit old answer" true
      (Option.is_none (Render.admit_keeper_message_search state work answer));
    let older=Render.prepare_keeper_message_search state ~keeper_name:"alpha"
      ~needle:"MATCH" ~older_than:(Some cursor) in
    let repeated=Render.complete_keeper_message_search older
      (Domain_pool.submit_cpu pool (fun () -> Render.run_keeper_message_search older)) in
    let _,earlier=Option.get repeated.match_result in
    check bool "executor result keeps repeat source ordering" true
      (Masc_tui_chat_search.compare_position earlier.matched_position cursor.matched_position < 0))))

let test_navigation_retires_a_running_search () = at_sizes (fun origin ->
  let state=state origin in
  state.msg_loaded <- [row ~id:"navigated" ~request_id:"navigated" ~role:user
    ~text:"OLDER_MATCH newest MATCH" 1.];
  (* Scrolling back (a key or the wheel) and returning to the live edge (End,
     Ctrl-E, sending) both go through set_msg_scroll. *)
  List.iter (fun (label, rows) ->
    let plan=Render.plan_keeper_message_search state ~keeper_name:"alpha"
      ~needle:"MATCH" ~older_than:None in
    let work=Render.prepare_keeper_message_search state ~keeper_name:"alpha"
      ~needle:"MATCH" ~older_than:None in
    check bool ("precondition: the fresh search is owned before " ^ label) true
      (Render.keeper_message_search_owned state plan);
    let answer=Render.run_keeper_message_search work in
    T.set_msg_scroll state rows;
    check bool (label ^ " retires the running search") false
      (Render.keeper_message_search_owned state plan);
    check bool (label ^ ": the late answer cannot move the view") true
      (Option.is_none (Render.admit_keeper_message_search state work answer)))
    ["scrolling back", 3; "returning to the live edge", 0])

(* A view stance rewrites a tool, skill, Memory or reasoning body from the same
   typed data while the row's identity stays. A reader scrolled inside that
   body stays on the row in its new text: the old offsets neither land on an
   unrelated line of the new text nor drop the reader at the live edge. *)
let test_view_stance_keeps_reader_on_its_entry () = at_sizes (fun origin ->
  let module Transcript = Masc_tui_keeper_chat_transcript in
  let call name index = Transcript.make_tool_activity
      ~execution_id:(Printf.sprintf "stance-exec-%02d" index) ~call_id:None
      ~tool_name:(name index) ~args:"{}" ~outcome:Transcript.Returned ~duration:None () in
  let entry role text = row ~id:"stance-entry" ~request_id:"stance-entry" ~role ~text 1. in
  let tool name = {(entry T.Message_tool "tools") with
    me_tool_block=Some (Transcript.tool_block (List.init 60 (call name)))} in
  let cases = [
    "tool full to compact", tool (fun _ -> "fixture_tool"),
      (fun state -> state.T.msg_tool_visibility <- T.Tools_full),
      (fun state -> state.T.msg_tool_visibility <- T.Tools_compact), "fixture_tool";
    "tool full to results", tool (Printf.sprintf "TOOLCALL_%02d"),
      (fun state -> state.T.msg_tool_visibility <- T.Tools_full),
      (fun state -> state.T.msg_tool_visibility <- T.Tools_results), "TOOLCALL_00";
    "tool results to full", tool (Printf.sprintf "TOOLCALL_%02d"),
      (fun state -> state.T.msg_tool_visibility <- T.Tools_results),
      (fun state -> state.T.msg_tool_visibility <- T.Tools_full), "TOOLCALL_00";
    "skill full to compact",
      {(entry (T.Message_skill Transcript.Skill_used) "skill") with
        me_skill_block=[Transcript.make_skill_activity ~skill_name:"FIXTURE_SKILL"
          ~state:Transcript.Skill_used
          ~actions:(List.init 60 (Printf.sprintf "action_%02d")) ()]},
      (fun state -> state.T.msg_tool_visibility <- T.Tools_full),
      (fun state -> state.T.msg_tool_visibility <- T.Tools_compact), "FIXTURE_SKILL";
    "memory full to summary",
      {(entry T.Message_memory (long_answer "MEMORY_LINE_")) with
        me_memory_summary=Some "MEMORY_SUMMARY"},
      (fun state -> state.T.msg_memory_visibility <- T.Memory_full),
      (fun state -> state.T.msg_memory_visibility <- T.Memory_summary), "MEMORY_SUMMARY";
    "reasoning full to folded", entry T.Message_thinking (long_answer "REASONING_LINE_"),
      (fun state -> state.T.msg_reasoning_visibility <- T.Reasoning_full),
      (fun state -> state.T.msg_reasoning_visibility <- T.Reasoning_folded), "lines folded" ] in
  List.iter (fun (name, stance_entry, before, after, expected) ->
    let state = state origin in
    before state;
    state.msg_loaded <- [
      row ~id:"stance-question" ~request_id:"stance-question" ~role:user ~text:"STANCE_QUESTION" 0.;
      stance_entry;
      row ~id:"stance-reply" ~request_id:"stance-reply" ~role:T.Message_keeper
        ~text:(long_answer "STANCE_REPLY_") 3. ];
    ignore (find state "STANCE_REPLY_000");
    (* Twelve rows above the reply's first row: every drawn row of the frame
       belongs to the long entry. *)
    T.set_msg_scroll state (state.msg_scroll + 12);
    let inside = screen state in
    check bool (name ^ ": the fixture reads inside the entry") false
      (Astring.String.is_infix ~affix:"STANCE_REPLY_" inside
       || Astring.String.is_infix ~affix:"STANCE_QUESTION" inside);
    after state;
    let shown = frame_lines state in
    check bool (name ^ ": the stance change does not jump to the live edge") false
      (List.exists (Astring.String.is_infix ~affix:"STANCE_REPLY_099") shown);
    ignore (visible_line shown expected);
    check (option int) (name ^ ": the first drawn body row is the entry's first") (Some 0)
      (Option.bind state.msg_scroll_pin (fun pin -> match pin.T.pin_points with
         | point :: _ -> Some point.T.body_row | [] -> None));
    assert_still_reading state expected) cases)

(* /find reads a plan and returns. A daemon fiber on the UI domain renders the
   candidates afterwards, one entry per yield, and a newer generation stops it
   before it delivers anything. [seek_in_chat] posts its notice between the
   plan and the launch, so nothing is rendered before the notice either. *)
let test_find_renders_candidates_after_the_handler_returns () = at_sizes (fun origin ->
  let state = state origin in
  let entries = 40 in
  state.msg_loaded <- List.init entries (fun index ->
    let id = Printf.sprintf "steps-%02d" index in
    row ~id ~request_id:id ~role:user ~text:(Printf.sprintf "STEP_MATCH %02d" index)
      (float_of_int index));
  let built = Render.For_testing.search_candidate_build_count in
  Fun.protect ~finally:Domain_pool_ref.clear_for_tests (fun () ->
    Eio_main.run (fun env -> Eio.Switch.run (fun sw ->
      Eio_context.set_switch sw;
      Domain_pool_ref.set (Domain_pool.create ~sw ~domain_count:1 (Eio.Stdenv.domain_mgr env));
      let start ~deliver =
        Atomic.incr state.msg_search_generation;
        let before_plan = built () in
        let plan = Render.plan_keeper_message_search state ~keeper_name:"alpha"
            ~needle:"STEP_MATCH" ~older_than:None in
        check int "the plan renders no candidate" before_plan (built ());
        Render.launch_keeper_message_search state plan ~deliver;
        check int "the handler returns before any candidate is rendered" before_plan (built ());
        before_plan in
      let answer, resolve = Eio.Promise.create () in
      let first = start ~deliver:(Eio.Promise.resolve resolve) in
      (match Eio.Promise.await answer with
       | Error detail -> fail detail
       | Ok (work, matched) ->
           check int "a search left alone renders every candidate" entries (built () - first);
           check bool "and its answer lands on a match" true
             (Option.is_some (Render.complete_keeper_message_search work matched).match_result));
      let delivered = ref 0 in
      let second = start ~deliver:(fun _ -> incr delivered) in
      let rec until_rendering () =
        if built () - second < 3 then (Eio.Fiber.yield (); until_rendering ()) in
      until_rendering ();
      Atomic.incr state.msg_search_generation;
      let at_retire = built () in
      (* Each yield here lets the fiber take one more step, enough to finish
         every remaining entry and submit the matcher had it kept going. *)
      for _ = 1 to 4 * entries do Eio.Fiber.yield () done;
      check int "a retired generation renders no further candidate" at_retire (built ());
      check bool "it stopped before the last candidate" true (at_retire - second < entries);
      check int "a retired search delivers nothing" 0 !delivered))))

(* A no-match answer is about the durable rows. Pending input that arrives
   while the worker runs sits after them and must not make the answer stale. *)
let test_no_match_survives_pending_arrival () = at_sizes (fun origin ->
  let state = state origin in
  state.link_previews_mode <- `Off;
  let original = row ~id:"durable" ~request_id:"durable" ~role:user
    ~text:"durable words only" 1. in
  state.msg_loaded <- [original];
  let work = Render.prepare_keeper_message_search state ~keeper_name:"alpha"
    ~needle:"ABSENT_NEEDLE" ~older_than:None in
  let request = Chat.create_request ~keeper_name:"alpha" ~message:"queued while searching" () in
  let live = T.turn_log_create ~keeper_name:"alpha" ~request_id:request.request_id ~started_at:2. in
  state.msg_inflight <- [{T.sent_request=request;submitted_at=2.;sent_at=2.;
    control_generation=0;phase=T.Turn_streaming;log=live}];
  check bool "precondition: the arrival is a pending tail row" true
    (List.exists (function Some (T.Scroll_pending _) -> true | Some _ | None -> false)
      (Render.keeper_message_projection state ~keeper_name:"alpha" ~chat_cols:80).transient_anchors);
  check bool "a pending arrival keeps the no-match search current" true
    (Render.keeper_message_search_is_current state work);
  let answer = Render.run_keeper_message_search work in
  check bool "the no-match answer is admitted" true
    (Option.is_some (Render.admit_keeper_message_search state work answer));
  state.msg_loaded <- [{original with me_text="durable words changed"}];
  check bool "a durable change still makes the search stale" false
    (Render.keeper_message_search_is_current state work))

(* A held excerpt keeps its place among the producer's rows: the frozen
   speech stays before the live status, and an excerpt the producer has
   replaced stays before the replacement. *)
let test_held_polled_keeps_chronology () = at_sizes (fun origin ->
  let module Preview = Masc.Keeper_turn_preview in
  let state = state origin in
  let writer = Preview.reset ~keeper_name:"alpha" ~now:120.
    ~redaction:Masc.Keeper_secret_redaction.empty in
  let stream delta = Preview.note_stream ~writer:(Some writer) ~now:121.
    (Agent_core.Types.ContentBlockDelta {index=0;delta}) in
  Preview.note_attempt ~writer:(Some writer) ~now:120. ~runtime_id:"fixture-runtime";
  let poll () =
    let preview = match Preview.current ~keeper_name:"alpha" with
      | Some preview -> preview | None -> fail "real preview writer disappeared" in
    let wire = `Assoc ["schema",`String "masc.keeper_turns.v1";
      "keepers",`List [`Assoc ["keeper_name",`String "alpha";"status",`String "ok";
        "turn",`Assoc ["lane",`String "maintenance";
          "started_at_unix",`Float 120.;"interrupt_token",`String "held-order";
          "preview",Preview.to_json preview]]]] in
    state.keeper_turns <- (match Masc.Tui_decode.decode_keeper_turns wire with
      | Ok rows -> rows | Error detail -> fail detail) in
  let parts () =
    (Render.keeper_message_projection state ~keeper_name:"alpha" ~chat_cols:80).transient_anchors
    |> List.filter_map (function
      | Some (T.Scroll_polled (_, generation, part)) -> Some (generation, part)
      | Some _ | None -> None) in
  stream (Agent_core.Types.TextDelta
    (String.concat "" (List.init 100 (fun index -> Printf.sprintf "R%02d\n" index))));
  poll ();
  ignore (frame_lines state);
  T.set_msg_scroll state 5;
  ignore (frame_lines state);
  check int "precondition: the reader holds one polled excerpt" 1
    (List.length (Option.get state.msg_scroll_pin).T.held_transients);
  check bool "the held speech stays before the live status" true
    (match parts () with
     | [(_, T.Polled_speech); (_, T.Polled_status)] -> true
     | _ -> false);
  stream (Agent_core.Types.TextSnapshot "SNAPSHOT_REPLACEMENT\n");
  poll ();
  check bool "the replaced excerpt stays before the new generation" true
    (match parts () with
     | [(older, T.Polled_speech); (newer, T.Polled_speech); (_, T.Polled_status)] -> older < newer
     | _ -> false))

(* A retired search stops before its next candidate. The answer it returns is
   discarded by the generation check, so it only has to stop early. *)
let test_retired_matcher_stops_before_next_candidate () =
  let state = state Layout.Origin_inline in
  state.msg_loaded <- [row ~id:"retired-scan" ~request_id:"retired-scan" ~role:user
    ~text:"RETIRED_MATCH" 1.];
  let work = Render.prepare_keeper_message_search state ~keeper_name:"alpha"
    ~needle:"RETIRED_MATCH" ~older_than:None in
  let found answer =
    (Render.complete_keeper_message_search work answer).match_result in
  check bool "a live matcher finds the candidate" true
    (Option.is_some (found (Render.run_keeper_message_search work)));
  let asked = ref 0 in
  let retired () = incr asked; false in
  check bool "a retired matcher scans no candidate" true
    (Option.is_none (found (Render.run_keeper_message_search ~live:retired work)));
  check int "it asks once and stops" 1 !asked

(* The first scroll key holds the polled speech the last frame painted, even
   when a poll rolled the preview tail between that frame and the key. *)
let test_first_scroll_holds_the_painted_preview () = at_sizes (fun origin ->
  let module Preview = Masc.Keeper_turn_preview in
  let state = state origin in
  let writer = Preview.reset ~keeper_name:"alpha" ~now:120.
    ~redaction:Masc.Keeper_secret_redaction.empty in
  let stream delta = Preview.note_stream ~writer:(Some writer) ~now:121.
    (Agent_core.Types.ContentBlockDelta {index=0;delta}) in
  Preview.note_attempt ~writer:(Some writer) ~now:120. ~runtime_id:"fixture-runtime";
  let poll () =
    let preview = match Preview.current ~keeper_name:"alpha" with
      | Some preview -> preview | None -> fail "real preview writer disappeared" in
    let wire = `Assoc ["schema",`String "masc.keeper_turns.v1";
      "keepers",`List [`Assoc ["keeper_name",`String "alpha";"status",`String "ok";
        "turn",`Assoc ["lane",`String "maintenance";
          "started_at_unix",`Float 120.;"interrupt_token",`String "first-scroll";
          "preview",Preview.to_json preview]]]] in
    state.keeper_turns <- (match Masc.Tui_decode.decode_keeper_turns wire with
      | Ok rows -> rows | Error detail -> fail detail);
    preview in
  stream (Agent_core.Types.TextDelta
    (String.concat "" (List.init 100 (fun index -> Printf.sprintf "P%02d\n" index))));
  let painted = poll () in
  ignore (frame_lines state);
  stream (Agent_core.Types.TextDelta
    (String.concat "" (List.init 100 (fun index -> Printf.sprintf "Q%02d\n" index))));
  let rolled = poll () in
  check bool "precondition: the poll rolled the tail before the key" true
    (rolled.text_position.start_byte > painted.text_position.start_byte);
  T.set_msg_scroll state 5;
  let held = (Option.get state.msg_scroll_pin).T.held_transients in
  check int "the first scroll key holds one polled excerpt" 1 (List.length held);
  check bool "it is the preview the last frame painted" true
    (List.for_all (fun excerpt ->
       excerpt.T.held_preview.Masc.Tui_decode.ktp_text_position.kpp_start_byte
       = painted.text_position.start_byte) held))

let () = run "chat search projection" [
  "rendered conversation", [
    test_case "navigation retires a running search" `Quick test_navigation_retires_a_running_search;
    test_case "retired matcher stops before its next candidate" `Quick
      test_retired_matcher_stops_before_next_candidate;
    test_case "find renders candidates after the handler returns" `Quick
      test_find_renders_candidates_after_the_handler_returns;
    test_case "view stance keeps the reader on its entry" `Quick test_view_stance_keeps_reader_on_its_entry;
    test_case "search executor owns frozen source and keeps repeat cursor" `Quick test_search_executor_owns_frozen_source;
    test_case "rich card repeat follows interleaved source sequence" `Quick test_rich_card_repeat_follows_interleaved_source_order;
    test_case "replaced preview title is searched whole" `Quick test_replaced_preview_title_is_searched_whole;
    test_case "partially mapped document keeps its mapped runs" `Quick
      test_partially_mapped_document_keeps_its_mapped_runs;
    test_case "replaced body is searched whole" `Quick test_replaced_body_is_searched_whole;
    test_case "regenerated label is searched whole" `Quick test_regenerated_label_is_searched_whole;
    test_case "unanchored status row counts as unsearched" `Quick
      test_unanchored_status_row_counts_as_unsearched;
    test_case "empty projection follows future arrivals" `Quick test_empty_projection_does_not_hold_future_arrivals;
    test_case "polled absolute source survives rolling and journal takeover" `Quick test_polled_source_survives_tail_and_journal_takeover;
    test_case "live-edge seed survives first scroll with reflow" `Quick test_live_edge_seed_survives_first_scroll_with_reflow;
    test_case "live-edge seed owns a source position" `Quick test_live_edge_seed_owns_source_position;
    test_case "unmapped blank cannot override typed pin after reflow" `Quick test_unmapped_blank_does_not_override_typed_pin;
    test_case "lost source points release stale numeric scroll" `Quick test_lost_source_points_release_numeric_scroll;
    test_case "idle search pin reuses semantic and URL indexes" `Quick test_idle_search_pin_reuses_semantic_index;
    test_case "search pin preserves query endpoint through width and gutters" `Quick test_search_pin_retains_query_endpoint_through_reflow;
    test_case "semantic search repetitive prefixes and optional boundaries" `Quick test_semantic_search_repetitive_prefix_and_boundaries;
    test_case "search folds Unicode case and keeps source scalar offsets" `Quick test_search_folds_unicode_case;
    test_case "bottom-up diagram repeat follows drawn rows" `Quick
      test_bottom_up_diagram_repeat_follows_drawn_rows;
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
    test_case "first scroll holds the painted preview" `Quick
      test_first_scroll_holds_the_painted_preview;
    test_case "no-match search survives a pending arrival" `Quick
      test_no_match_survives_pending_arrival;
    test_case "held polled excerpt keeps its chronology" `Quick
      test_held_polled_keeps_chronology;
    test_case "reply alias uses recorded execution source" `Quick test_reply_alias_uses_recorded_execution_source;
    test_case "scroll pin follows history and canonical reply aliases" `Quick
      test_pin_aliases_history_and_canonical_reply;
    test_case "search pins before the first frame and releases at the live edge" `Quick
      test_search_pin_before_first_frame_and_at_tail;
    test_case "receipt repeat preserves request identity through batch binding" `Quick
      test_admission_repeat_survives_batch_binding;
    test_case "receipt pin survives binding before paint and long reply arrival" `Quick
      test_admission_pin_survives_batch_reply_arrival ] ]
