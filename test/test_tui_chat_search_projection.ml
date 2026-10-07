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

let screen state =
  let frame, clamped = Render.render_keeper_message state in
  Option.iter (T.apply_clamped_scroll state) clamped;
  frame.Masc_tui_frame_presenter.lines
  |> List.map Masc_tui_theme.strip_sgr |> String.concat "\n"

let count text needle = List.length (Astring.String.cuts ~sep:needle text) - 1

let find ?older state needle =
  match Render.keeper_message_find_scroll state ~keeper_name:"alpha"
      ~needle ~older_than:older with
  | None -> fail ("visible conversation match missing: " ^ needle)
  | Some (scroll, cursor) -> T.set_msg_scroll_absolute state scroll; cursor

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
   | T.Search_journal _ -> fail "search repeated a newer journal item");
  check bool "no older match ends the walk" true
    (Option.is_none (Render.keeper_message_find_scroll state ~keeper_name:"alpha"
       ~needle:"MATCH_" ~older_than:(Some history)));
  T.turn_log_add ~now:20. held ~seq:(Some 4) (reply "MATCH_REPLY canonical");
  T.turn_log_add ~now:21. held ~seq:(Some 5) Live.Run_finished;
  Log.commit held.tl_log;
  let settled = find state "MATCH_REPLY" in
  (match settled.matched_anchor, latest.matched_anchor with
   | T.Search_journal settled, T.Search_journal latest ->
       check bool "canonical replacement preserves the matched stretch identity" true
         (settled.origin = latest.origin && settled.source = latest.source)
   | _ -> fail "journal reply lost its source anchor");
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

let () = run "chat search projection" [
  "rendered conversation", [
    test_case "held replies and full suffix geometry" `Quick test_settled_reply_and_complete_suffix;
    test_case "repeat across visibility, backfill and finalization" `Quick
      test_repeat_survives_reasoning_visibility_and_backfill;
    test_case "repeat across source and workspace replacement" `Quick
      test_repeat_across_history_journal_replacement;
    test_case "frame feedback consumes arrival compensation" `Quick
      test_frame_feedback_consumes_arrival_compensation ] ]
