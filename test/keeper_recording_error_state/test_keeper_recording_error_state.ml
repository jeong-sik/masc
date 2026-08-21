open Alcotest
module S = Keeper_recording_error_state

let reset () = S.reset_for_test ()

let test_record_first_then_repeated () =
  reset ();
  let error = "opaque diagnostic text" in
  check bool "first" true (S.record ~keeper:"verifier" ~error = `First);
  check bool "second" true (S.record ~keeper:"verifier" ~error = `Repeated 2);
  check bool "third" true (S.record ~keeper:"verifier" ~error = `Repeated 3)
;;

let test_distinct_keepers_are_independent () =
  reset ();
  let error = "same exact text" in
  check bool "keeper A" true (S.record ~keeper:"A" ~error = `First);
  check bool "keeper B" true (S.record ~keeper:"B" ~error = `First);
  check int "cardinality" 2 (S.cardinality ())
;;

let test_distinct_diagnostics_are_not_classified_together () =
  reset ();
  check bool "first text" true (S.record ~keeper:"A" ~error:"auth timeout" = `First);
  check bool "second text" true (S.record ~keeper:"A" ~error:"auth timeout!" = `First);
  check int "cardinality" 2 (S.cardinality ())
;;

let test_reset_for_test_clears_state () =
  reset ();
  ignore (S.record ~keeper:"x" ~error:"y");
  check int "before reset" 1 (S.cardinality ());
  S.reset_for_test ();
  check int "after reset" 0 (S.cardinality ());
  check bool "first after reset" true (S.record ~keeper:"x" ~error:"y" = `First)
;;

let () =
  Alcotest.run
    "Keeper_recording_error_state"
    [ ( "exact occurrence state"
      , [ test_case "first then repeated" `Quick test_record_first_then_repeated
        ; test_case "keepers independent" `Quick test_distinct_keepers_are_independent
        ; test_case
            "diagnostics remain opaque"
            `Quick
            test_distinct_diagnostics_are_not_classified_together
        ; test_case "reset" `Quick test_reset_for_test_clears_state
        ] )
    ]
;;
