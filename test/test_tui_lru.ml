(* What the bounded store keeps and what it drops.

   The chat pane reads from this once per message it walks, so the two things
   that matter are that a lookup never returns something older than what was
   stored under that key, and that reading from a value keeps it: a pane
   walking the same messages every frame must not evict the answers it is
   about to ask for again. *)

module Lru = Masc_tui_lru

open Alcotest

let test_a_stored_value_comes_back () =
  let store = Lru.create ~capacity:4 in
  Lru.set store "a" 1;
  Lru.set store "b" 2;
  check (option int) "a" (Some 1) (Lru.find store "a");
  check (option int) "b" (Some 2) (Lru.find store "b");
  check (option int) "never stored" None (Lru.find store "c");
  check int "two values" 2 (Lru.size store)
;;

let test_a_key_takes_its_new_value_without_taking_a_second_place () =
  let store = Lru.create ~capacity:4 in
  Lru.set store "a" 1;
  Lru.set store "a" 9;
  check (option int) "the newer value" (Some 9) (Lru.find store "a");
  check int "one value" 1 (Lru.size store)
;;

let test_the_least_recently_used_value_is_the_one_dropped () =
  let store = Lru.create ~capacity:2 in
  Lru.set store "a" 1;
  Lru.set store "b" 2;
  (* Reading from a is what makes b the older of the two. *)
  ignore (Lru.find store "a" : int option);
  Lru.set store "c" 3;
  check (option int) "b was dropped" None (Lru.find store "b");
  check (option int) "a was read from and stayed" (Some 1) (Lru.find store "a");
  check (option int) "c is here" (Some 3) (Lru.find store "c");
  check int "the bound holds" 2 (Lru.size store)
;;

let test_a_rewritten_key_becomes_the_newest () =
  let store = Lru.create ~capacity:2 in
  Lru.set store "a" 1;
  Lru.set store "b" 2;
  Lru.set store "a" 11;
  Lru.set store "c" 3;
  check (option int) "b was the oldest" None (Lru.find store "b");
  check (option int) "a was rewritten and stayed" (Some 11) (Lru.find store "a")
;;

let test_the_order_reads_newest_first () =
  let store = Lru.create ~capacity:3 in
  Lru.set store "a" 1;
  Lru.set store "b" 2;
  Lru.set store "c" 3;
  ignore (Lru.find store "a" : int option);
  check (list string) "a was just read" [ "a"; "c"; "b" ] (Lru.keys_newest_first store)
;;

let test_a_store_of_one_holds_the_newest () =
  let store = Lru.create ~capacity:1 in
  Lru.set store "a" 1;
  Lru.set store "b" 2;
  check (option int) "a went" None (Lru.find store "a");
  check (option int) "b stayed" (Some 2) (Lru.find store "b");
  check int "one value" 1 (Lru.size store)
;;

let test_a_store_cannot_be_empty_by_construction () =
  check bool "zero is refused" true
    (try
       ignore (Lru.create ~capacity:0 : (string, int) Lru.t);
       false
     with Invalid_argument _ -> true)
;;

let test_a_long_walk_keeps_what_it_walked () =
  (* The pane's case: walk a thousand messages, then walk them again. The
     second walk finds every one of them. *)
  let store = Lru.create ~capacity:1024 in
  for index = 1 to 1000 do
    Lru.set store index (index * 2)
  done;
  let missing =
    List.filter
      (fun index -> Option.is_none (Lru.find store index))
      (List.init 1000 (fun index -> index + 1))
  in
  check (list int) "nothing was dropped" [] missing;
  check int "and the store holds them" 1000 (Lru.size store)
;;

let test_a_walk_past_the_bound_drops_where_it_started () =
  let store = Lru.create ~capacity:100 in
  for index = 1 to 300 do
    Lru.set store index index
  done;
  check (option int) "the first is gone" None (Lru.find store 1);
  check (option int) "the last is here" (Some 300) (Lru.find store 300);
  check int "the bound holds" 100 (Lru.size store)
;;

let () =
  Alcotest.run
    "tui lru"
    [ ( "store",
        [ Alcotest.test_case "a stored value comes back" `Quick
            test_a_stored_value_comes_back;
          Alcotest.test_case "a key takes its new value without a second place"
            `Quick test_a_key_takes_its_new_value_without_taking_a_second_place;
          Alcotest.test_case "the least recently used value is dropped" `Quick
            test_the_least_recently_used_value_is_the_one_dropped;
          Alcotest.test_case "a rewritten key becomes the newest" `Quick
            test_a_rewritten_key_becomes_the_newest;
          Alcotest.test_case "the order reads newest first" `Quick
            test_the_order_reads_newest_first;
          Alcotest.test_case "a store of one holds the newest" `Quick
            test_a_store_of_one_holds_the_newest;
          Alcotest.test_case "a store cannot be empty by construction" `Quick
            test_a_store_cannot_be_empty_by_construction;
          Alcotest.test_case "a long walk keeps what it walked" `Quick
            test_a_long_walk_keeps_what_it_walked;
          Alcotest.test_case "a walk past the bound drops where it started"
            `Quick test_a_walk_past_the_bound_drops_where_it_started
        ] )
    ]
;;
