(* Queue and live progress are independent sources. Admission says whether
   this request is queued; a Keeper row alone cannot establish that fact. *)
open Alcotest
module Tui = Masc_tui_types
module Decode = Tui.Tui_decode
module Live = Masc_tui_keeper_chat_live
module Chat = Masc_tui_keeper_chat_projection
module Queue = Masc_tui_keeper_chat_queue

let state () =
  let state = Tui.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2. () in
  state.msg_target_keeper_name <- Some "alpha";
  state

let running ?(keeper_name = "alpha") lane : Decode.keeper_turn_row =
  { ktr_chat_control_token = None; ktr_keeper_name = keeper_name
  ; ktr_state = Keeper_turn_running { lane; started_at_unix = 1.; interrupt_token = "fixture-token"; preview = None }
  }

let live ?(keeper_name = "alpha") ?(request_id = "request-1") state admission =
  let live = Tui.turn_log_create ~keeper_name ~request_id ~started_at:2. in
  Option.iter (fun admission ->
    Tui.turn_log_add ~now:3. live ~seq:None
      (Live.Accepted { admission; queue_length = 3; interactive = None })) admission;
  state.Tui.msg_live <- Some live;
  state.msg_inflight <- [{ Tui.sent_request = { Chat.request_id; keeper_name; message = "request"; attachments = []; references = [] };
    submitted_at = 2.; sent_at = 2.; control_generation = 0; origin = Tui.Direct_submission; phase = Tui.Turn_streaming; log = live }];
  live

let texts rows = List.map Masc_tui_answering.chat_activity_row_text rows

(* The admission is the live progress row's to say
   ([Masc_tui_keeper_chat_transcript.phase_text], pinned in
   test_tui_keeper_chat_transcript): "sent; not accepted yet", "queued · 3
   messages in the keeper's queue", "accepted; the run is starting". The
   band said each again in a sentence of its own under it. For every
   admission, the band now names only what the progress row does not: a
   turn this pane did not open, which the pane is waiting behind. *)
let test_the_band_does_not_repeat_the_admission () =
  List.iter (fun admission ->
    let state = state () in
    ignore (live state admission);
    check (list string) "no turn observed: nothing under the progress row" []
      (texts (Tui.keeper_message_activity_rows state));
    state.keeper_turns <- [running Turn_lane_autonomous];
    match Tui.keeper_message_activity_rows state with
    | [ row ] ->
      check bool "the one row is the turn the pane waits behind" true
        (String.length row.Masc_tui_answering.lead > 0
         && Astring.String.is_infix ~affix:"autonomous" row.lead);
      check bool "and it does not restate the admission" false
        (List.exists (fun needle ->
           Astring.String.is_infix ~affix:needle (Masc_tui_answering.chat_activity_row_text row))
           [ "Your message"; "Your request"; "queued at the server" ])
    | rows -> fail (String.concat " | " (texts rows)))
    [ None; Some Live.Running; Some Live.Settled; Some Live.Queued ]

(* The band never names a blocker it did not observe: another keeper's turn,
   this pane's own chat operation (the live row draws it), a failing poll, an
   idle or unreadable keeper -- none puts an observed-turn row under a queued
   request of this pane. *)
let test_queue_does_not_invent_a_blocking_turn () =
  List.iter (fun (rows, error) ->
    let state = state () in
    state.keeper_turns <- rows;
    state.keeper_turns_error <- error;
    ignore (live state (Some Live.Queued));
    check bool "no observed-turn row names a blocker" false
      (List.exists (fun text -> Astring.String.is_infix ~affix:"autonomous" text)
         (texts (Tui.keeper_message_activity_rows state))))
    [ [], None
    ; [running ~keeper_name:"beta" Turn_lane_autonomous], None
    ; [{ Decode.ktr_chat_control_token = None; ktr_keeper_name = "alpha"; ktr_state = Keeper_turn_idle }], None
    ; [{ Decode.ktr_chat_control_token = None; ktr_keeper_name = "alpha"; ktr_state = Keeper_turn_unavailable "offline" }], None
    ];
  let state = state () in
  state.keeper_turns <- [running Turn_lane_maintenance];
  ignore (live state (Some Live.Queued));
  check bool "same Keeper maintenance is observed background work" true
    (List.exists (fun text -> Astring.String.is_infix ~affix:"maintenance" text)
       (texts (Tui.keeper_message_activity_rows state)))

let test_started_and_finished_requests_stop_waiting () =
  let state = state () in
  let log = live state (Some Live.Queued) in
  state.keeper_turns <- [running Turn_lane_chat_operation];
  Tui.turn_log_add ~now:4. log ~seq:(Some 1) Live.Run_started;
  check (list string) "a started run is the live progress row's, not the band's" []
    (texts (Tui.keeper_message_activity_rows state));
  state.keeper_turns <- [];
  Tui.turn_log_add ~now:5. log ~seq:(Some 2) Live.Run_finished;
  check (list string) "settled run is not queued" []
    (texts (Tui.keeper_message_activity_rows state));
  ignore (live ~keeper_name:"beta" state (Some Live.Queued));
  check (list string) "another Keeper's pending submission stays out" []
    (texts (Tui.keeper_message_activity_rows state))

let test_local_queue_is_not_server_admission () =
  let state = state () in
  let add keeper_name request_id =
    let request : Chat.request =
      { request_id; keeper_name; message = "hello"; attachments = []; references = [] } in
    match Queue.push state.msg_queued ~submitted_at:1. request with
    | Ok (queue, _) -> state.msg_queued <- queue
    | Error error -> fail error in
  add "alpha" "local-alpha";
  add "beta" "local-beta";
  check (list string) "only target's unsent messages are counted"
    ["Queue (1 waiting · auto-next:on) NEXT: \"hello\" · Ctrl-T:queue"]
    (texts (Tui.keeper_message_activity_rows state));
  state.msg_target_keeper_name <- None;
  check (list string) "no target has no attributed activity" []
    (texts (Tui.keeper_message_activity_rows state))

let test_working_request_survives_newer_queued_view () =
  let state = state () in
  state.keeper_turns <- [running Turn_lane_autonomous];
  let working = live state (Some Live.Running) in
  Tui.turn_log_add ~now:4. working ~seq:(Some 1) Live.Run_started;
  Tui.turn_log_add ~now:4. working ~seq:(Some 2)
    (Live.Batch_bound {operation_id = "request-1"; execution_id = "shared-execution"});
  let active = List.hd state.msg_inflight in
  ignore (live ~request_id:"queued-2" state (Some Live.Queued));
  state.msg_inflight <- state.msg_inflight @ [active];
  (* The live row draws the newer queued request; the working one under it
     is named by the band, since nothing else on screen names it. *)
  check (list string) "the working request the live row is not drawing stays visible"
    ["Current direct conversation · shared-execution · in progress"]
    (texts (Tui.keeper_message_activity_rows state));
  check (list string) "stale autonomous interrupt rows are suppressed" []
    (Tui.keeper_observed_interrupt_rows state)

(* Esc and its hint read one fact. While the turns poll is failing the stale
   running row stays on screen, but Esc has no target, so no row may offer
   the stop. *)
let test_esc_hint_follows_the_observed_turn () =
  let state = state () in
  state.keeper_turns <- [running Turn_lane_chat_operation];
  check (option (pair (float 0.001) string)) "a running row is the target"
    (Some (1., "fixture-token")) (Tui.keeper_observed_turn state "alpha");
  check bool "the row naming the turn offers the stop Esc will send" true
    (List.exists (fun text -> Astring.String.is_infix ~affix:"Esc stops it" text)
       (texts (Tui.keeper_message_activity_rows state)));
  check (list string) "and no row of its own says it again" []
    (Tui.keeper_observed_interrupt_rows state);
  state.keeper_turns_error <- Some "poll failed";
  check (option (pair (float 0.001) string)) "a failing poll leaves Esc without a target"
    None (Tui.keeper_observed_turn state "alpha");
  check bool "no row offers a stop Esc would not send" false
    (List.exists (fun text -> Astring.String.is_infix ~affix:"Esc" text)
       (texts (Tui.keeper_message_activity_rows state)))

let () =
  run "TUI chat activity"
    [ "request and lane states",
      [ test_case "Working request stays visible behind newer queued view" `Quick test_working_request_survives_newer_queued_view
      ; test_case "the band does not repeat the admission" `Quick
          test_the_band_does_not_repeat_the_admission
      ; test_case "queue does not invent its blocker" `Quick
          test_queue_does_not_invent_a_blocking_turn
      ; test_case "started, finished, and other Keeper requests" `Quick
          test_started_and_finished_requests_stop_waiting
      ; test_case "local queue is distinct from server admission" `Quick
          test_local_queue_is_not_server_admission
      ; test_case "Esc hint follows the observed turn" `Quick
          test_esc_hint_follows_the_observed_turn
      ] ]

