(** [Keeper_runtime_instructions.text_equal] decides whether a Keeper's
    instructions drifted between the TOML and the persisted meta. It must
    read the whole text: three live Keepers carry instructions of 4.5-11 KB,
    and an edit past the first few kilobytes is still an edit. *)

open Masc

let equal = Alcotest.(check bool)

(* 1,400 Hangul syllables: 4,200 bytes in UTF-8, past any byte cap a
   comparison might once have applied, while still one short paragraph of
   Korean instructions. *)
let long_prefix = String.concat "" (List.init 1400 (fun _ -> "가"))

let test_edit_past_four_kilobytes_is_drift () =
  let before = long_prefix ^ " 리뷰 요청에는 답하지 않는다." in
  let after = long_prefix ^ " 리뷰 요청에는 반드시 답한다." in
  equal "same prefix, different tail: not equal" false
    (Keeper_runtime_instructions.text_equal before after)
;;

let test_identical_long_text_is_not_drift () =
  let text = long_prefix ^ " 리뷰 요청에는 답하지 않는다." in
  equal "identical: equal" true (Keeper_runtime_instructions.text_equal text text)
;;

let test_surrounding_whitespace_is_not_drift () =
  equal "leading/trailing whitespace: equal" true
    (Keeper_runtime_instructions.text_equal "  판을 읽는다.\n" "판을 읽는다.")
;;

let test_interior_whitespace_is_drift () =
  equal "interior whitespace: not equal" false
    (Keeper_runtime_instructions.text_equal "판을 읽는다." "판을  읽는다.")
;;

let test_empty_and_blank_are_equal () =
  equal "empty vs blank: equal" true (Keeper_runtime_instructions.text_equal "" " \n")
;;

let () =
  Alcotest.run
    "keeper_runtime_instructions"
    [ ( "text_equal"
      , [ Alcotest.test_case "an edit past four kilobytes is drift" `Quick
            test_edit_past_four_kilobytes_is_drift
        ; Alcotest.test_case "identical long text is not drift" `Quick
            test_identical_long_text_is_not_drift
        ; Alcotest.test_case "surrounding whitespace is not drift" `Quick
            test_surrounding_whitespace_is_not_drift
        ; Alcotest.test_case "interior whitespace is drift" `Quick
            test_interior_whitespace_is_drift
        ; Alcotest.test_case "empty and blank are equal" `Quick
            test_empty_and_blank_are_equal
        ] )
    ]
;;
