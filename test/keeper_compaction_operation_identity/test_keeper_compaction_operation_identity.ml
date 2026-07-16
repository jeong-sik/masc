module Identity = Keeper_compaction_operation_identity

let canonical_uuid = "123e4567-e89b-12d3-a456-426614174000"

let test_typed_ids () =
  let parse parse value =
    match parse value with
    | Ok id -> id
    | Error Identity.Invalid_canonical_uuid -> Alcotest.fail "canonical UUID rejected"
  in
  let operation = parse Identity.Operation_id.of_string canonical_uuid in
  let attempt = parse Identity.Attempt_id.of_string canonical_uuid in
  Alcotest.(check string)
    "operation projection"
    canonical_uuid
    (Identity.Operation_id.to_string operation);
  Alcotest.(check string)
    "attempt projection"
    canonical_uuid
    (Identity.Attempt_id.to_string attempt);
  let generated_operation = Identity.Operation_id.generate () in
  let next_operation = Identity.Operation_id.generate () in
  Alcotest.(check bool)
    "fresh operation ids differ"
    false
    (Identity.Operation_id.equal generated_operation next_operation);
  (match
     Identity.Operation_id.of_string
       (Identity.Operation_id.to_string generated_operation)
   with
   | Ok restored ->
     Alcotest.(check bool)
       "generated operation is canonical"
       true
       (Identity.Operation_id.equal generated_operation restored)
   | Error _ -> Alcotest.fail "generated operation id did not parse");
  List.iter
    (fun value ->
       match Identity.Operation_id.of_string value with
       | Error Identity.Invalid_canonical_uuid -> ()
       | Ok _ -> Alcotest.failf "noncanonical UUID accepted: %S" value)
    [ String.uppercase_ascii canonical_uuid; "not-a-uuid"; " " ^ canonical_uuid ]
;;

let test_cause () =
  let open Identity.Cause in
  (match of_string "provider context overflow" with
   | Ok cause ->
     Alcotest.(check string) "exact projection" "provider context overflow" (to_string cause)
   | Error _ -> Alcotest.fail "canonical cause rejected");
  List.iter
    (fun (value, expected) ->
       match of_string value with
       | Error actual -> Alcotest.(check bool) value true (actual = expected)
       | Ok _ -> Alcotest.failf "invalid cause accepted: %S" value)
    [ "", Empty; " padded", Noncanonical; "padded ", Noncanonical ]
;;

let () =
  Alcotest.run
    "keeper compaction operation identity"
    [ ( "identity"
      , [ Alcotest.test_case "canonical typed UUIDs" `Quick test_typed_ids
        ; Alcotest.test_case "canonical cause" `Quick test_cause
        ] )
    ]
