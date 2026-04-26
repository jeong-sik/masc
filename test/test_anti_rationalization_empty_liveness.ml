(** Ratchet: [Anti_rationalization.review] treats an empty evaluator
    response as "evaluator unavailable" (approve by liveness) rather
    than rejecting the completing keeper.

    35 rejections in 2 days on 2026-04-17/18 (#8688,
    ~/me/.masc/tool_calls) surfaced where the evaluator returned an
    empty text block; the gate rejected the keeper with
    "review format unrecognized: empty review output" even though
    the keeper had no role in the evaluator's failure.

    This test pins the precondition — [parse_verdict ""] MUST return
    exactly [Error "empty review output"] — so the matcher branch in
    [review] continues to trigger the liveness-approve path. If
    [parse_verdict] starts returning a different error string for
    empty input, the branch silently falls through to [Format_reject]
    again and this assertion surfaces the regression. *)

module AR = Masc_mcp.Anti_rationalization

let test_empty_verdict_emits_canonical_error () =
  match AR.parse_verdict "" with
  | Error msg ->
    Alcotest.(check string)
      "empty text gives canonical 'empty review output' error"
      "empty review output"
      msg
  | Ok _ -> Alcotest.fail "parse_verdict \"\" should return Error"
;;

let test_whitespace_only_verdict_also_empty () =
  match AR.parse_verdict "   \n\t  " with
  | Error msg ->
    Alcotest.(check string)
      "whitespace-only text trims to empty"
      "empty review output"
      msg
  | Ok _ -> Alcotest.fail "parse_verdict of whitespace should return Error"
;;

let () =
  Alcotest.run
    "anti_rationalization_empty_liveness"
    [ ( "parse_verdict empty precondition"
      , [ Alcotest.test_case
            "exactly empty"
            `Quick
            test_empty_verdict_emits_canonical_error
        ; Alcotest.test_case
            "whitespace-only"
            `Quick
            test_whitespace_only_verdict_also_empty
        ] )
    ]
;;
