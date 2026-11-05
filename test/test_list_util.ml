open Alcotest

let ints = list int
let strip = List_util.strip_prefix ~equal:Int.equal

let test_strip_prefix_keeps_what_follows () =
  check (option ints) "an empty prefix keeps the whole list" (Some [ 1; 2 ]) (strip [] [ 1; 2 ]);
  check (option ints) "the elements after the prefix" (Some [ 3 ]) (strip [ 1; 2 ] [ 1; 2; 3 ]);
  check (option ints) "a list equal to the prefix leaves nothing" (Some []) (strip [ 1; 2 ] [ 1; 2 ]);
  check (option ints) "the empty list starts the empty list" (Some []) (strip [] [])
;;

let test_strip_prefix_refuses_a_list_that_does_not_start_with_it () =
  check (option ints) "a prefix longer than the list" None (strip [ 1; 2; 3 ] [ 1; 2 ]);
  check (option ints) "a different element in the middle" None (strip [ 1; 3 ] [ 1; 2; 3 ]);
  check (option ints) "a later run is not a prefix" None (strip [ 2 ] [ 1; 2 ]);
  check (option ints) "a prefix of something from nothing" None (strip [ 1 ] [])
;;

(* The stdlib way to say the same thing: cut the list to the prefix's length and
   compare. *)
let by_cutting prefix xs =
  let length = List.length prefix in
  if List.equal Int.equal prefix (List.take length xs)
  then Some (List.drop length xs)
  else None
;;

let every_list_up_to_four_elements =
  let rec of_length = function
    | 0 -> [ [] ]
    | n -> List.concat_map (fun xs -> [ 0 :: xs; 1 :: xs ]) (of_length (n - 1))
  in
  List.concat_map of_length [ 0; 1; 2; 3; 4 ]
;;

let test_both_agree_with_cutting_on_every_short_list () =
  List.iter
    (fun prefix ->
       List.iter
         (fun xs ->
            let expected = by_cutting prefix xs in
            let name =
              Printf.sprintf
                "[%s] against [%s]"
                (String.concat ";" (List.map string_of_int prefix))
                (String.concat ";" (List.map string_of_int xs))
            in
            check (option ints) ("strip_prefix " ^ name) expected (strip prefix xs);
            check
              bool
              ("is_prefix " ^ name)
              (Option.is_some expected)
              (List_util.is_prefix ~equal:Int.equal prefix xs))
         every_list_up_to_four_elements)
    every_list_up_to_four_elements
;;

let test_the_lists_may_hold_different_types () =
  let named_by id (name, _) = String.equal id name in
  let rows = [ "a", 1; "b", 2; "c", 3 ] in
  check bool "ids against rows" true (List_util.is_prefix ~equal:named_by [ "a"; "b" ] rows);
  check bool "an id out of order" false (List_util.is_prefix ~equal:named_by [ "b" ] rows);
  check
    (option (list (pair string int)))
    "the rows after the ids"
    (Some [ "c", 3 ])
    (List_util.strip_prefix ~equal:named_by [ "a"; "b" ] rows)
;;

let test_the_caller_decides_when_two_elements_are_equal () =
  let same_ignoring_case a b =
    String.equal (String.lowercase_ascii a) (String.lowercase_ascii b)
  in
  check
    bool
    "case ignored"
    true
    (List_util.is_prefix ~equal:same_ignoring_case [ "A"; "b" ] [ "a"; "B"; "c" ]);
  check bool "case kept" false (List_util.is_prefix ~equal:String.equal [ "A"; "b" ] [ "a"; "B"; "c" ])
;;

let () =
  run
    "list_util"
    [ ( "strip_prefix"
      , [ test_case "keeps what follows the prefix" `Quick test_strip_prefix_keeps_what_follows
        ; test_case
            "refuses a list that does not start with it"
            `Quick
            test_strip_prefix_refuses_a_list_that_does_not_start_with_it
        ] )
    ; ( "against the stdlib"
      , [ test_case
            "strip_prefix and is_prefix agree with cutting, on every short list"
            `Quick
            test_both_agree_with_cutting_on_every_short_list
        ] )
    ; ( "element types"
      , [ test_case "the lists may hold different types" `Quick test_the_lists_may_hold_different_types
        ; test_case
            "the caller decides when two elements are equal"
            `Quick
            test_the_caller_decides_when_two_elements_are_equal
        ] )
    ]
;;
