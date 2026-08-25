(** [Json_util.dedupe_keep_order] treats [""] as an ordinary value.

    That is worth pinning because three private near-copies existed
    beside it and two of them dropped blanks instead. One was even named
    [dedupe_keep_order] as well, in [Tool_agent], so a reader who knew
    the shared function would have been wrong about it. Those copies are
    now named for what they do, and [Voice_config] delegates here rather
    than carrying a fourth implementation.

    The variants stay private, so this suite covers the shared rule only
    — exporting them to assert on them would widen the API for the sake
    of a test. What it does cover is exactly the point they disagreed
    on: whether [""] survives. *)

open Alcotest

let strings = list string

let test_blank_is_an_ordinary_value () =
  check strings "empty string survives on its own" [ "" ]
    (Json_util.dedupe_keep_order [ "" ]);
  check strings "empty string keeps its position" [ "a"; ""; "b" ]
    (Json_util.dedupe_keep_order [ "a"; ""; "b" ]);
  check strings "repeated empties collapse like any duplicate" [ "" ]
    (Json_util.dedupe_keep_order [ ""; "" ])

let test_whitespace_is_not_trimmed () =
  check strings "a leading space makes a different value" [ " a"; "a" ]
    (Json_util.dedupe_keep_order [ " a"; "a" ]);
  check strings "whitespace-only is a value" [ "a"; " " ]
    (Json_util.dedupe_keep_order [ "a"; " " ])

let test_first_occurrence_wins () =
  check strings "later duplicates drop, order from first sighting"
    [ "b"; "a"; "c" ]
    (Json_util.dedupe_keep_order [ "b"; "a"; "b"; "c"; "a" ]);
  check strings "empty input" [] (Json_util.dedupe_keep_order [])

(* Structural equality, not string equality: the signature is ['a list]. *)
let test_works_on_non_strings () =
  check (list int) "ints dedupe structurally" [ 3; 1; 2 ]
    (Json_util.dedupe_keep_order [ 3; 1; 3; 2; 1 ]);
  check (list (pair string int)) "tuples compare structurally"
    [ ("a", 1); ("a", 2) ]
    (Json_util.dedupe_keep_order [ ("a", 1); ("a", 2); ("a", 1) ])

let () =
  run
    "dedup_rules"
    [ ( "dedupe_keep_order"
      , [ test_case "blank is an ordinary value" `Quick
            test_blank_is_an_ordinary_value
        ; test_case "whitespace is not trimmed" `Quick
            test_whitespace_is_not_trimmed
        ; test_case "first occurrence wins" `Quick test_first_occurrence_wins
        ; test_case "works on non-strings" `Quick test_works_on_non_strings
        ] )
    ]
