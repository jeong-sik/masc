(** Tests for {!Masc.Keeper_decoded_rows}: the decoded lines of a store are
    kept between reads, only appended bytes are decoded, and what is kept
    stays within the byte budget by dropping the stores read longest ago. *)

open Alcotest

module Decoded = Masc.Keeper_decoded_rows

(* A decoder that records what it was asked to decode. Each line becomes a
   fresh string, so a kept line is told from a decoded-again one by [==]. *)
type decoder =
  { decode : after:int -> string -> (int * string) list
  ; asked : unit -> (int * string) list
  }

let decoder () =
  let asked = ref [] in
  let decode ~after bytes =
    asked := (after, bytes) :: !asked;
    String.split_on_char '\n' bytes
    |> List.filter (fun line -> line <> "")
    |> List.mapi (fun index line -> after + index + 1, String.uppercase_ascii line)
  in
  { decode; asked = (fun () -> List.rev !asked) }
;;

let asked_t = list (pair int string)
let lines_t = list (pair int string)

let read cache decoder ~path rows = Decoded.lines cache ~path ~rows ~decode:decoder.decode

let test_only_appended_bytes_are_decoded () =
  let cache = Decoded.create ~budget_bytes:1024 in
  let decoder = decoder () in
  let first = read cache decoder ~path:"a" "one\ntwo\n" in
  check lines_t "every line is decoded on the first read" [ 1, "ONE"; 2, "TWO" ] first;
  let again = read cache decoder ~path:"a" "one\ntwo\n" in
  check bool "the same bytes answer with the lines already decoded" true
    (List.for_all2 ( == ) first again);
  let grown = read cache decoder ~path:"a" "one\ntwo\nthree\n" in
  check lines_t "the appended line follows the kept ones" [ 1, "ONE"; 2, "TWO"; 3, "THREE" ] grown;
  check bool "the kept lines are the values already built" true
    (List.for_all2 ( == ) first (List.filteri (fun index _ -> index < 2) grown));
  check asked_t "the decoder saw the whole store once and then the appended bytes"
    [ 0, "one\ntwo\n"; 2, "three\n" ]
    (decoder.asked ())
;;

let test_other_bytes_are_decoded_whole () =
  let cache = Decoded.create ~budget_bytes:1024 in
  let decoder = decoder () in
  let (_ : (int * string) list) = read cache decoder ~path:"a" "one\ntwo\n" in
  let rewritten = read cache decoder ~path:"a" "uno\n" in
  check lines_t "a store written again is numbered from one" [ 1, "UNO" ] rewritten;
  let (_ : (int * string) list) = read cache decoder ~path:"b" "one\ntwo\n" in
  check asked_t "neither a rewrite nor another path reuses the kept lines"
    [ 0, "one\ntwo\n"; 0, "uno\n"; 0, "one\ntwo\n" ]
    (decoder.asked ())
;;

let test_forgotten_store_is_decoded_again () =
  let cache = Decoded.create ~budget_bytes:1024 in
  let decoder = decoder () in
  let (_ : (int * string) list) = read cache decoder ~path:"a" "one\n" in
  check int "the store's bytes are kept" 4 (Decoded.kept_bytes cache);
  Decoded.forget cache ~path:"a";
  check int "a forgotten store keeps nothing" 0 (Decoded.kept_bytes cache);
  Decoded.forget cache ~path:"a";
  check int "forgetting it again changes nothing" 0 (Decoded.kept_bytes cache);
  let (_ : (int * string) list) = read cache decoder ~path:"a" "one\n" in
  check asked_t "its next read decodes it whole" [ 0, "one\n"; 0, "one\n" ] (decoder.asked ())
;;

(* Three stores of four bytes under a budget of eight: the one read longest
   ago goes, and reading a store again makes it the newest. *)
let test_store_read_longest_ago_is_dropped () =
  let cache = Decoded.create ~budget_bytes:8 in
  let decoder = decoder () in
  let read path = read cache decoder ~path "row\n" in
  let (_ : (int * string) list) = read "a" in
  let (_ : (int * string) list) = read "b" in
  let (_ : (int * string) list) = read "a" in
  let (_ : (int * string) list) = read "c" in
  check int "what is kept fits the budget" 8 (Decoded.kept_bytes cache);
  let asked_before = List.length (decoder.asked ()) in
  let (_ : (int * string) list) = read "a" in
  check int "the store read again before the third one is still kept" asked_before
    (List.length (decoder.asked ()));
  let (_ : (int * string) list) = read "b" in
  check int "the store read longest ago was dropped and is decoded again" (asked_before + 1)
    (List.length (decoder.asked ()))
;;

let test_store_over_the_budget_is_not_kept () =
  let cache = Decoded.create ~budget_bytes:8 in
  let decoder = decoder () in
  let (_ : (int * string) list) = read cache decoder ~path:"small" "row\n" in
  let large = read cache decoder ~path:"large" "a long row\n" in
  check lines_t "it is still decoded" [ 1, "A LONG ROW" ] large;
  check int "and only the store that fits is kept" 4 (Decoded.kept_bytes cache)
;;

(* Keepers that are made, read and purged one after another, each under its
   own path, and a reader that answers after its store was forgotten. *)
let test_many_paths_stay_within_the_budget () =
  let budget_bytes = 12 in
  let cache = Decoded.create ~budget_bytes in
  let decoder = decoder () in
  for index = 1 to 200 do
    let path = Printf.sprintf "keeper-%d" index in
    let (_ : (int * string) list) = read cache decoder ~path "row\n" in
    check bool "the kept bytes never pass the budget" true (Decoded.kept_bytes cache <= budget_bytes)
  done;
  Decoded.forget cache ~path:"keeper-200";
  let (_ : (int * string) list) = read cache decoder ~path:"keeper-200" "row\n" in
  check bool "a read that answers after the store was forgotten is within the budget too" true
    (Decoded.kept_bytes cache <= budget_bytes);
  Decoded.forget cache ~path:"keeper-200";
  check int "and the next forget drops it" 8 (Decoded.kept_bytes cache)
;;

let test_negative_budget_is_refused () =
  check_raises "a negative budget is a programming error"
    (Invalid_argument "Keeper_decoded_rows.create: budget_bytes is negative")
    (fun () -> ignore (Decoded.create ~budget_bytes:(-1) : string Decoded.t))
;;

let () =
  run
    "keeper_decoded_rows"
    [ ( "kept lines"
      , [ test_case "only appended bytes are decoded" `Quick test_only_appended_bytes_are_decoded
        ; test_case "other bytes are decoded whole" `Quick test_other_bytes_are_decoded_whole
        ; test_case "a forgotten store is decoded again" `Quick
            test_forgotten_store_is_decoded_again
        ] )
    ; ( "budget"
      , [ test_case "the store read longest ago is dropped" `Quick
            test_store_read_longest_ago_is_dropped
        ; test_case "a store over the budget is not kept" `Quick
            test_store_over_the_budget_is_not_kept
        ; test_case "many paths stay within the budget" `Quick
            test_many_paths_stay_within_the_budget
        ; test_case "a negative budget is refused" `Quick test_negative_budget_is_refused
        ] )
    ]
;;
