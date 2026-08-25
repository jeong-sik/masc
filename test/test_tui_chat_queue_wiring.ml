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
      Keeper_chat.create_request ~keeper_name ~message:("hello " ^ keeper_name)
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

let test_chat_visibility_defaults_and_cycles () =
  let default =
    Tui_types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2.0 ()
  in
  check string "reasoning compatibility default" "full"
    (Tui_types.reasoning_visibility_to_string default.msg_reasoning_visibility);
  check string "tool compatibility default" "full"
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
    match Masc_tui_keeper_chat_queue.push queue ~keeper_name:keeper text with
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
  | Some ((keeper, text), rest) ->
      check string "newest pair is the last pushed" "c" keeper;
      check string "newest text is the last pushed" "third" text;
      check int "drain order of the rest is untouched" 2
        (Masc_tui_keeper_chat_queue.length rest);
      (match
         Masc_tui_keeper_chat_queue.take_first_sendable rest
           ~sendable:(fun _ -> true)
       with
       | Some (("a", "first"), remaining) ->
           check bool "oldest still drains first" true
             (Masc_tui_keeper_chat_queue.waiting remaining
              = [ ("b", "second") ])
       | _ -> failf "oldest no longer drains first after take_newest")
;;

(* The pane draws one row per waiting line. The row budget that sizes the
   history has to count those rows: the frame presenter drops whatever runs
   past the last terminal row, so a pane that came out taller by the number of
   waiting lines loses its bottom and the prompt slides out from under the
   caret. That was the bug -- the queue rows were drawn and never counted. *)
let test_the_row_budget_counts_the_queue () =
  let n =
    Ast_grep.count_calls_in_value_binding
      ~module_path:"bin/masc_tui_types.ml"
      ~binding_name:"keeper_message_status_rows"
      ~callee:"Masc_tui_keeper_chat_queue.waiting"
  in
  if n < 1 then
    failf
      "keeper_message_status_rows must count the rows the pane draws for \
       waiting lines; Masc_tui_keeper_chat_queue.waiting is called %d time(s)"
      n
;;

(* The other half of the budget check above. Counting rows nothing draws is
   the same defect as drawing rows nothing counts, and it is the one that
   actually shipped: #29818 rewrote the in-flight block and took the queue
   rows out with it, leaving the count. Both halves are asserted so neither
   side can move alone. *)
let test_the_pane_draws_the_queue_it_counts () =
  let n =
    Ast_grep.count_calls_in_value_binding
      ~module_path:"bin/masc_tui_render.ml"
      ~binding_name:"render_keeper_message"
      ~callee:"Masc_tui_keeper_chat_queue.waiting"
  in
  if n < 1 then
    failf
      "render_keeper_message must draw the waiting lines the row budget \
       reserves for it; Masc_tui_keeper_chat_queue.waiting is called %d \
       time(s)"
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

(* A line waiting for the next turn is the newest thing the operator typed.
   The arrows walked [msg_history], which is only written on dispatch, so the
   walk stepped straight over it: the queued line could be neither read back
   nor pulled into the composer. *)
let test_the_arrow_walk_includes_the_queue () =
  let n =
    Ast_grep.count_calls_in_value_binding
      ~module_path:"bin/masc_tui.ml"
      ~binding_name:"own_typed_messages"
      ~callee:"Chat_queue.waiting"
  in
  if n < 1 then
    failf
      "own_typed_messages must offer the waiting lines to the arrows; \
       Chat_queue.waiting is called %d time(s)"
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
        ; test_case "chat visibility defaults and cycles" `Quick
            test_chat_visibility_defaults_and_cycles
        ; test_case "chat shortcuts reach visibility state" `Quick
            test_chat_shortcuts_reach_visibility_state
        ; test_case "the row budget counts the queue" `Quick
            test_the_row_budget_counts_the_queue
        ; test_case "the pane draws the queue it counts" `Quick
            test_the_pane_draws_the_queue_it_counts
        ; test_case "the pane draws every row into its own buffer" `Quick
            test_the_pane_draws_every_row_into_its_own_buffer
        ; test_case "the arrow walk includes the queue" `Quick
            test_the_arrow_walk_includes_the_queue
        ; test_case "both readers share one disposition" `Quick
            test_both_readers_share_one_disposition
        ; test_case "the calls table says what came back" `Quick
            test_the_calls_table_says_what_came_back
        ; test_case "the sending rows show an age" `Quick
            test_the_sending_rows_show_an_age
        ] )
    ; ( "queue"
      , [ test_case "take_newest returns the last and keeps order" `Quick
            test_take_newest_returns_last_and_keeps_order ] )
    ]
;;
