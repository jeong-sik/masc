module AR = Masc.Task.Anti_rationalization

let unmet ~notes ~contract = AR.check_contract ~notes ~contract

let check_unmet label expected actual =
  Alcotest.(check (list string)) label expected actual

let test_snake_case_fallback_accepts_nearby_word_sequence () =
  check_unmet
    "snake_case contract is met by nearby words"
    []
    (unmet
       ~notes:"we now record synthetic backpressure counters in server logs"
       ~contract:[ "record_synthetic_backpressure" ])

let test_snake_case_fallback_requires_word_boundaries () =
  check_unmet
    "substring-only token matches stay unmet"
    [ "record_synthetic_backpressure" ]
    (unmet
       ~notes:"pre-recorded nonsynthetic backpressure evidence"
       ~contract:[ "record_synthetic_backpressure" ])

let test_space_phrase_contracts_remain_literal () =
  check_unmet
    "space-separated phrase contracts are not bag-of-words"
    [ "run tests" ]
    (unmet
       ~notes:"I did not run the app; tests are still pending"
       ~contract:[ "run tests" ])

let test_snake_case_fallback_requires_proximity () =
  check_unmet
    "distant unrelated token mentions stay unmet"
    [ "record_synthetic_backpressure" ]
    (unmet
       ~notes:"record metrics now; synthetic suite skipped; backpressure remains unhandled"
       ~contract:[ "record_synthetic_backpressure" ])

let test_snake_case_fallback_rejects_intervening_negation () =
  check_unmet
    "negated near-phrase stays unmet"
    [ "record_synthetic_backpressure" ]
    (unmet
       ~notes:"we record no synthetic backpressure counters"
       ~contract:[ "record_synthetic_backpressure" ])

let () =
  Alcotest.run
    "anti_rationalization_contract_fallback"
    [ ( "check_contract"
      , [ Alcotest.test_case
            "snake_case accepts nearby words"
            `Quick
            test_snake_case_fallback_accepts_nearby_word_sequence
        ; Alcotest.test_case
            "snake_case requires word boundaries"
            `Quick
            test_snake_case_fallback_requires_word_boundaries
        ; Alcotest.test_case
            "space phrase stays literal"
            `Quick
            test_space_phrase_contracts_remain_literal
        ; Alcotest.test_case
            "snake_case requires proximity"
            `Quick
            test_snake_case_fallback_requires_proximity
        ; Alcotest.test_case
            "snake_case rejects intervening negation"
            `Quick
            test_snake_case_fallback_rejects_intervening_negation
        ] )
    ]
