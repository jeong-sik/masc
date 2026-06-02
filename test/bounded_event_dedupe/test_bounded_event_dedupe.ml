module D = Bounded_event_dedupe

let test_normalize_signature () =
  Alcotest.(check string)
    "normalizes whitespace and ASCII case"
    "error: path blocked"
    (D.normalize_signature " \tERROR:\nPath   BLOCKED  ");
  Alcotest.(check int)
    "applies byte cap"
    4
    (String.length (D.normalize_signature ~length_cap:4 "abcdef"))
;;

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
  Alcotest.(check int) "count" 2 (D.count state ~key:"alpha");
  Alcotest.(check int) "cardinality" 1 (D.cardinality state)
;;

let test_threshold_fires_once () =
  let state = D.create () in
  let threshold = 3 in
  let _ : D.threshold_outcome =
    D.record_threshold state ~key:"alpha" ~threshold
  in
  (match D.record_threshold state ~key:"alpha" ~threshold with
   | D.Repeated_threshold 2 -> ()
   | _ -> Alcotest.fail "second occurrence should be a repeat");
  (match D.record_threshold state ~key:"alpha" ~threshold with
   | D.Threshold { count = 3; threshold = 3 } -> ()
   | _ -> Alcotest.fail "third occurrence should trip threshold");
  (match D.record_threshold state ~key:"alpha" ~threshold with
   | D.Repeated_threshold 4 -> ()
   | _ -> Alcotest.fail "threshold should not fire twice");
  (match D.record_threshold state ~key:"alpha" ~threshold:5 with
   | D.Repeated_threshold 5 -> ()
   | _ -> Alcotest.fail "changed threshold should not re-fire")
;;

let test_remove_and_reset () =
  let state = D.create () in
  let _ : D.occurrence_outcome = D.record state ~key:"alpha" in
  let _ : D.occurrence_outcome = D.record state ~key:"beta" in
  D.remove state ~key:"alpha";
  Alcotest.(check int) "alpha removed" 0 (D.count state ~key:"alpha");
  Alcotest.(check int) "beta remains" 1 (D.count state ~key:"beta");
  D.reset state;
  Alcotest.(check int) "reset clears all" 0 (D.cardinality state)
;;

let () =
  Alcotest.run
    "Bounded_event_dedupe"
    [ ( "state"
      , [ Alcotest.test_case "normalize_signature" `Quick test_normalize_signature
        ; Alcotest.test_case "key separator" `Quick test_key_uses_separator
        ; Alcotest.test_case
            "record counts occurrences"
            `Quick
            test_record_counts_occurrences
        ; Alcotest.test_case "threshold fires once" `Quick test_threshold_fires_once
        ; Alcotest.test_case "remove and reset" `Quick test_remove_and_reset
        ] )
    ]
;;
