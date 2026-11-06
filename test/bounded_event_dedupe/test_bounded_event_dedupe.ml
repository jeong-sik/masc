module D = Bounded_event_dedupe

let test_key_uses_separator () =
  Alcotest.(check bool)
    "component boundaries are preserved"
    true
    (not (String.equal (D.key [ "ab"; "c" ]) (D.key [ "a"; "bc" ])))
;;

let test_record_counts_occurrences () =
  let state = D.create () in
  (match D.record state ~key:"alpha" with
   | D.First -> ()
   | D.Repeated _ -> Alcotest.fail "first occurrence should be First");
  (match D.record state ~key:"alpha" with
   | D.Repeated 2 -> ()
   | D.First -> Alcotest.fail "second occurrence should be Repeated"
   | D.Repeated n -> Alcotest.failf "second count should be 2, got %d" n);
  Alcotest.(check int) "cardinality" 1 (D.cardinality state)
;;

let test_reset () =
  let state = D.create () in
  let _ : D.occurrence_outcome = D.record state ~key:"alpha" in
  let _ : D.occurrence_outcome = D.record state ~key:"beta" in
  Alcotest.(check int) "two keys" 2 (D.cardinality state);
  D.reset state;
  Alcotest.(check int) "reset clears all" 0 (D.cardinality state)
;;

let () =
  Alcotest.run
    "Bounded_event_dedupe"
    [ ( "state"
      , [ Alcotest.test_case "key separator" `Quick test_key_uses_separator
        ; Alcotest.test_case
            "record counts occurrences"
            `Quick
            test_record_counts_occurrences
        ; Alcotest.test_case "reset" `Quick test_reset
        ] )
    ]
;;
