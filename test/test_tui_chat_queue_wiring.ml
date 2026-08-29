(** The queue is wired into the two places that make it work.

    The pure ordering and cap live in [Masc_tui_keeper_chat_queue] and are
    tested there. What cannot be tested there is that the executable actually
    uses it: a queue nothing pushes to is a refusal with extra steps, and a
    queue nothing drains is a message that never arrives. Both were the bug —
    Enter during a turn answered "Keeper message already in progress" and threw
    the text away. *)

open Alcotest

module Keeper_chat = Masc_tui_keeper_chat_projection
module Keeper_chat_transcript = Masc_tui_keeper_chat_transcript
module Tui_types = Masc_tui_types

let calls ~module_path ~callee = Ast_grep.count_calls ~module_path ~callee

(* Scrolling back and asking for what is behind it are the same act. They used
   to be three copies of the same four lines, and [pageup] was missing its
   copy: a page-at-a-time reader stopped at whatever the first load happened to
   bring in. Going back through one place is what stops it being forgotten
   again, so the executable has to actually go through it (#31089). *)
let test_every_way_back_asks_for_what_is_behind_it () =
  let n = calls ~module_path:"bin/masc_tui.ml" ~callee:"scroll_back" in
  if n < 3 then
    failf
      "every way of scrolling back (arrow, wheel, page) must ask for older \
       history through scroll_back; it is called %d time(s)"
      n
;;

let entry_at at : Tui_types.msg_entry =
  { Tui_types.me_keeper_name = "alpha"
  ; me_role = Tui_types.Message_keeper
  ; me_text = Printf.sprintf "row at %.0f" at
  ; me_tool_block = None
  ; me_timestamp = ""
  ; me_request_id = ""
  ; me_at = at
  }

let ats entries =
  List.map (fun (e : Tui_types.msg_entry) -> e.Tui_types.me_at) entries

(* The refresh brings the newest window. Anything the operator paged back to is
   older than that window and has to survive the tick. *)
let test_a_refresh_keeps_what_was_paged_back_to () =
  let paged = [ entry_at 100.; entry_at 200. ] in
  let fresh = [ entry_at 300.; entry_at 400. ] in
  check
    (list (float 0.001))
    "older rows kept, fresh window appended"
    [ 100.; 200.; 300.; 400. ]
    (ats (Tui_types.merge_paged_history ~paged ~fresh))
;;

(* Rows the fresh window already carries come back in it, so keeping the paged
   copy too would show them twice. *)
let test_a_refresh_does_not_double_the_overlap () =
  let paged = [ entry_at 100.; entry_at 300.; entry_at 400. ] in
  let fresh = [ entry_at 300.; entry_at 400.; entry_at 500. ] in
  check
    (list (float 0.001))
    "only rows older than the window survive"
    [ 100.; 300.; 400.; 500. ]
    (ats (Tui_types.merge_paged_history ~paged ~fresh))
;;

(* A window that came back empty says nothing about what is behind it, so it
   is not a reason to drop what is held. *)
let test_an_empty_refresh_keeps_the_transcript () =
  let paged = [ entry_at 100.; entry_at 200. ] in
  check
    (list (float 0.001))
    "kept"
    [ 100.; 200. ]
    (ats (Tui_types.merge_paged_history ~paged ~fresh:[]))
;;

let test_oldest_at_reports_the_cursor () =
  check
    (option (float 0.001))
    "oldest of the held rows"
    (Some 100.)
    (Tui_types.oldest_at [ entry_at 300.; entry_at 100.; entry_at 200. ]);
  check
    (option (float 0.001))
    "nothing to page back from"
    None
    (Tui_types.oldest_at [])
;;

let test_enter_during_a_turn_queues () =
  let n = calls ~module_path:"bin/masc_tui.ml" ~callee:"queue_keeper_message" in
  if n < 1 then
    failf
      "bin/masc_tui.ml must queue a message typed while a turn is running; \
       queue_keeper_message is called %d time(s)"
      n
;;

let test_a_settled_turn_drains_the_queue () =
  let n = calls ~module_path:"bin/masc_tui.ml" ~callee:"drain_queued_message" in
  if n < 1 then
    failf
      "bin/masc_tui.ml must drain the queue when a turn settles; \
       drain_queued_message is called %d time(s)"
      n
;;

(* Two Keepers can stream at once. A single [state.msg_live] slot lets the
   later dispatch replace the earlier transcript, so the earlier turn's next
   delta and tool rows disappear. Both the streaming and settle paths must
   resolve the transcript from the request's own in-flight entry. *)
let test_concurrent_turns_keep_request_owned_transcripts () =
  List.iter
    (fun binding_name ->
      let n =
        Ast_grep.count_calls_in_value_binding
          ~module_path:"bin/masc_tui.ml"
          ~binding_name
          ~callee:"inflight_entry_by_request_id"
      in
      if n < 1 then
        failf
          "%s must resolve the live transcript from the request's in-flight \
           entry; inflight_entry_by_request_id is called %d time(s)"
          binding_name
          n)
    [ "settle_live_turn"; "apply_async_message" ]
;;

let test_live_transcripts_are_kept_per_keeper () =
  let state =
    Tui_types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2.0 ()
  in
  let entry keeper_name started_at =
    let sent_request =
      Keeper_chat.create_request ~keeper_name ~message:("hello " ^ keeper_name) ()
    in
    let live =
      Keeper_chat_transcript.create
        ~keeper_name
        ~request_id:sent_request.request_id
        ~started_at
    in
    ({ Tui_types.sent_request = sent_request; sent_at = started_at; live }
      : Tui_types.inflight)
  in
  let alpha = entry "alpha" 1.0 in
  let beta = entry "beta" 2.0 in
  state.msg_inflight <- [ beta; alpha ];
  check bool "alpha keeps its own live transcript" true
    (match Tui_types.live_for_keeper state "alpha" with
     | Some live -> live == alpha.live
     | None -> false);
  check bool "beta keeps its own live transcript" true
    (match Tui_types.live_for_keeper state "beta" with
     | Some live -> live == beta.live
     | None -> false)
;;

(* The renderer knows the wrapped transcript's real maximum only after it has
   laid the rows out. That clamped value must come back into state; otherwise
   PgUp can leave [msg_scroll] above the maximum and Up/Down appear frozen
   until enough keys have burned through the invisible excess. *)
let test_message_scroll_accepts_the_rendered_clamp () =
  let state =
    Tui_types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2.0 ()
  in
  state.msg_scroll <- 30;
  Tui_types.apply_clamped_scroll state (Tui_types.Message_scroll 7);
  check int "requested scroll is normalized to the drawn row" 7 state.msg_scroll
;;

(* Resources and Approval detail worked the drawable row out and then threw
   it away: the drawing clamped for display while the stored value kept
   climbing, so j past the end cost one k per step to undo. Both now report
   the row they drew, the same way the transcript already does. *)
let test_resource_scroll_accepts_the_rendered_clamp () =
  let state =
    Tui_types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2.0 ()
  in
  state.resource_scroll <- 42;
  Tui_types.apply_clamped_scroll state (Tui_types.Resource_scroll 5);
  check int "requested scroll is normalized to the drawn row" 5
    state.resource_scroll
;;

let test_approval_detail_scroll_accepts_the_rendered_clamp () =
  let state =
    Tui_types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2.0 ()
  in
  state.approval_detail_scroll <- 42;
  Tui_types.apply_clamped_scroll state (Tui_types.Approval_detail_scroll 3);
  check int "requested scroll is normalized to the drawn row" 3
    state.approval_detail_scroll
;;

(* The header names what is unusual, not what is normal.

   Reasoning hidden and tools compact are the quiet defaults: the answer is
   primary, with work one shortcut away. Spelling those modes in every header
   would spend width to describe the ordinary case.

   Every combination is listed rather than described, because the rule is
   about which of eight cases produce which string. *)
let test_the_header_names_only_unusual_modes () =
  let summary ?(origin = Masc_tui_message_layout.Origin_inline) memory_visible
      reasoning tools =
    Tui_types.chat_visibility_summary ~memory_visible ~reasoning ~tools ~origin
  in
  let full = Tui_types.Reasoning_full and folded = Tui_types.Reasoning_folded in
  let hidden = Tui_types.Reasoning_hidden in
  let tools_full = Tui_types.Tools_full and compact = Tui_types.Tools_compact in
  (* The header says nothing for the state the TUI actually starts in, so the
     default has to be read rather than restated here. *)
  let started =
    Tui_types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2.0 ()
  in
  check
    bool
    "the pane starts with the origin in the margin"
    true
    (started.Tui_types.msg_origin_display
     = Masc_tui_message_layout.Origin_inline);
  check string "everything at its default says nothing" ""
    (summary ~origin:started.Tui_types.msg_origin_display true hidden compact);
  (* The inline margin is the default, so going back to the roomier row layout
     is what the header has to name. *)
  check string "the roomier row layout is named" "clock:row"
    (summary ~origin:Masc_tui_message_layout.Origin_row true hidden compact);
  check string "dropping the clock is named" "clock:off"
    (summary ~origin:Masc_tui_message_layout.Origin_bare true hidden compact);
  check string "full reasoning alone" "reasoning:full"
    (summary true full compact);
  check string "folded reasoning alone" "reasoning:folded"
    (summary true folded compact);
  check string "full tools alone" "tools:full"
    (summary true hidden tools_full);
  check string "memory off alone" "memory:off"
    (summary false hidden compact);
  check string "two of them" "reasoning:full tools:full"
    (summary true full tools_full);
  check string "all three, in a fixed order"
    "memory:off reasoning:full tools:full"
    (summary false full tools_full);
  check int "at rest it now costs nothing" 0
    (String.length (summary true hidden compact));
  check int "all three deviations still fit as one compact label" 36
    (String.length (summary false full tools_full))
;;

let test_chat_visibility_defaults_and_cycles () =
  let default =
    Tui_types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2.0 ()
  in
  check string "reasoning starts out of the conversation hierarchy" "hidden"
    (Tui_types.reasoning_visibility_to_string default.msg_reasoning_visibility);
  check string "tool calls start as one activity summary" "compact"
    (Tui_types.tool_visibility_to_string default.msg_tool_visibility);
  let configured =
    Tui_types.create_state
      ~reasoning_visibility:Tui_types.Reasoning_hidden
      ~tool_visibility:Tui_types.Tools_compact
      ~workspace:"test"
      ~port:8935
      ~refresh_interval:2.0
      ()
  in
  check string "configured reasoning default" "hidden"
    (Tui_types.reasoning_visibility_to_string configured.msg_reasoning_visibility);
  check string "configured tool default" "compact"
    (Tui_types.tool_visibility_to_string configured.msg_tool_visibility);
  check (list string) "reasoning cycles through all three states"
    [ "hidden"; "folded"; "full"; "hidden" ]
    (let rec collect count mode =
       if count = 0
       then [ Tui_types.reasoning_visibility_to_string mode ]
       else
         Tui_types.reasoning_visibility_to_string mode
         :: collect (count - 1) (Tui_types.next_reasoning_visibility mode)
     in
     collect 3 Tui_types.Reasoning_hidden);
  check string "tool detail toggles open" "full"
    (Tui_types.tool_visibility_to_string
       (Tui_types.toggle_tool_visibility Tui_types.Tools_compact))
;;

let test_chat_shortcuts_reach_visibility_state () =
  List.iter
    (fun callee ->
      let count =
        Ast_grep.count_calls_in_value_binding
          ~module_path:"bin/masc_tui.ml"
          ~binding_name:"handle_message_key"
          ~callee
      in
      if count < 1 then
        failf "handle_message_key must call %s; observed %d call(s)" callee count)
    [ "next_reasoning_visibility"; "toggle_tool_visibility" ]
;;

(* Cancel (Ctrl-K) and edit (Ctrl-P) both act on the newest waiting line, so
   the take-newest operation has to return exactly the last-pushed pair and
   leave the drain order of everything older untouched. *)
let test_take_newest_returns_last_and_keeps_order () =
  check bool "empty queue has no newest" true
    (Masc_tui_keeper_chat_queue.take_newest
       Masc_tui_keeper_chat_queue.empty
     = None);
  (* [fun q -> match …] in a [|>] chain swallows the rest of the chain into
     the match, so the stages are a plain application instead. *)
  let push_ok queue keeper text =
    let request =
      Masc_tui_keeper_chat_projection.create_request ~attachments:[]
        ~keeper_name:keeper ~message:text ()
    in
    match Masc_tui_keeper_chat_queue.push queue request with
    | Ok (next, _) -> next
    | Error detail -> failf "push failed: %s" detail
  in
  let queue =
    push_ok
      (push_ok
         (push_ok Masc_tui_keeper_chat_queue.empty "a" "first")
         "b" "second")
      "c" "third"
  in
  match Masc_tui_keeper_chat_queue.take_newest queue with
  | None -> failf "take_newest returned None with three waiting"
  | Some (newest, rest) ->
      check string "newest request is the last pushed" "c"
        newest.Masc_tui_keeper_chat_projection.keeper_name;
      check string "newest text is the last pushed" "third"
        newest.Masc_tui_keeper_chat_projection.message;
      check int "drain order of the rest is untouched" 2
        (Masc_tui_keeper_chat_queue.length rest);
      (match
         Masc_tui_keeper_chat_queue.take_first_sendable rest
           ~sendable:(fun _ -> true)
       with
       | Some (oldest, remaining) ->
           check string "oldest still drains first" "a"
             oldest.Masc_tui_keeper_chat_projection.keeper_name;
           check (list string) "and what is left keeps its order" [ "second" ]
             (Masc_tui_keeper_chat_queue.waiting remaining
              |> List.map (fun (r : Masc_tui_keeper_chat_projection.request) ->
                     r.Masc_tui_keeper_chat_projection.message))
       | None -> failf "oldest no longer drains first after take_newest")
;;

(* The queue no longer has rows of its own beneath the conversation: a waiting
   line is drawn in the conversation, in its place in the order, from the
   moment it is typed.

   What still has to hold is that the budget and the pane agree about it.
   Counting rows nothing draws is the same defect as drawing rows nothing
   counts, and the second one shipped: #29818 rewrote the in-flight block and
   took the queue rows out with it, leaving the count behind, so every line
   typed during a turn cost a row of conversation and put nothing in its
   place.

   Asserted as an equality rather than as "both at least once". The contract is
   that the two sides move together; "neither draws nor counts" satisfies it
   exactly as "both do", and requiring a count would pin the old design rather
   than the rule it existed for. *)
let test_the_budget_and_the_pane_agree_about_queue_rows () =
  let counted =
    Ast_grep.count_calls_in_value_binding
      ~module_path:"bin/masc_tui_types.ml"
      ~binding_name:"keeper_message_status_rows"
      ~callee:"Masc_tui_keeper_chat_queue.waiting"
  in
  let drawn =
    Ast_grep.count_calls_in_value_binding
      ~module_path:"bin/masc_tui_render.ml"
      ~binding_name:"render_keeper_message"
      ~callee:"Masc_tui_keeper_chat_queue.waiting"
  in
  if counted <> drawn then
    failf
      "the row budget and the pane disagree about the queue: \
       keeper_message_status_rows walks it %d time(s), render_keeper_message \
       %d time(s)"
      counted drawn
;;

(* A queued line is shown as queued. Drawn like a sent one it would be the same
   silence that made a refused send look like a sent one -- the operator has to
   be able to tell which of their own messages has actually gone. The queue is
   the only place that fact lives, so the pane asks it rather than carrying a
   second copy that can drift. *)
let test_the_pane_marks_what_is_still_waiting () =
  let n =
    Ast_grep.count_calls_in_value_binding
      ~module_path:"bin/masc_tui_render.ml"
      ~binding_name:"render_keeper_message"
      ~callee:"Masc_tui_keeper_chat_queue.holds"
  in
  if n < 1 then
    failf
      "render_keeper_message must ask the queue which rows are still waiting; \
       Masc_tui_keeper_chat_queue.holds is called %d time(s)"
      n
;;

(* When a turn settles, the pane reloads the keeper's transcript from the
   server and drops the rows it is replacing -- every user row for that keeper.
   A queued line is not in what the server sent, because it has not been sent;
   dropping it there takes it off the screen at the exact moment the turn ahead
   of it settles, which is when the operator is watching for it to go. It would
   come back only if and when it was dispatched, and the lines behind it not at
   all. So the reload asks the queue before dropping. *)
let test_a_transcript_reload_keeps_what_is_still_queued () =
  let n =
    Ast_grep.count_calls_in_value_binding
      ~module_path:"bin/masc_tui.ml"
      ~binding_name:"forget_session_rows_the_transcript_holds"
      ~callee:"Chat_queue.holds"
  in
  if n < 1 then
    failf
      "the transcript reload must keep the rows the queue still holds; \
       Chat_queue.holds is called %d time(s) in \
       forget_session_rows_the_transcript_holds"
      n
;;

(* Staged attachments belong to the line they were staged for. They used to be
   taken at dispatch, so an image attached while a line waited went out with
   whichever line happened to go next -- and the operator had no way to see
   that it had. Both branches of the send take them now: the one that sends
   immediately and the one that queues. *)
let test_a_queued_line_takes_its_attachments_when_it_is_typed () =
  let n =
    Ast_grep.count_calls_in_value_binding
      ~module_path:"bin/masc_tui.ml"
      ~binding_name:"start_keeper_message"
      ~callee:"take_pending_attachments"
  in
  if n < 2 then
    failf
      "both the sending and the queueing branch must take the staged \
       attachments where the line is written; take_pending_attachments is \
       called %d time(s) in start_keeper_message"
      n
;;

(* The operator pressed Enter, so the line belongs in the conversation now --
   not when the turn ahead of it settles. Keyed on the request id through the
   same call dispatch makes, so the row a queued line already has is the row it
   keeps when it finally goes out; there is no second copy to reconcile. *)
let test_queueing_puts_the_line_in_the_conversation () =
  let n =
    Ast_grep.count_calls_in_value_binding
      ~module_path:"bin/masc_tui.ml"
      ~binding_name:"queue_keeper_message"
      ~callee:"append_user_history_once"
  in
  if n < 1 then
    failf
      "queue_keeper_message must put the queued line in the conversation; \
       append_user_history_once is called %d time(s)"
      n
;;

(* And taking it back takes the row with it. A cancelled line left in the
   conversation reads as sent -- the exact confusion the row was added to
   end. *)
let test_cancel_and_edit_take_the_row_with_them () =
  let n =
    Ast_grep.count_calls_in_value_binding
      ~module_path:"bin/masc_tui.ml"
      ~binding_name:"handle_message_key"
      ~callee:"forget_queued_history"
  in
  if n < 2 then
    failf
      "cancel (Ctrl-K) and edit (Ctrl-P) must each drop the queued line's row; \
       forget_queued_history is called %d time(s) in handle_message_key"
      n
;;

(* Every box row the chat pane draws belongs to the pane, not to the frame
   around it. On a terminal at or above the split threshold the roster takes
   the left columns and [chat_buf] is a separate buffer, so a row written to
   the outer [buf] lands above the tab strip and pushes the whole screen down
   by one row. That is what the queued lines did: #29818 rewrote the in-flight
   block, and when the queue rows came back they came back on [buf]. The
   operator saw the queue stack up over the tabs and the chat slide off the
   bottom. Nothing failed — the rows were drawn, just into the wrong pane. *)
let test_the_pane_draws_every_row_into_its_own_buffer () =
  let source =
    let path = Ast_grep.resolve_module_path "bin/masc_tui_render.ml" in
    let channel = open_in_bin path in
    let length = in_channel_length channel in
    let text = really_input_string channel length in
    close_in channel;
    text
  in
  let lines = String.split_on_char '\n' source in
  let in_renderer = ref false in
  let offenders = ref [] in
  List.iteri
    (fun index line ->
       if
         String.length line > 26
         && String.sub line 0 26 = "let render_keeper_message "
       then in_renderer := true
       else if
         String.length line > 4
         && String.sub line 0 4 = "let "
         && !in_renderer
       then in_renderer := false;
       if !in_renderer then
         List.iter
           (fun call ->
              let needle = call ^ " buf " in
              let rec search from =
                match String.index_from_opt line from needle.[0] with
                | None -> ()
                | Some at ->
                  if
                    at + String.length needle <= String.length line
                    && String.sub line at (String.length needle) = needle
                  then offenders := (index + 1, String.trim line) :: !offenders
                  else search (at + 1)
              in
              search 0)
           [ "box_top"; "box_line"; "box_line_styled"; "box_divider"; "box_empty" ])
    lines;
  match !offenders with
  | [] -> ()
  | rows ->
    failf
      "render_keeper_message must draw every box row into [chat_buf]; these \
       go to the outer frame buffer and shift the screen when the roster \
       pane is shown: %s"
      (String.concat "; "
         (List.map (fun (n, text) -> Printf.sprintf "line %d: %s" n text) rows))
;;

(* A line waiting for the next turn is the newest thing the operator typed, and
   the arrows have to hand it back. They walk [msg_history], which once was
   written only on dispatch -- so the walk stepped straight over a queued line
   and it could be neither read back nor pulled into the composer.

   It is written when the line is typed now, so one walk covers both and the
   queue is not walked alongside it. That is what this pins: walking both would
   put the newest line in the arrows twice. The other half -- that a queued
   line reaches the history at all -- is
   [test_queueing_puts_the_line_in_the_conversation]. *)
let test_the_arrow_walk_does_not_repeat_the_queue () =
  let n =
    Ast_grep.count_calls_in_value_binding
      ~module_path:"bin/masc_tui.ml"
      ~binding_name:"own_typed_messages"
      ~callee:"Chat_queue.waiting"
  in
  if n <> 0 then
    failf
      "own_typed_messages must not walk the queue as well: a queued line is \
       already in the history it walks, so concatenating the queue shows the \
       newest line twice; Chat_queue.waiting is called %d time(s)"
      n
;;

(* The footer says what Enter does, and it has to say what Enter actually
   does. It used to work that out from [msg_inflight_kind] while the send path
   read the durable fences first, so a request being reconciled or cleaned up
   drew "queued 1" and [Enter:blocked] on the same screen. Both now read
   [send_disposition], which is where the order lives. *)
let test_both_readers_share_one_disposition () =
  List.iter
    (fun (module_path, what) ->
      let n = calls ~module_path ~callee:"send_disposition" in
      if n < 1 then
        failf
          "%s must decide %s from send_disposition, not from its own reading            of the state; it is called %d time(s)"
          module_path what n)
    [ ("bin/masc_tui.ml", "what Enter does")
    ; ("bin/masc_tui_render.ml", "what the footer says Enter does")
    ]
;;

(* The Keeper Calls table says a call ran and what it was called with. What
   it answered is the question a failed call leaves open, and the digest is
   computed where it can be tested; this pins that the table asks for it. *)
let test_the_calls_table_says_what_came_back () =
  let n =
    calls ~module_path:"bin/masc_tui_render.ml"
      ~callee:"Masc.Keeper_chat_tool_trail.tool_result_digest"
  in
  if n < 1 then
    failf
      "bin/masc_tui_render.ml must draw what a call answered; \
       tool_result_digest is called %d time(s)"
      n
;;

(* The rows that say a request is being sent have to say how long for. A turn
   running minutes is ordinary, and without an age those rows read the same at
   three seconds and at thirteen minutes -- which is the difference between
   slow and stuck. The age is computed where it can be tested; this pins that
   the pane actually asks for it. *)
let test_the_sending_rows_show_an_age () =
  let n =
    calls ~module_path:"bin/masc_tui_render.ml"
      ~callee:"Message_layout.age_text"
  in
  if n < 1 then
    failf
      "bin/masc_tui_render.ml must age the rows it draws for a request in \
       flight; Message_layout.age_text is called %d time(s)"
      n
;;

let () =
  run
    "tui_chat_queue_wiring"
    [ ( "wiring"
      , [ test_case "Enter during a turn queues" `Quick
            test_enter_during_a_turn_queues
        ; test_case "a settled turn drains the queue" `Quick
            test_a_settled_turn_drains_the_queue
        ; test_case "concurrent turns keep request-owned transcripts" `Quick
            test_concurrent_turns_keep_request_owned_transcripts
        ; test_case "live transcripts are kept per Keeper" `Quick
            test_live_transcripts_are_kept_per_keeper
        ; test_case "message scroll accepts the rendered clamp" `Quick
            test_message_scroll_accepts_the_rendered_clamp
        ; test_case "resource scroll accepts the rendered clamp" `Quick
            test_resource_scroll_accepts_the_rendered_clamp
        ; test_case "approval detail scroll accepts the rendered clamp" `Quick
            test_approval_detail_scroll_accepts_the_rendered_clamp
        ; test_case "chat visibility defaults and cycles" `Quick
            test_chat_visibility_defaults_and_cycles
        ; test_case "the header names only unusual modes" `Quick
            test_the_header_names_only_unusual_modes
        ; test_case "chat shortcuts reach visibility state" `Quick
            test_chat_shortcuts_reach_visibility_state
        ; test_case "the budget and the pane agree about queue rows" `Quick
            test_the_budget_and_the_pane_agree_about_queue_rows
        ; test_case "the pane marks what is still waiting" `Quick
            test_the_pane_marks_what_is_still_waiting
        ; test_case "queueing puts the line in the conversation" `Quick
            test_queueing_puts_the_line_in_the_conversation
        ; test_case "a queued line takes its attachments when it is typed" `Quick
            test_a_queued_line_takes_its_attachments_when_it_is_typed
        ; test_case "a transcript reload keeps what is still queued" `Quick
            test_a_transcript_reload_keeps_what_is_still_queued
        ; test_case "cancel and edit take the row with them" `Quick
            test_cancel_and_edit_take_the_row_with_them
        ; test_case "the pane draws every row into its own buffer" `Quick
            test_the_pane_draws_every_row_into_its_own_buffer
        ; test_case "the arrow walk does not repeat the queue" `Quick
            test_the_arrow_walk_does_not_repeat_the_queue
        ; test_case "both readers share one disposition" `Quick
            test_both_readers_share_one_disposition
        ; test_case "the calls table says what came back" `Quick
            test_the_calls_table_says_what_came_back
        ; test_case "the sending rows show an age" `Quick
            test_the_sending_rows_show_an_age
        ; test_case "every way back asks for what is behind it" `Quick
            test_every_way_back_asks_for_what_is_behind_it
        ; test_case "a refresh keeps what was paged back to" `Quick
            test_a_refresh_keeps_what_was_paged_back_to
        ; test_case "a refresh does not double the overlap" `Quick
            test_a_refresh_does_not_double_the_overlap
        ; test_case "an empty refresh keeps the transcript" `Quick
            test_an_empty_refresh_keeps_the_transcript
        ; test_case "oldest_at reports the cursor" `Quick
            test_oldest_at_reports_the_cursor
        ] )
    ; ( "queue"
      , [ test_case "take_newest returns the last and keeps order" `Quick
            test_take_newest_returns_last_and_keeps_order ] )
    ]
;;
