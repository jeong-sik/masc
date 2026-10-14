(* Wiki_rank: words are cut without a dictionary, and the score orders pages
   that already matched a query. *)

open Alcotest
module R = Masc.Wiki_rank

let check_terms label text expected = check (list string) label expected (R.terms text)

let test_hangul_words_become_two_character_pieces () =
  check_terms "four letters are three pieces" "정치병자" [ "정치"; "치병"; "병자" ];
  check_terms "a two letter word is one piece" "박자" [ "박자" ];
  check_terms "a lone letter is itself" "박" [ "박" ];
  check_terms "a suffix does not hide the stem" "박자가" [ "박자"; "자가" ]

let test_ascii_words_are_lowercased_and_split_on_punctuation () =
  check_terms "letters and digits" "RFC 지도" [ "rfc"; "지도" ];
  check_terms "punctuation separates" "Max, Mad, Love" [ "max"; "mad"; "love" ];
  check_terms "a symbol separates" "C# 중심" [ "c"; "중심" ];
  check_terms "digits stay with their run" "25번" [ "25"; "번" ]

let test_non_ascii_punctuation_separates () =
  check_terms "an em dash between spaces" "밤섬 — 구간" [ "밤섬"; "구간" ];
  check_terms "an em dash with no spaces" "밤섬—구간" [ "밤섬"; "구간" ];
  check_terms "an ideographic space" "밤섬\xe3\x80\x80구간" [ "밤섬"; "구간" ];
  check_terms "ascii next to hangul" "bass베이스" [ "bass"; "베이"; "이스" ]

let test_bytes_that_are_not_utf8_separate_and_never_raise () =
  check_terms "a stray byte" "\xff박자\xc3" [ "박자" ];
  check_terms "a lead byte with no tail" "\xe0\x80" [];
  check_terms "empty" "" []

(* Four mentions in a short page beat one mention in a long one. *)
let test_more_mentions_in_less_text_score_higher () =
  let scores =
    R.scores
      ~query:"박자"
      [ "박자 박자 박자 박자"
      ; "박자는 한 번 나오고 나머지는 베이스와 근음 이야기가 길게 이어져요"
      ; "베이스 근음만 있어요"
      ]
  in
  match scores with
  | [ many; once; none ] ->
    check bool "four mentions beat one" true (many > once);
    check bool "one mention beats none" true (once > 0.0);
    check (float 1e-9) "no mention scores zero" 0.0 none
  | _ -> fail "one score per text"

(* The same count in a shorter page scores higher: length is normalized. *)
let test_a_shorter_page_with_the_same_count_scores_higher () =
  let long = "박자 " ^ String.concat " " (List.init 40 (fun i -> Printf.sprintf "단어%d" i)) in
  match R.scores ~query:"박자" [ "박자"; long ] with
  | [ short; padded ] -> check bool "shorter first" true (short > padded)
  | _ -> fail "one score per text"

(* A term found in every page says little; the rare one decides the order. The
   two pages without it are the same length, so they tie. *)
let test_a_rare_term_outweighs_a_common_one () =
  match R.scores ~query:"박자 근음" [ "박자 근음"; "박자 베이스"; "박자 드럼통" ] with
  | [ both; common_a; common_b ] ->
    check bool "the page with the rare term is first" true (both > common_a);
    check (float 1e-9) "the others tie" common_a common_b
  | _ -> fail "one score per text"

(* Same length, one mention each. Only the weight of the term tells them
   apart: "근음" is in one page of four, "박자" is in three. *)
let test_a_page_with_only_the_rare_term_beats_one_with_only_the_common_term () =
  match R.scores ~query:"박자 근음" [ "근음"; "박자"; "박자 베이스"; "박자 드럼통" ] with
  | rare :: common :: _ -> check bool "the rare term weighs more" true (rare > common)
  | _ -> fail "one score per text"

let test_no_query_term_or_no_word_scores_zero () =
  let zeros label scores = check (list (float 1e-9)) label [ 0.0; 0.0 ] scores in
  zeros "an empty query" (R.scores ~query:"" [ "박자"; "근음" ]);
  zeros "a query of spaces" (R.scores ~query:"   " [ "박자"; "근음" ]);
  zeros "a corpus with no word" (R.scores ~query:"박자" [ "--"; "..." ]);
  check (list (float 1e-9)) "no texts" [] (R.scores ~query:"박자" [])

let test_scores_do_not_depend_on_text_order () =
  let texts = [ "박자 박자"; "근음 박자 베이스"; "공연 순서" ] in
  let forward = R.scores ~query:"박자" texts in
  let backward = List.rev (R.scores ~query:"박자" (List.rev texts)) in
  check (list (float 1e-9)) "same scores in either order" forward backward

let () =
  run
    "Wiki_rank"
    [ ( "terms"
      , [ test_case "hangul words become two-character pieces" `Quick test_hangul_words_become_two_character_pieces
        ; test_case "ascii words are lowercased and split on punctuation" `Quick test_ascii_words_are_lowercased_and_split_on_punctuation
        ; test_case "non-ascii punctuation separates" `Quick test_non_ascii_punctuation_separates
        ; test_case "bytes that are not utf-8 separate and never raise" `Quick test_bytes_that_are_not_utf8_separate_and_never_raise
        ] )
    ; ( "scores"
      , [ test_case "more mentions in less text score higher" `Quick test_more_mentions_in_less_text_score_higher
        ; test_case "a shorter page with the same count scores higher" `Quick test_a_shorter_page_with_the_same_count_scores_higher
        ; test_case "a rare term outweighs a common one" `Quick test_a_rare_term_outweighs_a_common_one
        ; test_case "a page with only the rare term beats one with only the common term" `Quick test_a_page_with_only_the_rare_term_beats_one_with_only_the_common_term
        ; test_case "no query term or no word scores zero" `Quick test_no_query_term_or_no_word_scores_zero
        ; test_case "scores do not depend on text order" `Quick test_scores_do_not_depend_on_text_order
        ] )
    ]
;;
