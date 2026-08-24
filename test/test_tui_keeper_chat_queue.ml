(** What happens to a line typed while a turn is running.

    It used to be answered with "Keeper message already in progress" and lost.
    These pin what replaced that: the line waits, in the order it was written,
    addressed to the keeper it was written to. *)

open Alcotest
module Queue = Masc_tui_keeper_chat_queue

let push_exn queue ~keeper_name text =
  match Queue.push queue ~keeper_name text with
  | Ok (queue, waiting) -> (queue, waiting)
  | Error detail -> failf "expected the line to queue, got: %s" detail
;;

let test_lines_wait_in_the_order_they_were_written () =
  let q, first = push_exn Queue.empty ~keeper_name:"bluebird" "one" in
  let q, second = push_exn q ~keeper_name:"bluebird" "two" in
  let q, third = push_exn q ~keeper_name:"bluebird" "three" in
  check (list int) "each push says how many are waiting" [ 1; 2; 3 ]
    [ first; second; third ];
  check (list string) "and they wait in submission order"
    [ "one"; "two"; "three" ]
    (List.map snd (Queue.waiting q))
;;

(* The operator can switch keepers while a turn runs. A queued line must reach
   the keeper it was written to, not whoever is selected when it finally goes. *)
let test_a_line_keeps_the_keeper_it_was_written_to () =
  let q, _ = push_exn Queue.empty ~keeper_name:"bluebird" "for bluebird" in
  let q, _ = push_exn q ~keeper_name:"bandleader" "for bandleader" in
  match Queue.take_first_sendable q ~sendable:(fun _ -> true) with
  | None -> fail "expected a waiting line"
  | Some ((keeper_name, text), rest) ->
      check string "the oldest goes first" "for bluebird" text;
      check string "to its own keeper" "bluebird" keeper_name;
      (match Queue.take_first_sendable rest ~sendable:(fun _ -> true) with
       | None -> fail "expected the second line to still be waiting"
       | Some ((keeper_name, text), rest) ->
           check string "and the next keeps its own" "bandleader" keeper_name;
           check string "with its own text" "for bandleader" text;
           check bool "nothing left after both" true (Queue.is_empty rest))
;;

(* Refused and named at the cap rather than dropping the oldest: a line that
   silently disappeared is the failure this whole queue exists to end. *)
let test_the_cap_refuses_rather_than_forgetting () =
  let rec fill queue = function
    | 0 -> queue
    | n ->
        let queue, _ = push_exn queue ~keeper_name:"k" (string_of_int n) in
        fill queue (n - 1)
  in
  let full = fill Queue.empty Queue.cap in
  check int "the queue is at its cap" Queue.cap (Queue.length full);
  match Queue.push full ~keeper_name:"k" "one too many" with
  | Ok _ -> fail "the cap must refuse"
  | Error detail ->
      check bool "the refusal says the line was not taken" true
        (Astring.String.is_infix ~affix:"not queued" detail);
      check int "and nothing already waiting was dropped" Queue.cap
        (Queue.length full)
;;

(* A keeper that is no longer registered cannot receive what was written to it.
   Holding those lines would make the count report work that never moves. *)
let test_lines_for_a_departed_keeper_are_forgotten () =
  let q, _ = push_exn Queue.empty ~keeper_name:"leaving" "gone" in
  let q, _ = push_exn q ~keeper_name:"staying" "kept" in
  let q, _ = push_exn q ~keeper_name:"leaving" "gone too" in
  let q = Queue.drop_for_keeper q ~keeper_name:"leaving" in
  check (list string) "only the other keeper's line remains" [ "kept" ]
    (List.map snd (Queue.waiting q));
  check int "and the count follows" 1 (Queue.length q)
;;

(* Lines wait because their own keeper had a turn running, and keepers run
   turns independently. Taking strictly from the front stalls every line behind
   one whose keeper is still busy — and permanently, because the ones behind it
   are addressed to keepers that are idle and so have no settle coming. *)
let test_a_busy_keeper_does_not_stall_the_lines_behind_it () =
  let q, _ = push_exn Queue.empty ~keeper_name:"busy" "waits" in
  let q, _ = push_exn q ~keeper_name:"free" "can go" in
  let q, _ = push_exn q ~keeper_name:"busy" "waits too" in
  match Queue.take_first_sendable q ~sendable:(fun k -> not (String.equal k "busy")) with
  | None -> fail "the free keeper's line should be sendable"
  | Some ((keeper_name, text), rest) ->
      check string "the free keeper's line comes out" "can go" text;
      check string "with its own keeper" "free" keeper_name;
      check (list string) "and the busy keeper's lines keep their order"
        [ "waits"; "waits too" ]
        (List.map snd (Queue.waiting rest))
;;

let test_nothing_sendable_takes_nothing () =
  let q, _ = push_exn Queue.empty ~keeper_name:"busy" "waits" in
  check bool "a queue with only busy keepers takes nothing" true
    (Option.is_none (Queue.take_first_sendable q ~sendable:(fun _ -> false)));
  check int "and keeps what it had" 1 (Queue.length q)
;;

(* With everything sendable it is the oldest line, the same as popping. *)
let test_all_sendable_is_oldest_first () =
  let q, _ = push_exn Queue.empty ~keeper_name:"a" "one" in
  let q, _ = push_exn q ~keeper_name:"b" "two" in
  match Queue.take_first_sendable q ~sendable:(fun _ -> true) with
  | None -> fail "expected a line"
  | Some ((_, text), rest) ->
      check string "oldest first" "one" text;
      check (list string) "the rest keeps its order" [ "two" ]
        (List.map snd (Queue.waiting rest))
;;

let test_an_empty_queue_takes_nothing () =
  check bool "empty is empty" true (Queue.is_empty Queue.empty);
  check int "and has no length" 0 (Queue.length Queue.empty);
  check bool "and takes nothing" true
    (Option.is_none (Queue.take_first_sendable Queue.empty ~sendable:(fun _ -> true)))
;;

let () =
  run
    "tui_keeper_chat_queue"
    [ ( "queue"
      , [ test_case "lines wait in the order they were written" `Quick
            test_lines_wait_in_the_order_they_were_written
        ; test_case "a line keeps the keeper it was written to" `Quick
            test_a_line_keeps_the_keeper_it_was_written_to
        ; test_case "the cap refuses rather than forgetting" `Quick
            test_the_cap_refuses_rather_than_forgetting
        ; test_case "lines for a departed keeper are forgotten" `Quick
            test_lines_for_a_departed_keeper_are_forgotten
        ; test_case "a busy keeper does not stall the lines behind it" `Quick
            test_a_busy_keeper_does_not_stall_the_lines_behind_it
        ; test_case "nothing sendable takes nothing" `Quick
            test_nothing_sendable_takes_nothing
        ; test_case "all sendable is oldest first" `Quick
            test_all_sendable_is_oldest_first
        ; test_case "an empty queue takes nothing" `Quick
            test_an_empty_queue_takes_nothing
        ] )
    ]
;;
