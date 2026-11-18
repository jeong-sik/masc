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
  T.note_drawn_reads state;
  start_inventory_read state;
  answer_inventory state warming;
  check drawn "a 304 that moves nothing" T.Drawn_unchanged (T.tools_inventory_effect state)

let test_answer_after_drawn_failure () =
  let state = state () in
  let warming = snapshot Tools.Warming in
  answer_inventory state warming;
  start_inventory_read state;
  fail_inventory state "read failed";
  T.note_drawn_reads state;
  start_inventory_read state;
  answer_inventory state warming;
  check drawn "a 304 clears the drawn failure" T.Drawn_changed (T.tools_inventory_effect state)

let test_answer_after_drawn_progress () =
  let state = state () in
  let warming = snapshot Tools.Warming in
  answer_inventory state warming;
  start_inventory_read state;
  (* A frame built while the read runs draws it in progress. *)
  T.note_drawn_reads state;
  answer_inventory state warming;
  check drawn "only the answer's frame clears the progress" T.Drawn_changed
    (T.tools_inventory_effect state)

let test_frame_in_between () =
  let state = state () in
  let warming = snapshot Tools.Warming in
  answer_inventory state warming;
  start_inventory_read state;
  T.note_drawn_reads state;
  answer_inventory state warming;
  check drawn "the answer clears the drawn progress" T.Drawn_changed (T.tools_inventory_effect state);
  (* The frame that answer asked for is built and recorded. *)
  T.note_drawn_reads state;
  start_inventory_read state;
  answer_inventory state warming;
  check drawn "the next 304 compares with that frame" T.Drawn_unchanged
    (T.tools_inventory_effect state)

let test_fresh_body () =
  let state = state () in
  answer_inventory state (snapshot Tools.Warming);
  T.note_drawn_reads state;
  answer_inventory state (snapshot Tools.Warming);
  check drawn "a fresh body is drawn even when it reads the same" T.Drawn_changed
    (T.tools_inventory_effect state);
  T.note_drawn_reads state;
  answer_inventory state (snapshot Tools.Settled);
  check drawn "a built inventory replaces the placeholder" T.Drawn_changed
    (T.tools_inventory_effect state)

let test_skill_cursor () =
  let state = state () in
  let warming = snapshot Tools.Warming in
  answer_inventory state warming;
  T.note_drawn_reads state;
  answer_inventory state warming;
  state.tools_skill_cursor <- state.tools_skill_cursor + 1;
  check drawn "the answer moved the Skill cursor" T.Drawn_changed (T.tools_inventory_effect state)

(* The waiting answer the loop applies when the projection is still not full:
   the same rows, no failure, nobody newly unverified. *)
let answer_waiting (state : T.state) =
  state.keeper_waiting_error <- None

let test_waiting () =
  let state = state () in
  answer_waiting state;
  T.note_drawn_reads state;
  answer_waiting state;
  check drawn "an incomplete projection read again" T.Drawn_unchanged (T.keeper_waiting_effect state);
  state.keeper_waiting_error <- Some (T.Request_failed "waiting read failed");
  T.note_drawn_reads state;
  answer_waiting state;
  check drawn "a 304 clears the drawn waiting failure" T.Drawn_changed (T.keeper_waiting_effect state);
  T.note_drawn_reads state;
  T.note_keeper_waiting_change state T.Waiting_all;
  check drawn "a change the screen now waits for" T.Drawn_changed (T.keeper_waiting_effect state)

let test_turns () =
  let state = state () in
  state.keeper_turns_inflight <- true;
  T.note_drawn_reads state;
  state.keeper_turns_inflight <- false;
  check drawn "the frame drew the turn read in progress" T.Drawn_changed (T.keeper_turns_effect state);
  T.note_drawn_reads state;
  state.keeper_turns_inflight <- true;
  state.keeper_turns_inflight <- false;
  check drawn "a turn read that moved nothing" T.Drawn_unchanged (T.keeper_turns_effect state);
  state.keeper_turns_error <- Some (T.Request_failed "turns read failed");
  T.note_drawn_reads state;
  state.keeper_turns_error <- None;
  check drawn "a 304 clears the drawn turn failure" T.Drawn_changed (T.keeper_turns_effect state);
  T.note_drawn_reads state;
  state.keeper_waiting_error <- Some (T.Request_failed "waiting read failed");
  check drawn "the turn answer carries waiting rows too" T.Drawn_changed (T.keeper_turns_effect state)

let () =
  run "tui_drawn_effect"
    [ ( "tools inventory",
        [ test_case "no frame yet" `Quick test_no_frame_yet;
          test_case "unchanged 304" `Quick test_unchanged_answer;
          test_case "304 after a drawn failure" `Quick test_answer_after_drawn_failure;
          test_case "answer after drawn progress" `Quick test_answer_after_drawn_progress;
          test_case "frame built in between" `Quick test_frame_in_between;
          test_case "fresh body" `Quick test_fresh_body;
          test_case "skill cursor" `Quick test_skill_cursor ] );
      ("keeper waiting", [ test_case "waiting answers" `Quick test_waiting ]);
      ("keeper turns", [ test_case "turn answers" `Quick test_turns ]) ]
