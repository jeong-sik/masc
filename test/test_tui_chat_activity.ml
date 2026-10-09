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
  state.msg_tool_visibility <- Tui.Tools_full;
  state

let running ?(keeper_name = "alpha") lane : Decode.keeper_turn_row =
  { ktr_chat_control_token = None; ktr_keeper_name = keeper_name
  ; ktr_state = Keeper_turn_running { lane; started_at_unix = 1.; interrupt_token = "fixture-token"; turn_ref = None; preview = None }
  }

let live ?(keeper_name = "alpha") ?(request_id = "request-1") state admission =
  let live = Tui.turn_log_create ~keeper_name ~request_id ~started_at:2. in
  Option.iter (fun admission ->
    Tui.turn_log_add ~now:3. live ~seq:None
      (Live.Accepted { admission; queue_length = 3; interactive = None })) admission;
  state.Tui.msg_live <- Some live;
  state.msg_inflight <- [{ Tui.sent_request = { Chat.request_id; keeper_name; message = "request"; attachments = []; references = [] };
    submitted_at = 2.; sent_at = 2.; control_generation = 0; phase = Tui.Turn_streaming; log = live }];
  live

let texts rows = List.map Masc_tui_answering.chat_activity_row_text rows

(* An in-flight entry with no events, so its execution id falls back to its
   request id ([Keeper_chat_transcript.execution_id]) and two of these are
   told apart by the id they were created with. *)
let inflight ?(keeper_name = "alpha") ~request_id ~at () =
  let log = Tui.turn_log_create ~keeper_name ~request_id ~started_at:at in
  { Tui.sent_request =
      { Chat.request_id; keeper_name; message = "request"; attachments = []
      ; references = [] }
  ; submitted_at = at
  ; sent_at = at
  ; control_generation = 0
  ; phase = Tui.Turn_streaming
  ; log
  }

let test_local_queue_is_not_server_admission () =
  let state = state () in
  check bool "separate Enter sends stay separate by default" false state.coalesce_queued_input;
  check bool "new sends do not jump the queue by default" false state.user_input_priority_next;
  let add keeper_name request_id =
    let request : Chat.request =
      { request_id; keeper_name; message = "hello"; attachments = []; references = [] } in
    match Queue.push state.msg_queued ~submitted_at:1. request with
    | Ok (queue, _) -> state.msg_queued <- queue
    | Error error -> fail error in
  add "alpha" "local-alpha";
  add "beta" "local-beta";
  check (list string) "only target's unsent messages are counted"
    ["Queue (1 pending) · auto-next:off · Ctrl-T:queue"; "Local NEXT: \"hello\""]
    (texts (Tui.keeper_message_activity_rows state));
  state.msg_target_keeper_name <- None;
  check (list string) "no target has no attributed activity" []
    (texts (Tui.keeper_message_activity_rows state))

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

(* #37741. The pane skips the in-flight row for the request the live
   transcript is already drawing -- one age and one request id, not three --
   and the budget counted it anyway, so with a single message in flight the
   status area reserved a row nobody drew.
 *)
let test_only_the_uncovered_in_flight_rows_are_drawn () =
  let state = state () in
  ignore (live state (Some Live.Running));
  check int "the request the transcript draws gets no in-flight row" 0
    (List.length (Tui.keeper_message_inflight_drawn state));
  state.msg_inflight
    <- state.msg_inflight @ [ inflight ~request_id:"request-2" ~at:3. () ];
  check int "a second message to the same keeper keeps its row" 1
    (List.length (Tui.keeper_message_inflight_drawn state));
  state.msg_inflight
    <- state.msg_inflight
       @ [ inflight ~keeper_name:"beta" ~request_id:"request-3" ~at:4. () ];
  check int "another keeper's request keeps its row too" 2
    (List.length (Tui.keeper_message_inflight_drawn state))

(* Without a live turn on this pane nothing is covered, so every entry draws.
   Reading [msg_live] alone would be wrong here: a live turn belonging to
   another keeper draws nothing on this screen and must hide nothing. *)
let test_a_live_turn_elsewhere_covers_nothing_here () =
  let state = state () in
  state.msg_inflight <- [ inflight ~request_id:"request-1" ~at:2. () ];
  check int "no live turn: the entry draws" 1
    (List.length (Tui.keeper_message_inflight_drawn state));
  state.msg_live
    <- Some
         (Tui.turn_log_create ~keeper_name:"beta" ~request_id:"request-1"
            ~started_at:2.);
  check int "a live turn on another keeper hides nothing here" 1
    (List.length (Tui.keeper_message_inflight_drawn state))

let test_one_status_row_per_server_batch () =
  let state = state () in
  ignore (live ~request_id:"queued-after-batch" state (Some Live.Queued));
  let member request_id at =
    let entry = inflight ~request_id ~at () in
    Tui.turn_log_add ~now:at entry.log ~seq:None
      (Live.Batch_bound { operation_id = request_id;
                          execution_id = "shared-execution" });
    entry
  in
  let first = member "request-1" 2. in
  let second = member "request-2" 3. in
  let third = { (member "request-3" 4.) with phase = Tui.Turn_reconciling } in
  state.msg_inflight <- state.msg_inflight @ [first; second; third];
  match Tui.keeper_message_inflight_drawn state with
  | [group] ->
    check int "one visible row for one execution" 3 group.count;
    check int "reconciliation is not hidden in the batch" 1
      group.reconciling_count;
    check string "the row names the execution" "shared-execution"
      (Tui.turn_log_execution_id group.representative.log);
    check (float 0.001) "the age begins with the oldest submission" 2.
      group.representative.sent_at
  | groups -> failf "expected one batch row, got %d" (List.length groups)

let test_compact_status_keeps_delivery_and_priority_truth () =
  let state = state () in
  state.msg_tool_visibility <- Tui.Tools_compact;
  let first = inflight ~request_id:"first-private-id" ~at:2. () in
  let second = inflight ~request_id:"second-private-id" ~at:3. () in
  List.iter (fun entry -> Tui.turn_log_add ~now:4. entry.Tui.log ~seq:None
      (Live.Accepted {admission=Live.Queued; queue_length=99; interactive=None})) [first; second];
  state.msg_inflight <- [second; first];
  state.msg_live <- Some second.log;
  state.keeper_turns <- [running Turn_lane_autonomous];
  let rows () = List.map (fun row -> row.Masc_tui_answering.lead ^ row.rest)
      (Tui.keeper_message_activity_rows state) in
  check (list string) "one quiet status preserves exact current queue count"
    ["기존 작업 처리 중 · 내 메시지 2건 대기 · 처리 대기"] (rows ());
  state.keeper_run_next_inflight <- [second.sent_request];
  state.keeper_run_next_receipts <- [first.sent_request, Ok "confirmed first"];
  check (list string) "in-flight priority cannot claim confirmation"
    ["기존 작업 처리 중 · 내 메시지 2건 대기 · 다음 순서 확인 중"] (rows ());
  state.keeper_run_next_inflight <- [];
  check (list string) "one receipt does not confirm both inputs"
    ["기존 작업 처리 중 · 내 메시지 2건 대기 · 일부 메시지 다음 순서로 전달 대기"] (rows ());
  state.keeper_run_next_receipts <- [first.sent_request, Ok "first"; second.sent_request, Ok "second"];
  check (list string) "both exact receipts confirm priority"
    ["기존 작업 처리 중 · 내 메시지 2건 대기 · 다음 순서로 전달 대기"] (rows ());
  state.keeper_run_next_receipts <- [second.sent_request, Error "offline"];
  check bool "actual refusal retains attention" true (Tui.keeper_message_activity_needs_attention state);
  check (list string) "failure does not claim priority"
    ["다음 순서 확인 불가 · 기존 작업 처리 중 · 내 메시지 2건 대기"] (rows ());
  let foreign = inflight ~keeper_name:"beta" ~request_id:"foreign-private-id" ~at:1. () in
  state.msg_inflight <- foreign :: state.msg_inflight;
  (match Tui.keeper_message_inflight_drawn state with
   | [group] -> check string "foreign stop target survives folding" "beta" group.representative.sent_request.keeper_name
   | groups -> failf "expected foreign-only row, got %d" (List.length groups));
  state.msg_tool_visibility <- Tui.Tools_full;
  check bool "diagnostics keep exact private ID" true
    (List.exists (fun text -> Astring.String.is_infix ~affix:"second-private-id" text) (rows ()))

let test_priority_control_receipt_ordering () =
  let setup () =
    let state = state () in
    let entry = inflight ~request_id:"priority-request" ~at:2. () in
    state.msg_inflight <- [entry];
    state.keeper_run_next_inflight <- [entry.sent_request];
    state, entry.sent_request in
  List.iter (fun received_first ->
    List.iter (fun outcome ->
      let state, request = setup () in
      let generation = Tui.begin_keeper_chat_control state "alpha" in
      check int "active callback still serializes subsequent priority" 1
        (List.length state.keeper_run_next_inflight);
      if received_first then ignore (Tui.settle_keeper_run_next state request (Ok "accepted"));
      (* The transport token acknowledgement is not the final control result. *)
      ignore (Tui.finish_keeper_chat_control state "alpha" ~generation);
      check bool "priority evidence is provisional until semantic result" true
        (Tui.keeper_run_next_receipt_provisional state request);
      Tui.settle_keeper_priority_control state "alpha" ~generation ~outcome;
      if not received_first then ignore (Tui.settle_keeper_run_next state request (Ok "accepted"));
      check int "callback tracking settles exactly once" 0
        (List.length state.keeper_run_next_inflight);
      check int "failure restores evidence, successful supersession retires it"
        (match outcome with Tui.Priority_unconfirmed -> 1 | Tui.Priority_superseded -> 0)
        (List.length state.keeper_run_next_receipts))
      [Tui.Priority_unconfirmed; Tui.Priority_superseded]) [false; true];
  (* Every confirmed control applies its own cohort, independent of which
     overlapping control or run-next callback returns first. *)
  List.iter (fun received_first ->
    List.iter (fun older_first ->
      List.iter (fun older_succeeds ->
        let state, request = setup () in
        let first = Tui.begin_keeper_chat_control state "alpha" in
        let second = Tui.begin_keeper_chat_control state "alpha" in
        let successful = if older_succeeds then first else second in
        let unsuccessful = if older_succeeds then second else first in
        if received_first then ignore (Tui.settle_keeper_run_next state request (Ok "accepted"));
        let settle generation = Tui.settle_keeper_priority_control state "alpha" ~generation
          ~outcome:(if generation = successful then Tui.Priority_superseded else Tui.Priority_unconfirmed) in
        settle (if older_first then first else second);
        check int "one callback leaves the other control outstanding" 1
          (List.length state.keeper_priority_controls);
        check bool "the unsettled control keeps its cohort provisional" true
          (Tui.keeper_run_next_receipt_provisional state request);
        (* This assertion also covers a second control that never answers. *)
        if (if older_first then first else second) = successful then
          check int "success already removes acknowledged priority despite hanging control" 0
            (List.length state.keeper_run_next_receipts);
        settle (if older_first then second else first);
        if not received_first then ignore (Tui.settle_keeper_run_next state request (Ok "accepted"));
        check int "failure cannot restore evidence superseded by another control" 0
          (List.length state.keeper_run_next_receipts);
        check int "each settled generation leaves tracking exactly once" 0
          (List.length state.keeper_priority_controls);
        settle unsuccessful;
        check int "duplicate semantic callback cannot recreate evidence" 0
          (List.length state.keeper_run_next_receipts)) [false; true]) [false; true]) [false; true];
  let state, request = setup () in
  let alpha = Tui.begin_keeper_chat_control state "alpha" in
  let beta = Tui.begin_keeper_chat_control state "beta" in
  Tui.settle_keeper_priority_control state "beta" ~generation:beta ~outcome:Tui.Priority_superseded;
  check bool "another Keeper's success cannot settle alpha's cohort" true
    (Tui.keeper_run_next_receipt_provisional state request);
  Tui.settle_keeper_priority_control state "alpha" ~generation:alpha ~outcome:Tui.Priority_unconfirmed;
  ignore (Tui.settle_keeper_run_next state request (Ok "accepted"));
  check int "alpha failure preserves its received priority" 1
    (List.length state.keeper_run_next_receipts)

let test_compact_progress_follows_working_execution () =
  let state = state () in
  state.msg_tool_visibility <- Tui.Tools_compact;
  let active = inflight ~request_id:"active-execution" ~at:1. () in
  Tui.turn_log_add ~now:2. active.log ~seq:(Some 0) Live.Run_started;
  Tui.turn_log_add ~now:3. active.log ~seq:(Some 1)
    (Live.Thinking "Consider the observed state");
  let pending = inflight ~request_id:"new-pending-input" ~at:4. () in
  Tui.turn_log_add ~now:4. pending.log ~seq:(Some 0)
    (Live.Accepted {admission=Live.Queued; queue_length=1; interactive=None});
  state.msg_inflight <- [pending; active];
  state.msg_live <- Some pending.log;
  let progress ~now =
    match Tui.keeper_message_status_log state with
    | None -> fail "working execution disappeared behind pending input"
    | Some source ->
        check string "status belongs to the execution producing events"
          "active-execution" (Tui.turn_log_execution_id source);
        Tui.keeper_message_visible_status_rows state source.tl_transcript ~now
        |> List.filter_map (fun (kind, text) ->
            match kind with
            | Masc_tui_keeper_chat_transcript.Progress -> Some text
            | Answer_needed | Attention | Approval _ -> None)
        |> String.concat "\n"
  in
  List.iter (fun folded ->
    state.msg_turn_folded <- folded;
    check bool "reasoning remains visible in compact progress" true
      (Astring.String.is_infix ~affix:"reasoning" (progress ~now:3.5))) [false; true];
  let occurrence : Live.tool_occurrence =
    {stream_scope=0; block_index=1; provider_message_id=None;
     tool_call_id=Some "observed-tool"} in
  Tui.turn_log_add ~now:5. active.log ~seq:(Some 2)
    (Live.Tool_started {occurrence; tool_name="Inspect_state"});
  check bool "the running tool is named without expanding tool details" true
    (Astring.String.is_infix ~affix:"Inspect_state" (progress ~now:5.5));
  check (list string) "the new input remains pending beside actual progress"
    ["new-pending-input"]
    (Tui.keeper_message_waiting_requests state ~keeper_name:"alpha"
     |> List.map (fun (request, _) -> request.Chat.request_id));
  (* Reopening the pane follows a held journal, with no locally owned stream. *)
  Masc_tui_keeper_chat_log.commit active.log.tl_log;
  state.msg_settled_logs <- [active.log];
  state.msg_inflight <- [];
  state.msg_live <- None;
  Masc_tui_keeper_chat_log.observe_operation_state active.log.tl_log
    (Some (Keeper_chat_operation.Running { started_at = 1. }));
  check bool "an observed journal keeps the same compact tool progress" true
    (Astring.String.is_infix ~affix:"Inspect_state" (progress ~now:6.))

let test_historical_open_journal_cannot_own_progress () =
  let module Log = Masc_tui_keeper_chat_log in
  let module Transcript = Masc_tui_keeper_chat_transcript in
  let state = state () in
  let old = inflight ~request_id:"yesterday" ~at:1. () in
  Tui.turn_log_add ~now:2. old.log ~seq:(Some 0) Live.Run_started;
  Tui.turn_log_add ~now:3. old.log ~seq:(Some 1) (Live.Text {text="retained partial output"; stream_scope=None});
  Log.commit old.log.tl_log;
  state.msg_settled_logs <- [old.log];
  check bool "an unclosed historical stream alone is not current progress" true
    (Option.is_none (Tui.keeper_message_status_log state));
  let current = inflight ~request_id:"today" ~at:100. () in
  Tui.turn_log_add ~now:101. current.log ~seq:(Some 0) Live.Run_started;
  state.msg_inflight <- [current];
  state.msg_live <- Some current.log;
  check (option string) "current input owns progress before historical reconciliation"
    (Some "today") (Option.map Tui.turn_log_request_id (Tui.keeper_message_status_log state));
  List.iter (fun terminal ->
    let log = Log.create ~keeper_name:"alpha" ~request_id:"yesterday" ~started_at:1. in
    ignore (Log.add ~at:2. log ~seq:(Some 0) Live.Run_started);
    ignore (Log.add ~at:3. log ~seq:(Some 1) (Live.Text {text="retained partial output"; stream_scope=None}));
    Log.observe_operation_state log (Some terminal);
    Log.observe_operation_state log (Some (Keeper_chat_operation.Running {started_at=1.}));
    check bool "terminal facts cannot regress on a delayed open observation" true
      (Option.exists Keeper_chat_operation.is_terminal (Log.operation_state log));
    let transcript = Transcript.of_log ~now:100. log in
    check bool "terminal operation closes an incomplete stream" true
      (match Transcript.phase transcript with Stream_ended | Stream_failed _ -> true | Waiting | Working -> false);
    check bool "partial output survives reconciliation" true
      (List.exists (fun (item : Transcript.drawn_item) ->
        match item.drawn with Drawn_text text -> text = "retained partial output" | _ -> false)
        (Transcript.drawn transcript));
    check int "no invented journal sequence" 1
      (match Log.resume_position log with After_seq seq -> seq | Whole_turn -> -1))
    [ Keeper_chat_operation.Failed {completed_at=4.; failure={kind=Turn_cancelled;
        detail="owner stopped the turn"; outcome_ref=None}}
    ; Cancelled {completed_at=4.}
    ; Succeeded {completed_at=4.; outcome_ref="recorded-result"} ]

(* Between continuation segments the request stays open and nothing is in
   progress, so the compact band says nothing. *)
let test_open_request_between_segments_has_no_banner () =
  let state = state () in
  state.msg_tool_visibility <- Tui.Tools_compact;
  let entry = inflight ~request_id:"checkpointed" ~at:1. () in
  List.iter (fun delta -> Tui.turn_log_add ~now:2. entry.log ~seq:None delta)
    [ Live.Run_started
    ; Live.Reply_details { terminal_stream_scope = None; reply = ""; turn_outcome = Continuation_checkpoint; turn_ref = "trace#1" }
    ; Live.Run_finished ];
  state.msg_inflight <- [entry];
  check bool "the request waits for its next segment" true
    (Masc_tui_keeper_chat_transcript.awaiting_continuation entry.log.tl_transcript);
  check (list string) "no progress banner between segments" []
    (texts (Tui.keeper_message_activity_rows state))
;;

let () =
  run "TUI chat activity"
    [ "request and lane states",
      [ test_case "historical open journal cannot own progress" `Quick test_historical_open_journal_cannot_own_progress
      ; test_case "compact progress follows working execution" `Quick
          test_compact_progress_follows_working_execution
      ; test_case "priority control receipt ordering" `Quick test_priority_control_receipt_ordering
      ; test_case "compact delivery and priority truth" `Quick test_compact_status_keeps_delivery_and_priority_truth
      ; test_case "open request between segments has no banner" `Quick
          test_open_request_between_segments_has_no_banner

      ; test_case "one status row per server batch" `Quick
          test_one_status_row_per_server_batch
      ; test_case "local queue is distinct from server admission" `Quick
          test_local_queue_is_not_server_admission
      ; test_case "Esc hint follows the observed turn" `Quick
          test_esc_hint_follows_the_observed_turn
      ; test_case "only the uncovered in-flight rows are drawn" `Quick
          test_only_the_uncovered_in_flight_rows_are_drawn
      ; test_case "a live turn elsewhere covers nothing here" `Quick
          test_a_live_turn_elsewhere_covers_nothing_here
      ] ]
