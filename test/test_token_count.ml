(** Phantom-typed token count tests (RFC-0149 §3.2 PR-1). *)

open Alcotest

module Token_count = Masc_mcp.Token_count

let result_pp ppf = function
  | `Saved n -> Format.fprintf ppf "`Saved %d" n
  | `Divergent n -> Format.fprintf ppf "`Divergent %d" n

let result_eq a b =
  match a, b with
  | `Saved x, `Saved y -> x = y
  | `Divergent x, `Divergent y -> x = y
  | _ -> false

let saved_t = testable result_pp result_eq

let saved_when_post_smaller () =
  let pre = Token_count.pre_estimate 1000 in
  let post = Token_count.post_recount 200 in
  check saved_t "post < pre yields Saved" (`Saved 800)
    (Token_count.saved ~pre ~post)

let saved_zero_when_equal () =
  let pre = Token_count.pre_estimate 500 in
  let post = Token_count.post_recount 500 in
  check saved_t "post = pre yields Saved 0" (`Saved 0)
    (Token_count.saved ~pre ~post)

let divergent_when_post_bigger () =
  let pre = Token_count.pre_estimate 300 in
  let post = Token_count.post_recount 500 in
  check saved_t "post > pre yields Divergent" (`Divergent 200)
    (Token_count.saved ~pre ~post)

let negative_input_clamps_to_zero () =
  let pre = Token_count.pre_estimate (-100) in
  let post = Token_count.post_recount (-50) in
  check int "pre clamped to 0" 0 (Token_count.to_int pre);
  check int "post clamped to 0" 0 (Token_count.to_int post);
  check saved_t "0 vs 0 yields Saved 0" (`Saved 0)
    (Token_count.saved ~pre ~post)

let to_int_preserves_value () =
  let pre = Token_count.pre_estimate 1234 in
  check int "to_int round-trips constructor input" 1234
    (Token_count.to_int pre)

let () =
  run "token_count"
    [ ( "saved variant"
      , [ test_case "post smaller -> Saved" `Quick saved_when_post_smaller
        ; test_case "post equal -> Saved 0" `Quick saved_zero_when_equal
        ; test_case "post bigger -> Divergent" `Quick
            divergent_when_post_bigger
        ] )
    ; ( "construction"
      , [ test_case "negative inputs clamp to zero" `Quick
            negative_input_clamps_to_zero
        ; test_case "to_int round-trips" `Quick to_int_preserves_value
        ] )
    ]
