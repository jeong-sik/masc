(* Whether an answer to a read the screen keeps asking again changed what the
   screen draws (RFC tui-one-screen-grammar §8).

   A frame records each reader's view when it is built. The reader's answer
   builds the view again and compares it with that record, so the loop asks
   for a frame only when the answer moved something a frame drew. The
   answers below write the state the way the loop's reader branches do
   (bin/masc_tui.ml); the executable is not linkable, so the same fields are
   written here. *)

open Alcotest
module T = Masc_tui_types
module Tools = Masc.Tui_decode_tools

let drawn =
  testable
    (fun formatter -> function
       | T.Drawn_changed -> Format.pp_print_string formatter "changed"
       | T.Drawn_unchanged -> Format.pp_print_string formatter "unchanged")
    (fun a b ->
       match a, b with
       | T.Drawn_changed, T.Drawn_changed | T.Drawn_unchanged, T.Drawn_unchanged -> true
       | T.Drawn_changed, T.Drawn_unchanged | T.Drawn_unchanged, T.Drawn_changed -> false)

let state () = T.create_state ~workspace:"drawn-effect" ~port:8935 ()

(* A frame as the loop builds one: it begins, the drawing notes what it drew
   from the turns observation time (Metrics and the answering overlay draw
   its age), and the drawn views are recorded. *)
let draw_frame ?(age_drawn = false) state =
  T.begin_drawn_reads ();
  if age_drawn then T.note_turn_observation_age_drawn ();
  T.note_drawn_reads state

let snapshot freshness =
  { Tools.ts_tools = [];
    ts_count = 0;
    ts_freshness = freshness;
    ts_effective = None;
    ts_usage = None;
    ts_volume_gc_report = None;
    ts_storage =
      { Tools.st_host_disk = Tools.Host_disk_absent;
        st_keeper_cleanup = Tools.Keeper_cleanup_absent } }

(* The inventory read begins: the Keeper reads in flight say so. *)
let start_inventory_read (state : T.state) =
  state.tools_read_inflight <-
    Some { T.tri_generation = state.tools_request_generation;
           tri_keeper = None;
           tri_pending = [ T.Tools_inventory_read ] }

(* Its answer: the read is settled and the reading replaces the held one. *)
let answer_inventory (state : T.state) reading =
  state.tools_read_inflight <- None;
  state.tools_inventory <- Some reading;
  state.tools_inventory_keeper <- None;
  state.tools_error <- None

let fail_inventory (state : T.state) detail =
  state.tools_read_inflight <- None;
  state.tools_error <- Some (T.Request_failed detail)

let test_no_frame_yet () =
  let state = state () in
  answer_inventory state (snapshot Tools.Warming);
  check drawn "nothing was drawn yet" T.Drawn_changed (T.tools_inventory_effect state)

let test_unchanged_answer () =
  let state = state () in
  (* A 304 answers with the very value the last read decoded. *)
  let warming = snapshot Tools.Warming in
  answer_inventory state warming;
  draw_frame state;
  start_inventory_read state;
  answer_inventory state warming;
  check drawn "a 304 that moves nothing" T.Drawn_unchanged (T.tools_inventory_effect state)

let test_answer_after_drawn_failure () =
  let state = state () in
  let warming = snapshot Tools.Warming in
  answer_inventory state warming;
  start_inventory_read state;
  fail_inventory state "read failed";
  draw_frame state;
  start_inventory_read state;
  answer_inventory state warming;
  check drawn "a 304 clears the drawn failure" T.Drawn_changed (T.tools_inventory_effect state)

let test_answer_after_drawn_progress () =
  let state = state () in
  let warming = snapshot Tools.Warming in
  answer_inventory state warming;
  start_inventory_read state;
  (* A frame built while the read runs draws it in progress. *)
  draw_frame state;
  answer_inventory state warming;
  check drawn "only the answer's frame clears the progress" T.Drawn_changed
    (T.tools_inventory_effect state)

let test_frame_in_between () =
  let state = state () in
  let warming = snapshot Tools.Warming in
  answer_inventory state warming;
  start_inventory_read state;
  draw_frame state;
  answer_inventory state warming;
  check drawn "the answer clears the drawn progress" T.Drawn_changed (T.tools_inventory_effect state);
  (* The frame that answer asked for is built and recorded. *)
  draw_frame state;
  start_inventory_read state;
  answer_inventory state warming;
  check drawn "the next 304 compares with that frame" T.Drawn_unchanged
    (T.tools_inventory_effect state)

let test_fresh_body () =
  let state = state () in
  answer_inventory state (snapshot Tools.Warming);
  draw_frame state;
  answer_inventory state (snapshot Tools.Warming);
  check drawn "a fresh body is drawn even when it reads the same" T.Drawn_changed
    (T.tools_inventory_effect state);
  draw_frame state;
  answer_inventory state (snapshot Tools.Settled);
  check drawn "a built inventory replaces the placeholder" T.Drawn_changed
    (T.tools_inventory_effect state)

let test_skill_selection () =
  let state = state () in
  let warming = snapshot Tools.Warming in
  answer_inventory state warming;
  draw_frame state;
  answer_inventory state warming;
  state.tools_skill_cursor <- state.tools_skill_cursor + 1;
  check drawn "the answer moved the Skill cursor" T.Drawn_changed (T.tools_inventory_effect state);
  state.tools_skill_focus <- T.Reading_page;
  draw_frame state;
  answer_inventory state warming;
  state.tools_skill_focus <- T.Choosing_skill;
  check drawn "the selected Skill page closed" T.Drawn_changed (T.tools_inventory_effect state);
  draw_frame state;
  answer_inventory state warming;
  T.tools_task_user_scroll state (state.tools_scroll + 1);
  check drawn "the list followed the Skill selection" T.Drawn_changed (T.tools_inventory_effect state)

(* The waiting answer the loop applies when the projection is still not full:
   the same rows, no failure, nobody newly unverified. *)
let answer_waiting (state : T.state) =
  state.keeper_waiting_error <- None

let test_waiting () =
  let state = state () in
  answer_waiting state;
  draw_frame state;
  answer_waiting state;
  check drawn "an incomplete projection read again" T.Drawn_unchanged (T.keeper_waiting_effect state);
  state.keeper_waiting_error <- Some (T.Request_failed "waiting read failed");
  draw_frame state;
  answer_waiting state;
  check drawn "a 304 clears the drawn waiting failure" T.Drawn_changed (T.keeper_waiting_effect state);
  draw_frame state;
  T.note_keeper_waiting_change state T.Waiting_all;
  check drawn "a change the screen now waits for" T.Drawn_changed (T.keeper_waiting_effect state)

let test_turns () =
  let state = state () in
  draw_frame state;
  state.keeper_turns_inflight <- true;
  check drawn "a turn read in progress is not drawn" T.Drawn_unchanged (T.keeper_turns_effect state);
  state.keeper_turns_inflight <- false;
  check drawn "nor is its end" T.Drawn_unchanged (T.keeper_turns_effect state);
  state.keeper_turns_error <- Some (T.Request_failed "turns read failed");
  draw_frame state;
  state.keeper_turns_error <- None;
  check drawn "a 304 clears the drawn turn failure" T.Drawn_changed (T.keeper_turns_effect state);
  draw_frame state;
  state.keeper_waiting_error <- Some (T.Request_failed "waiting read failed");
  check drawn "the turn answer carries waiting rows too" T.Drawn_changed (T.keeper_turns_effect state)

(* The cases below apply answers through the same state functions the
   loop's reader branches call (accept_keeper_turn_observation,
   accept_keeper_waiting_observation, Keeper_waiting_read), so the identity
   a 304 keeps is the one those functions keep. *)
module Decode = Masc.Tui_decode

(* [Sys.opaque_identity] keeps each row a fresh allocation, as a decoded
   body's rows are; a record of constants would be shared by the compiler. *)
let turn name : Decode.keeper_turn_row =
  { ktr_keeper_name = Sys.opaque_identity name; ktr_chat_control_token = None;
    ktr_state = Decode.Keeper_turn_idle }

let waiting_row name : Decode.keeper_waiting_row =
  { kwr_keeper_name = Sys.opaque_identity name
  ; kwr_state = Decode.Keeper_waiting_idle
  ; kwr_waiting_count = 0
  ; kwr_since = None
  ; kwr_due_at = None
  ; kwr_source_counts = []
  ; kwr_waiting_heads = [] }

let test_tools_other_keeper () =
  let state = state () in
  state.tools_inventory_keeper <- Some "alpha";
  state.tools_error <- Some (T.Request_failed "HTTP 503");
  draw_frame state;
  (* The read for the Keeper now selected fails the same way. *)
  state.tools_inventory_keeper <- Some "beta";
  state.tools_error <- Some (T.Request_failed "HTTP 503");
  check drawn "a failure now held for another Keeper" T.Drawn_changed (T.tools_inventory_effect state)

let test_turns_success_moves_observation_time () =
  let state = state () in
  let rows = [ turn "alpha" ] in
  let observed = Decode.Keeper_waiting_observed [ waiting_row "alpha" ] in
  T.accept_keeper_turn_observation state ~rows ~waiting:observed ~observed_at:10.;
  draw_frame state;
  (* The same decoded rows again, as a 304 hands them back: the answer
     stamps a new observation time, which this frame drew no age from. *)
  T.accept_keeper_turn_observation state ~rows ~waiting:observed ~observed_at:40.;
  check drawn "a later time no frame drew" T.Drawn_unchanged (T.keeper_turns_effect state);
  (* Metrics draws the age from that time. *)
  draw_frame ~age_drawn:true state;
  T.accept_keeper_turn_observation state ~rows ~waiting:observed ~observed_at:70.;
  check drawn "a later time the frame drew an age from" T.Drawn_changed
    (T.keeper_turns_effect state);
  (* The next frame is on a screen without the age; the note does not
     carry over from the frame before. *)
  draw_frame state;
  T.accept_keeper_turn_observation state ~rows ~waiting:observed ~observed_at:100.;
  check drawn "the age is no longer drawn" T.Drawn_unchanged (T.keeper_turns_effect state)

let test_turns_first_observation () =
  let state = state () in
  draw_frame state;
  (* The first answer turns "not read yet" into rows read, on any screen. *)
  T.accept_keeper_turn_observation state ~rows:[]
    ~waiting:(Decode.Keeper_waiting_observed []) ~observed_at:10.;
  check drawn "the first observation" T.Drawn_changed (T.keeper_turns_effect state);
  draw_frame ~age_drawn:true state;
  T.accept_keeper_turn_observation state ~rows:[]
    ~waiting:(Decode.Keeper_waiting_observed []) ~observed_at:10.;
  check drawn "the drawn age's time again" T.Drawn_unchanged (T.keeper_turns_effect state)

let test_turns_repeated_failure () =
  let state = state () in
  T.refuse_keeper_turn_observation state (T.Request_failed "HTTP 503");
  draw_frame state;
  state.keeper_turns_inflight <- true;
  state.keeper_turns_inflight <- false;
  T.refuse_keeper_turn_observation state (T.Request_failed "HTTP 503");
  check drawn "the same failure again" T.Drawn_unchanged (T.keeper_turns_effect state);
  T.refuse_keeper_turn_observation state (T.Request_failed "HTTP 502");
  check drawn "a different failure" T.Drawn_changed (T.keeper_turns_effect state)

let test_turns_fresh_rows () =
  let state = state () in
  state.keeper_turns <- [ turn "alpha" ];
  state.keeper_turns_observed_at <- Some 10.;
  draw_frame state;
  (* A fresh body decodes new rows; the observation time is held still so
     only the rows differ. *)
  state.keeper_turns <- [ turn "alpha" ];
  check drawn "rows from a fresh body" T.Drawn_changed (T.keeper_turns_effect state)

let test_turns_finish_glow () =
  let state = state () in
  draw_frame state;
  state.keeper_turn_finishes <- [ ("alpha", 10.) ];
  check drawn "a turn that just finished" T.Drawn_changed (T.keeper_turns_effect state)

let test_turns_settle_awaited_waiting () =
  let state = state () in
  T.note_keeper_waiting_change state T.Waiting_all;
  draw_frame state;
  (* The turns answer completes the waiting projection the screen waited for. *)
  state.keeper_waiting_read <- T.Keeper_waiting_read.settle_poll state.keeper_waiting_read ~success:true;
  check drawn "the wait the frame drew ends" T.Drawn_changed (T.keeper_turns_effect state)

let test_waiting_304_through_merge () =
  let state = state () in
  let rows = [ turn "alpha" ] in
  let observed = Decode.Keeper_waiting_observed [ waiting_row "alpha" ] in
  T.accept_keeper_waiting_observation state ~rows ~waiting:observed;
  draw_frame state;
  T.accept_keeper_waiting_observation state ~rows ~waiting:observed;
  check drawn "the same decoded answer" T.Drawn_unchanged (T.keeper_waiting_effect state);
  T.accept_keeper_waiting_observation state ~rows
    ~waiting:(Decode.Keeper_waiting_observed [ waiting_row "alpha" ]);
  check drawn "a fresh body" T.Drawn_changed (T.keeper_waiting_effect state)

let test_waiting_failure_cleared () =
  let state = state () in
  let rows = [ turn "alpha" ] in
  let held = waiting_row "alpha" in
  T.accept_keeper_waiting_observation state ~rows ~waiting:(Decode.Keeper_waiting_observed [ held ]);
  state.keeper_waiting_failure <- Some (Decode.Keeper_waiting_invalid "fleet scan failed");
  draw_frame state;
  (* Every Keeper on screen is observed again with the rows already held. *)
  T.accept_keeper_waiting_observation state ~rows ~waiting:(Decode.Keeper_waiting_observed [ held ]);
  check drawn "the fleet failure the frame drew is gone" T.Drawn_changed (T.keeper_waiting_effect state)

let test_waiting_unverified_resolved () =
  let state = state () in
  state.keeper_waiting_unverified <- [ "alpha"; "beta" ];
  draw_frame state;
  state.keeper_waiting_unverified <- [ "beta" ];
  check drawn "a Keeper read again" T.Drawn_changed (T.keeper_waiting_effect state)

let test_waiting_read_settles_the_wait () =
  let state = state () in
  T.note_keeper_waiting_change state T.Waiting_all;
  draw_frame state;
  let reading, request = T.Keeper_waiting_read.start state.keeper_waiting_read in
  state.keeper_waiting_read <- reading;
  (* Starting the read changes nothing the frame drew. *)
  check drawn "the read starts" T.Drawn_unchanged (T.keeper_waiting_effect state);
  (match request with
   | None -> fail "a change pending starts a read"
   | Some request ->
       (match T.Keeper_waiting_read.finish state.keeper_waiting_read request ~observed:true ~success:true with
        | None -> fail "the read in flight settles"
        | Some (reading, _follow_up) -> state.keeper_waiting_read <- reading));
  check drawn "the answer ends the drawn wait" T.Drawn_changed (T.keeper_waiting_effect state);
  draw_frame state;
  let reading, request = T.Keeper_waiting_read.start state.keeper_waiting_read in
  state.keeper_waiting_read <- reading;
  (match request with
   | None -> ()
   | Some request ->
       (match T.Keeper_waiting_read.finish state.keeper_waiting_read request ~observed:true ~success:true with
        | None -> ()
        | Some (reading, _follow_up) -> state.keeper_waiting_read <- reading));
  check drawn "a read with nothing awaited" T.Drawn_unchanged (T.keeper_waiting_effect state)

(* The reading slot is no reader's view (RFC tui-one-screen-grammar section 8).
   A read is begun and ended in the state, and each loop pass asks whether
   what the slot draws moved since the last frame. Instants are the real
   clock plus a whole or half second, so the decision under test is the 1 s
   bar and not the clock's grain. *)
module Wake = Masc_tui_wake

let at start seconds = Wake.Mono.after start seconds

let show (state : T.state) surface = state.view <- surface

let test_slot_no_frame_yet () =
  let state = state () in
  let start = Wake.Mono.now () in
  check drawn "nothing was drawn yet" T.Drawn_changed
    (T.step_reading_slot state ~now:start)

let test_slot_start_requests_nothing () =
  let state = state () in
  draw_frame state;
  let start = Wake.Mono.now () in
  let _read = T.reading_begin state in
  check drawn "a read inside the bar" T.Drawn_unchanged
    (T.step_reading_slot state ~now:(at start 0.5))

let test_slot_fast_read_requests_nothing () =
  let state = state () in
  draw_frame state;
  let start = Wake.Mono.now () in
  let settle = T.reading_begin state in
  settle ~ok:true;
  check drawn "a read that ended inside the bar" T.Drawn_unchanged
    (T.step_reading_slot state ~now:(at start 0.5));
  check drawn "and left nothing behind" T.Drawn_unchanged
    (T.step_reading_slot state ~now:(at start 3.0))

let test_slot_turns_on_once () =
  let state = state () in
  draw_frame state;
  let start = Wake.Mono.now () in
  let _read = T.reading_begin state in
  check drawn "the read passes the bar" T.Drawn_changed
    (T.step_reading_slot state ~now:(at start 1.5));
  draw_frame state;
  check drawn "the same read a second later" T.Drawn_unchanged
    (T.step_reading_slot state ~now:(at start 2.5))

(* An answer that draws the same rows still ends the read. The frame that
   turns the slot off is owed, one bar after the last slow read succeeded. *)
let test_slot_off_after_the_answer () =
  let state = state () in
  draw_frame state;
  let start = Wake.Mono.now () in
  let settle = T.reading_begin state in
  check drawn "on" T.Drawn_changed
    (T.step_reading_slot state ~now:(at start 1.5));
  draw_frame state;
  settle ~ok:true;
  check drawn "the length freezes" T.Drawn_changed
    (T.step_reading_slot state ~now:(at start 2.0));
  draw_frame state;
  check drawn "kept on for one bar" T.Drawn_unchanged
    (T.step_reading_slot state ~now:(at start 2.5));
  check drawn "off after the bar" T.Drawn_changed
    (T.step_reading_slot state ~now:(at start 3.5));
  draw_frame state;
  check drawn "and it stays off" T.Drawn_unchanged
    (T.step_reading_slot state ~now:(at start 4.0))

let test_slot_off_at_once_when_the_read_fails () =
  let state = state () in
  draw_frame state;
  let start = Wake.Mono.now () in
  let settle = T.reading_begin state in
  check drawn "on" T.Drawn_changed
    (T.step_reading_slot state ~now:(at start 1.5));
  draw_frame state;
  settle ~ok:false;
  check drawn "a failure turns it off at once" T.Drawn_changed
    (T.step_reading_slot state ~now:(at start 2.0));
  draw_frame state;
  check drawn "and no wait follows" T.Drawn_unchanged
    (T.step_reading_slot state ~now:(at start 3.5))

(* A read that reports its end on two paths counts once: the second end must
   not turn a success into a failure that cancels the wait. *)
let test_slot_second_end_is_ignored () =
  let state = state () in
  draw_frame state;
  let start = Wake.Mono.now () in
  let settle = T.reading_begin state in
  check drawn "on" T.Drawn_changed
    (T.step_reading_slot state ~now:(at start 1.5));
  draw_frame state;
  settle ~ok:true;
  settle ~ok:false;
  check drawn "the length freezes" T.Drawn_changed
    (T.step_reading_slot state ~now:(at start 2.0));
  draw_frame state;
  check drawn "still on inside the bar" T.Drawn_unchanged
    (T.step_reading_slot state ~now:(at start 2.5));
  check drawn "off only after the bar" T.Drawn_changed
    (T.step_reading_slot state ~now:(at start 3.5))

(* A read belongs to the screen that was open when it began. *)
let test_slot_counts_a_read_for_its_own_screen () =
  let state = state () in
  show state T.Memory;
  draw_frame state;
  let start = Wake.Mono.now () in
  let _read = T.reading_begin state in
  show state T.Overview;
  check drawn "the read began for the other screen" T.Drawn_unchanged
    (T.step_reading_slot state ~now:(at start 1.5));
  show state T.Memory;
  check drawn "back on the screen it began for" T.Drawn_changed
    (T.step_reading_slot state ~now:(at start 2.0))

let () =
  run "tui_drawn_effect"
    [ ( "tools inventory",
        [ test_case "no frame yet" `Quick test_no_frame_yet;
          test_case "unchanged 304" `Quick test_unchanged_answer;
          test_case "304 after a drawn failure" `Quick test_answer_after_drawn_failure;
          test_case "answer after drawn progress" `Quick test_answer_after_drawn_progress;
          test_case "frame built in between" `Quick test_frame_in_between;
          test_case "fresh body" `Quick test_fresh_body;
          test_case "Skill selection, page and scroll" `Quick test_skill_selection;
          test_case "failure for another Keeper" `Quick test_tools_other_keeper ] );
      ( "keeper waiting",
        [ test_case "waiting answers" `Quick test_waiting;
          test_case "304 through the merge" `Quick test_waiting_304_through_merge;
          test_case "fleet failure cleared" `Quick test_waiting_failure_cleared;
          test_case "unverified Keeper resolved" `Quick test_waiting_unverified_resolved;
          test_case "read settles the wait" `Quick test_waiting_read_settles_the_wait ] );
      ( "keeper turns",
        [ test_case "turn answers" `Quick test_turns;
          test_case "success moves the observation time" `Quick
            test_turns_success_moves_observation_time;
          test_case "first observation" `Quick test_turns_first_observation;
          test_case "repeated failure" `Quick test_turns_repeated_failure;
          test_case "fresh rows" `Quick test_turns_fresh_rows;
          test_case "finish glow" `Quick test_turns_finish_glow;
          test_case "awaited waiting settles" `Quick test_turns_settle_awaited_waiting ] );
      ( "reading slot",
        [ test_case "no frame yet" `Quick test_slot_no_frame_yet;
          test_case "a read begins" `Quick test_slot_start_requests_nothing;
          test_case "a fast read" `Quick test_slot_fast_read_requests_nothing;
          test_case "passes the bar" `Quick test_slot_turns_on_once;
          test_case "off after the answer" `Quick test_slot_off_after_the_answer;
          test_case "off when the read fails" `Quick
            test_slot_off_at_once_when_the_read_fails;
          test_case "a second end" `Quick test_slot_second_end_is_ignored;
          test_case "a read's own screen" `Quick
            test_slot_counts_a_read_for_its_own_screen ] ) ]
