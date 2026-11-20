(* What one answer to the Tools inventory read leaves owed.

   The server answers with a warming placeholder until it has built the
   inventory, and no push says when it has. The placeholder is read again
   after a wait that grows with each placeholder in a row, like a failure's;
   a change announced while it was read is read now. *)

open Alcotest
module O = Masc_tui_owed_read
module T = Masc_tui_types
module Tools = Masc.Tui_decode_tools

(* Instants on the main loop's clock, [seconds] after this test began. The
   checks below count in seconds and move onto the clock at each call. *)
let start = Masc_tui_wake.Mono.now ()
let at seconds = Masc_tui_wake.Mono.after start seconds

let retry_s = 2.0
let max_retry_s = 30.0

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

let warming = Ok (snapshot Tools.Warming)
let settled = Ok (snapshot Tools.Settled)
let failure = Error "read failed"

let answer ?(answered_for = Some "keeper-a") result =
  T.tools_inventory_answer ~selected:(Some "keeper-a") ~answered_for result

(* The loop's [failed_read] and [placeholder_read] (bin/masc_tui.ml), with
   the loop's waits. The executable is not linkable, so the same module
   calls are made here. *)
let failed ~now owed = O.failed ~retry_s ~max_retry_s ~now:(at now) (O.answering owed)
let placeholder ~now owed = O.placeholder ~retry_s ~max_retry_s ~now:(at now) (O.answering owed)

let owed_after ~now answer owed =
  T.tools_inventory_owed ~failed:(failed ~now) ~warming:(placeholder ~now) answer owed

(* One read and its answer, as the loop applies them: the read starts, then
   its answer is judged once. *)
let read_and_answer ?answered_for ~now result owed =
  owed_after ~now (answer ?answered_for result) (O.started owed)

let test_answers () =
  let judged result =
    match answer result with
    | T.Inventory_read -> "read"
    | T.Inventory_warming -> "warming"
    | T.Inventory_failed -> "failed"
    | T.Inventory_for_another -> "for another"
  in
  check string "a built inventory is the reading" "read" (judged settled);
  check string "the placeholder" "warming" (judged warming);
  check string "a failure" "failed" (judged failure);
  check bool "an answer for a Keeper no longer selected"
    true
    (match answer ~answered_for:(Some "keeper-b") settled with
     | T.Inventory_for_another -> true
     | T.Inventory_read | T.Inventory_warming | T.Inventory_failed -> false)

let test_warming_in_a_row_waits_longer () =
  let owed = read_and_answer ~now:10.0 warming (O.changed O.settled) in
  check bool "not before the first wait" false (O.due ~now:(at 11.9) owed);
  check bool "after the first wait" true (O.due ~now:(at 12.0) owed);
  let owed = read_and_answer ~now:12.0 warming owed in
  check bool "a second placeholder waits twice as long" false (O.due ~now:(at 15.9) owed);
  check bool "after the second wait" true (O.due ~now:(at 16.0) owed);
  let owed = read_and_answer ~now:16.0 warming owed in
  check bool "a third waits longer again" false (O.due ~now:(at 23.9) owed);
  let owed = read_and_answer ~now:24.0 settled owed in
  check bool "the built inventory ends the reads" false (O.due ~now:(at 1000.0) owed)

let test_a_failure_counts_once () =
  let owed = read_and_answer ~now:10.0 failure (O.changed O.settled) in
  check bool "not before the first wait" false (O.due ~now:(at 11.9) owed);
  check bool "the first failure waits the first wait" true (O.due ~now:(at 12.0) owed)

let test_another_keeper_leaves_a_read_owed () =
  let owed = read_and_answer ~answered_for:(Some "keeper-b") ~now:10.0 settled (O.changed O.settled) in
  check bool "the selected Keeper is read now" true (O.due ~now:(at 10.0) owed)

let rec warming_in_a_row ~now ~count owed =
  if count = 0 then (now, owed)
  else
    let owed = read_and_answer ~now warming owed in
    warming_in_a_row ~now:(now +. max_retry_s) ~count:(count - 1) owed

let test_the_wait_stops_at_its_cap () =
  let now, owed = warming_in_a_row ~now:10.0 ~count:8 (O.changed O.settled) in
  let last = now -. max_retry_s in
  check bool "not before the longest wait" false (O.due ~now:(at (last +. max_retry_s -. 0.1)) owed);
  check bool "after the longest wait" true (O.due ~now:(at (last +. max_retry_s)) owed)

let test_a_built_inventory_puts_the_wait_back () =
  let now, owed = warming_in_a_row ~now:10.0 ~count:4 (O.changed O.settled) in
  let owed = read_and_answer ~now settled owed in
  check bool "nothing owed after the built inventory" false (O.due ~now:(at (now +. 1000.0)) owed);
  (* The server announces a change and the next read meets a placeholder
     again: the placeholders before the built inventory are not this one's. *)
  let owed = read_and_answer ~now warming (O.changed owed) in
  check bool "not read before the first wait" false (O.due ~now:(at (now +. retry_s -. 0.1)) owed);
  check bool "the first wait again" true (O.due ~now:(at (now +. retry_s)) owed)

let test_another_keeper_drops_the_failures () =
  let now, owed = warming_in_a_row ~now:10.0 ~count:4 (O.changed O.settled) in
  let owed = read_and_answer ~answered_for:(Some "keeper-b") ~now settled owed in
  check bool "the selected Keeper is read now" true (O.due ~now:(at now) owed);
  let owed = read_and_answer ~now warming owed in
  check bool "not read before the first wait" false (O.due ~now:(at (now +. retry_s -. 0.1)) owed);
  check bool "its placeholder waits the first wait" true (O.due ~now:(at (now +. retry_s)) owed)

(* A tools-inventory push while a placeholder read is in flight: the
   placeholder may have been answered from before the change, so the change
   is read at once rather than after the grown wait. The placeholders in a
   row still count toward the wait after that. *)
let test_a_change_during_a_placeholder_read_is_read_now () =
  let now, owed = warming_in_a_row ~now:10.0 ~count:4 (O.changed O.settled) in
  let reading = O.changed (O.started owed) in
  let owed = owed_after ~now (answer warming) reading in
  check bool "the change is read now" true (O.due ~now:(at now) owed);
  let owed = read_and_answer ~now warming owed in
  check bool "the next placeholder still waits the longest wait" false
    (O.due ~now:(at (now +. max_retry_s -. 0.1)) owed);
  check bool "after it" true (O.due ~now:(at (now +. max_retry_s)) owed)

(* A read the record did not start, such as one on entering the screen,
   still leaves its placeholder read again. *)
let test_a_placeholder_from_an_unheard_read_is_read_again () =
  let owed = owed_after ~now:10.0 (answer warming) O.settled in
  check bool "not before the first wait" false (O.due ~now:(at 11.9) owed);
  check bool "after the first wait" true (O.due ~now:(at 12.0) owed)

let () =
  run "tui_tools_inventory_owed"
    [ ( "answer",
        [ test_case "each answer is judged" `Quick test_answers;
          test_case "warming in a row waits longer" `Quick test_warming_in_a_row_waits_longer;
          test_case "a failure counts once" `Quick test_a_failure_counts_once;
          test_case "another Keeper's answer leaves a read owed" `Quick
            test_another_keeper_leaves_a_read_owed;
          test_case "the wait stops at its cap" `Quick test_the_wait_stops_at_its_cap;
          test_case "a built inventory puts the wait back" `Quick
            test_a_built_inventory_puts_the_wait_back;
          test_case "another Keeper's answer drops the failures" `Quick
            test_another_keeper_drops_the_failures;
          test_case "a change during a placeholder read is read now" `Quick
            test_a_change_during_a_placeholder_read_is_read_now;
          test_case "a placeholder from an unheard read is read again" `Quick
            test_a_placeholder_from_an_unheard_read_is_read_again ] ) ]
