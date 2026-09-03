(** What happens to a line typed while a turn is running.

    It used to be answered with "Keeper message already in progress" and lost.
    These pin what replaced that: the line waits, in the order it was written,
    addressed to the keeper it was written to. *)

open Alcotest
module Queue = Masc_tui_keeper_chat_queue
module Chat = Masc_tui_keeper_chat_projection

(* What waits is the whole request, built when the operator pressed Enter.
   These tests are about order, so they build the smallest one that carries a
   keeper and a message. *)
let request ~keeper_name text =
  Chat.create_request ~attachments:[] ~keeper_name ~message:text ()
;;

let messages queue =
  List.map
    (fun (item : Queue.item) -> item.request.Chat.message)
    (Queue.waiting queue)
;;

let push_exn queue ~keeper_name text =
  match Queue.push queue ~submitted_at:42. (request ~keeper_name text) with
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
    (messages q)
;;

(* The operator can switch keepers while a turn runs. A queued line must reach
   the keeper it was written to, not whoever is selected when it finally goes. *)
let test_a_line_keeps_the_keeper_it_was_written_to () =
  let q, _ = push_exn Queue.empty ~keeper_name:"bluebird" "for bluebird" in
  let q, _ = push_exn q ~keeper_name:"bandleader" "for bandleader" in
  match Queue.take_first_sendable q ~sendable:(fun _ -> true) with
  | None -> fail "expected a waiting line"
  | Some (first_item, rest) ->
      let first = first_item.Queue.request in
      check string "the oldest goes first" "for bluebird" first.Chat.message;
      check string "to its own keeper" "bluebird" first.Chat.keeper_name;
      (match Queue.take_first_sendable rest ~sendable:(fun _ -> true) with
       | None -> fail "expected the second line to still be waiting"
       | Some (second_item, rest) ->
           let second = second_item.Queue.request in
           check string "and the next keeps its own" "bandleader"
             second.Chat.keeper_name;
           check string "with its own text" "for bandleader" second.Chat.message;
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
  match
    Queue.push full ~submitted_at:42. (request ~keeper_name:"k" "one too many")
  with
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
    (messages q);
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
  | Some (taken_item, rest) ->
      let taken = taken_item.Queue.request in
      check string "the free keeper's line comes out" "can go" taken.Chat.message;
      check string "with its own keeper" "free" taken.Chat.keeper_name;
      check (list string) "and the busy keeper's lines keep their order"
        [ "waits"; "waits too" ]
        (messages rest)
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
  | Some (taken_item, rest) ->
      let taken = taken_item.Queue.request in
      check string "oldest first" "one" taken.Chat.message;
      check (list string) "the rest keeps its order" [ "two" ]
        (messages rest)
;;

(* Editing a waiting line takes that line out, not the newest one. The arrows
   can walk back past several, and replacing "whichever was last" would drop a
   line the operator never looked at. *)
let test_take_removes_the_named_line_and_keeps_the_order () =
  let one = request ~keeper_name:"k" "one" in
  let two = request ~keeper_name:"k" "two" in
  let three = request ~keeper_name:"k" "three" in
  let queue =
    List.fold_left
      (fun queue request ->
        match Queue.push queue ~submitted_at:42. request with
        | Ok (queue, _) -> queue
        | Error detail -> failf "push failed: %s" detail)
      Queue.empty [ one; two; three ]
  in
  (match Queue.take queue ~request_id:two.Chat.request_id with
   | None -> fail "the queue holds this request"
   | Some (taken_item, rest) ->
       let taken = taken_item.Queue.request in
       check string "the named line comes out" "two" taken.Chat.message;
       check (list string) "and the rest keeps its order" [ "one"; "three" ]
         (messages rest));
  check bool "a request the queue does not hold takes nothing" true
    (Option.is_none (Queue.take queue ~request_id:"tui-request-not-here"))
;;

(* [holds] and [take] answer about the same line: the pane asks the first to
   mark a row as waiting and the send asks the second to replace it. Two
   answers that disagreed would mark a row the send could not find. *)
let test_holds_agrees_with_take () =
  let only = request ~keeper_name:"k" "only" in
  let queue =
    match Queue.push Queue.empty ~submitted_at:42. only with
    | Ok (queue, _) -> queue
    | Error detail -> failf "push failed: %s" detail
  in
  check bool "holds says yes" true
    (Queue.holds queue ~request_id:only.Chat.request_id);
  check bool "and take agrees" true
    (Option.is_some (Queue.take queue ~request_id:only.Chat.request_id));
  check bool "holds says no for a stranger" false
    (Queue.holds queue ~request_id:"tui-request-stranger")
;;

let test_an_empty_queue_takes_nothing () =
  check bool "empty is empty" true (Queue.is_empty Queue.empty);
  check int "and has no length" 0 (Queue.length Queue.empty);
  check bool "and takes nothing" true
    (Option.is_none (Queue.take_first_sendable Queue.empty ~sendable:(fun _ -> true)))
;;

let test_submission_clock_and_per_keeper_count_are_preserved () =
  let alpha = request ~keeper_name:"alpha" "one" in
  let beta = request ~keeper_name:"beta" "two" in
  let queue =
    match Queue.push Queue.empty ~submitted_at:12.5 alpha with
    | Error detail -> fail detail
    | Ok (queue, _) ->
        (match Queue.push queue ~submitted_at:13.5 beta with
         | Error detail -> fail detail
         | Ok (queue, _) -> queue)
  in
  check int "alpha count" 1 (Queue.length_for_keeper queue ~keeper_name:"alpha");
  check int "beta count" 1 (Queue.length_for_keeper queue ~keeper_name:"beta");
  match Queue.waiting_for_keeper queue ~keeper_name:"alpha" with
  | [ item ] ->
      check (float 0.001) "first submission clock" 12.5 item.Queue.submitted_at
  | items -> failf "expected one alpha item, got %d" (List.length items)
;;

let test_steer_precedes_next_for_its_keeper () =
  let queue, _ = push_exn Queue.empty ~keeper_name:"alpha" "next one" in
  let queue, _ = push_exn queue ~keeper_name:"beta" "beta next" in
  let queue, _ = push_exn queue ~keeper_name:"alpha" "next two" in
  let steer = request ~keeper_name:"alpha" "replacement" in
  let queue =
    match
      Queue.push_steer queue ~submitted_at:99.
        ~causal_parent_request_id:"active-a" steer
    with
    | Error detail -> fail detail
    | Ok (queue, waiting) ->
        check int "three alpha items" 3 waiting;
        queue
  in
  check (list string) "alpha dispatch order"
    [ "replacement"; "next one"; "next two" ]
    (Queue.waiting_for_keeper queue ~keeper_name:"alpha"
     |> List.map (fun item -> item.Queue.request.Chat.message));
  (match Queue.take_first_sendable queue ~sendable:(fun _ -> true) with
   | Some (item, _) ->
       check string "steer dispatches first" "replacement"
         item.Queue.request.Chat.message;
       check bool "typed intent" true
         (item.Queue.intent = Queue.Steer_after_interrupt);
       check (option string) "exact causal parent" (Some "active-a")
         item.Queue.causal_parent_request_id
   | None -> fail "steer should be sendable");
  (match Queue.take_newest_for_keeper queue ~keeper_name:"alpha" with
   | Some (item, _) ->
       check string "newest means submission, not dispatch tail" "replacement"
         item.Queue.request.Chat.message
   | None -> fail "newest alpha submission should exist");
  let edited = { steer with Chat.message = "edited replacement" } in
  (match Queue.replace_request queue ~request_id:steer.request_id edited with
   | Error detail -> fail detail
   | Ok edited_queue ->
       (match Queue.find edited_queue ~request_id:steer.request_id with
        | None -> fail "edited steer disappeared"
        | Some edited_item ->
            check string "edited body" "edited replacement"
              edited_item.request.message;
            check (float 0.001) "edit keeps submission clock" 99.
              edited_item.submitted_at;
            check (option string) "edit keeps causal parent" (Some "active-a")
              edited_item.causal_parent_request_id));
  match
    Queue.push_steer queue ~submitted_at:100.
      ~causal_parent_request_id:"active-a" steer
  with
  | Ok _ -> fail "a second steer for one Keeper must be refused"
  | Error detail ->
      check bool "refusal names existing steer" true
        (Astring.String.is_infix ~affix:"already waiting" detail)
;;

let test_take_newest_for_keeper_does_not_touch_another_keeper () =
  let queue, _ = push_exn Queue.empty ~keeper_name:"alpha" "alpha one" in
  let queue, _ = push_exn queue ~keeper_name:"beta" "beta one" in
  let queue, _ = push_exn queue ~keeper_name:"alpha" "alpha two" in
  let queue, _ = push_exn queue ~keeper_name:"beta" "beta two" in
  match Queue.take_newest_for_keeper queue ~keeper_name:"alpha" with
  | None -> fail "alpha has waiting input"
  | Some (taken, rest) ->
      check string "newest alpha" "alpha two" taken.Queue.request.Chat.message;
      check (list string) "other positions survive"
        [ "alpha one"; "beta one"; "beta two" ]
        (messages rest)
;;

(* Which waiting line a newly typed one joins. The reader types a thought,
   then its correction: both are meant for one turn, and neither has been sent
   -- dispatch takes a line out of the queue -- so joining them changes what
   one turn receives, not what a turn in flight sees. *)
let join_target_cases =
  [ test_case "nothing waiting -> no target" `Quick (fun () ->
        check bool "none" true
          (Queue.join_target Queue.empty ~keeper_name:"alpha" = None))
  ; test_case "joins the last waiting line, not the first" `Quick (fun () ->
        let queue, _ = push_exn Queue.empty ~keeper_name:"alpha" "first" in
        let queue, _ = push_exn queue ~keeper_name:"alpha" "second" in
        match Queue.join_target queue ~keeper_name:"alpha" with
        | Some item -> check string "last" "second" item.Queue.request.Chat.message
        | None -> fail "expected a join target")
  ; test_case "another keeper's line is not a target" `Quick (fun () ->
        let queue, _ = push_exn Queue.empty ~keeper_name:"beta" "beta line" in
        check bool "none" true
          (Queue.join_target queue ~keeper_name:"alpha" = None))
  ]

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
        ; test_case "take removes the named line and keeps the order" `Quick
            test_take_removes_the_named_line_and_keeps_the_order
        ; test_case "holds agrees with take" `Quick test_holds_agrees_with_take
        ; test_case "nothing sendable takes nothing" `Quick
            test_nothing_sendable_takes_nothing
        ; test_case "all sendable is oldest first" `Quick
            test_all_sendable_is_oldest_first
        ; test_case "an empty queue takes nothing" `Quick
            test_an_empty_queue_takes_nothing
        ; test_case "submission clock and per-keeper count are preserved" `Quick
            test_submission_clock_and_per_keeper_count_are_preserved
        ; test_case "steer precedes next for its keeper" `Quick
            test_steer_precedes_next_for_its_keeper
        ; test_case "take newest is scoped to one Keeper" `Quick
            test_take_newest_for_keeper_does_not_touch_another_keeper
        ] )
    ; ("join_target", join_target_cases)
    ]
;;
