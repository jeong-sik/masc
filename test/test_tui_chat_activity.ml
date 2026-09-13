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
  { ktr_keeper_name = keeper_name
  ; ktr_state = Keeper_turn_running { lane; started_at_unix = 1.; interrupt_token = None; preview = None }
  }

let live ?(keeper_name = "alpha") state admission =
  let live = Tui.turn_log_create ~keeper_name ~request_id:"request-1" ~started_at:2. in
  Option.iter (fun admission ->
    Tui.turn_log_add ~now:3. live ~seq:None
      (Live.Accepted { admission; queue_length = 3 })) admission;
  state.Tui.msg_live <- Some live;
  live

let last rows = match List.rev rows with
  | line :: _ -> line
  | [] -> fail "expected an activity row"

let test_admission_is_not_inferred_from_waiting_phase () =
  List.iter (fun (admission, expected) ->
    let state = state () in
    state.keeper_turns <- [running Turn_lane_autonomous];
    ignore (live state admission);
    check string "same Waiting phase, distinct admission facts" expected
      (last (Tui.keeper_message_activity_rows state)))
    [ None, "Your request is awaiting server acceptance; queue position unknown"
    ; Some Live.Running, "Your request was accepted; waiting for its first event"
    ; Some Live.Settled, "Your request already settled; replaying its result"
    ; Some Live.Queued, "Your message is queued behind this Keeper's current turn; start time unknown"
    ]

let test_queue_does_not_invent_a_blocking_turn () =
  List.iter (fun (rows, error) ->
    let state = state () in
    state.keeper_turns <- rows;
    state.keeper_turns_error <- error;
    ignore (live state (Some Live.Queued));
    check string "unknown or unrelated turn cannot be the blocker"
      "Your message is queued at the server; start time unknown"
      (last (Tui.keeper_message_activity_rows state)))
    [ [], None
    ; [running ~keeper_name:"beta" Turn_lane_autonomous], None
    ; [running Turn_lane_chat_operation], None
    ; [running Turn_lane_autonomous], Some "timeout"
    ; [{ Decode.ktr_keeper_name = "alpha"; ktr_state = Keeper_turn_idle }], None
    ; [{ Decode.ktr_keeper_name = "alpha"; ktr_state = Keeper_turn_unavailable "offline" }], None
    ];
  let state = state () in
  state.keeper_turns <- [running Turn_lane_maintenance];
  ignore (live state (Some Live.Queued));
  check string "same Keeper maintenance is observed background work"
    "Your message is queued behind this Keeper's current turn; start time unknown"
    (last (Tui.keeper_message_activity_rows state))

let test_started_and_finished_requests_stop_waiting () =
  let state = state () in
  let log = live state (Some Live.Queued) in
  state.keeper_turns <- [running Turn_lane_chat_operation];
  Tui.turn_log_add ~now:4. log ~seq:(Some 1) Live.Run_started;
  check (list string) "run started supersedes its old queued acceptance" []
    (Tui.keeper_message_activity_rows state);
  state.keeper_turns <- [];
  Tui.turn_log_add ~now:5. log ~seq:(Some 2) Live.Run_finished;
  check (list string) "settled run is not queued" []
    (Tui.keeper_message_activity_rows state);
  ignore (live ~keeper_name:"beta" state (Some Live.Queued));
  check (list string) "another Keeper's pending submission stays out" []
    (Tui.keeper_message_activity_rows state)

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
    ["1 message waiting in this TUI; not sent to the server yet"]
    (Tui.keeper_message_activity_rows state);
  state.msg_target_keeper_name <- None;
  check (list string) "no target has no attributed activity" []
    (Tui.keeper_message_activity_rows state)

let () =
  run "TUI chat activity"
    [ "request and lane states",
      [ test_case "admission distinguishes Waiting states" `Quick
          test_admission_is_not_inferred_from_waiting_phase
      ; test_case "queue does not invent its blocker" `Quick
          test_queue_does_not_invent_a_blocking_turn
      ; test_case "started, finished, and other Keeper requests" `Quick
          test_started_and_finished_requests_stop_waiting
      ; test_case "local queue is distinct from server admission" `Quick
          test_local_queue_is_not_server_admission
      ] ]
