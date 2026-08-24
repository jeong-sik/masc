(* The two matchers behind the [:] palette and the [/] roster search.

   Both are pure, and both were shipped without a test. They also share an
   unstated contract: each lowercases the haystack itself and expects the
   caller to have lowercased the needle. All three call sites do
   (masc_tui_types.palette_matches, masc_tui.roster_search_jump, and the n/N
   repeat beside it), so the contract holds today -- these cases pin it so a
   fourth caller that forgets is a failure here rather than a search box that
   quietly finds nothing. *)

open Masc_tui_types

let check_bool = Alcotest.(check bool)

let test_contains_is_a_substring_over_a_lowercased_haystack () =
  check_bool "plain substring" true (palette_contains ~needle:"adm" "keeper adm-race");
  check_bool "haystack case is ignored" true
    (palette_contains ~needle:"adm" "Keeper ADM-race");
  check_bool "absent substring" false (palette_contains ~needle:"zzz" "keeper adm-race");
  check_bool "empty needle matches anything" true (palette_contains ~needle:"" "anything");
  check_bool "needle longer than haystack" false (palette_contains ~needle:"keeper" "kee")
;;

let test_subsequence_takes_the_characters_in_order () =
  (* The comment on the function names this exact case. *)
  check_bool "kadm finds keeper adm-race" true
    (palette_subsequence ~needle:"kadm" "keeper adm-race");
  check_bool "order matters" false
    (palette_subsequence ~needle:"mdak" "keeper adm-race");
  check_bool "a substring is also a subsequence" true
    (palette_subsequence ~needle:"adm" "keeper adm-race");
  check_bool "empty needle matches anything" true
    (palette_subsequence ~needle:"" "anything");
  check_bool "a character the haystack lacks" false
    (palette_subsequence ~needle:"kz" "keeper adm-race")
;;

let test_the_caller_owns_the_needle_case () =
  (* Not a nicety: an uppercase needle reaches the comparison unchanged and
     matches nothing, because the haystack is already lowercase by then. The
     three call sites lowercase before calling. *)
  check_bool "uppercase needle finds nothing in contains" false
    (palette_contains ~needle:"ADM" "keeper adm-race");
  check_bool "uppercase needle finds nothing in subsequence" false
    (palette_subsequence ~needle:"KADM" "keeper adm-race")
;;

let () =
  Alcotest.run
    "masc-tui-palette-matching"
    [ ( "matchers"
      , [ Alcotest.test_case "contains is a substring over a lowercased haystack" `Quick
            test_contains_is_a_substring_over_a_lowercased_haystack
        ; Alcotest.test_case "subsequence takes the characters in order" `Quick
            test_subsequence_takes_the_characters_in_order
        ; Alcotest.test_case "the caller owns the needle case" `Quick
            test_the_caller_owns_the_needle_case
        ] )
    ]
;;
