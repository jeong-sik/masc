(* Seats of official client accounts: one number per account, one scheduler
   per account while the server runs (RFC exact-lane-walks-one-slot-list
   section 3.6). The published table lives for the whole process, so each
   case names its own accounts. *)

open Alcotest
module Seats = Runtime_official_client_seats
module Slot_scheduler = Llm_provider.Slot_scheduler

let declared provider_id runtime_id max_concurrent : Seats.declaration =
  { runtime_id; provider_id; max_concurrent }
;;

let published declarations =
  match Seats.of_declarations declarations with
  | Ok published -> published
  | Error (_ : Seats.disagreement list) -> fail "agreeing declarations were refused"
;;

let max_slots ~provider_id =
  match Seats.scheduler ~provider_id with
  | Some scheduler -> Some (Slot_scheduler.snapshot scheduler).Slot_scheduler.max_slots
  | None -> None
;;

let test_runtimes_of_one_account_that_agree_publish_one_scheduler () =
  Seats.publish
    (published
       [ declared "agree_a" "agree_a.sonnet" 2
       ; declared "agree_b" "agree_b.sonnet" 3
       ; declared "agree_a" "agree_a.haiku" 2
       ]);
  check (option int) "account a" (Some 2) (max_slots ~provider_id:"agree_a");
  check (option int) "account b" (Some 3) (max_slots ~provider_id:"agree_b");
  check (option int) "an account no publish named" None (max_slots ~provider_id:"agree_none")
;;

let test_runtimes_of_one_account_that_disagree_are_named () =
  match
    Seats.of_declarations
      [ declared "disagree_a" "disagree_a.sonnet" 2
      ; declared "disagree_b" "disagree_b.sonnet" 1
      ; declared "disagree_a" "disagree_a.haiku" 4
      ; declared "disagree_b" "disagree_b.haiku" 1
      ]
  with
  | Ok (_ : Seats.published) -> fail "one account declaring two numbers was published"
  | Error disagreements ->
    check
      (list (pair string (list (pair string int))))
      "only the disagreeing account, each runtime with its number"
      [ "disagree_a", [ "disagree_a.sonnet", 2; "disagree_a.haiku", 4 ] ]
      (List.map
         (fun (disagreement : Seats.disagreement) ->
            disagreement.account, disagreement.declarations)
         disagreements)
;;

(* A new number reconfigures the account's scheduler instead of replacing it,
   so a seat taken before goes back to the scheduler that counts it. *)
let test_a_new_number_reconfigures_the_same_scheduler () =
  Seats.publish (published [ declared "renumber_a" "renumber_a.sonnet" 1 ]);
  let before =
    match Seats.scheduler ~provider_id:"renumber_a" with
    | Some scheduler -> scheduler
    | None -> fail "the published account has no scheduler"
  in
  check bool "a seat is free" true (Slot_scheduler.try_acquire before);
  Seats.publish (published [ declared "renumber_a" "renumber_a.sonnet" 3 ]);
  (match Seats.scheduler ~provider_id:"renumber_a" with
   | Some after -> check bool "the same scheduler" true (after == before)
   | None -> fail "the account lost its scheduler");
  check (option int) "the new number" (Some 3) (max_slots ~provider_id:"renumber_a");
  Slot_scheduler.release before;
  check
    int
    "the seat taken before went back"
    0
    (Slot_scheduler.snapshot before).Slot_scheduler.active
;;

let test_an_account_left_out_keeps_its_scheduler () =
  Seats.publish (published [ declared "kept_a" "kept_a.sonnet" 2 ]);
  Seats.publish (published [ declared "kept_b" "kept_b.sonnet" 1 ]);
  check (option int) "the account left out" (Some 2) (max_slots ~provider_id:"kept_a");
  check (option int) "the account published" (Some 1) (max_slots ~provider_id:"kept_b")
;;

let () =
  run
    "runtime_official_client_seats"
    [ ( "official client seats"
      , [ test_case
            "runtimes of one account that agree publish one scheduler"
            `Quick
            test_runtimes_of_one_account_that_agree_publish_one_scheduler
        ; test_case
            "runtimes of one account that disagree are named"
            `Quick
            test_runtimes_of_one_account_that_disagree_are_named
        ; test_case
            "a new number reconfigures the same scheduler"
            `Quick
            test_a_new_number_reconfigures_the_same_scheduler
        ; test_case
            "an account left out keeps its scheduler"
            `Quick
            test_an_account_left_out_keeps_its_scheduler
        ] )
    ]
;;
