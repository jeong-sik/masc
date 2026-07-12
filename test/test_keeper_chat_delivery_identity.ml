open Alcotest

module Identity = Masc.Keeper_chat_delivery_identity

let expect_ok = function
  | Ok value -> value
  | Error error -> fail error
;;

let test_direct_roundtrip () =
  let request_id =
    Identity.Request_id.of_string "kmsg-direct-test" |> expect_ok
  in
  let key = Identity.Direct_request request_id in
  let decoded =
    Identity.delivery_key_to_yojson key
    |> Identity.delivery_key_of_yojson
    |> expect_ok
  in
  check bool "direct identity roundtrips" true
    (Identity.delivery_key_equal key decoded);
  check bool "filename is stable" true
    (String.equal
       (Identity.delivery_key_file_stem key)
       (Identity.delivery_key_file_stem decoded))
;;

let test_queue_requires_nonempty_receipts () =
  (match Identity.Receipt_ids.of_list [] with
   | Error Identity.Receipt_ids.Empty -> ()
   | Ok _ -> fail "empty receipt list was accepted");
  let receipt_id =
    Identity.Receipt_id.of_string
      "chatq_123e4567-e89b-12d3-a456-426614174000"
    |> expect_ok
  in
  let receipt_ids =
    Identity.Receipt_ids.of_list [ receipt_id ]
    |> Result.map_error Identity.Receipt_ids.error_to_string
    |> expect_ok
  in
  let key = Identity.Queue_receipts receipt_ids in
  let decoded =
    Identity.delivery_key_to_yojson key
    |> Identity.delivery_key_of_yojson
    |> expect_ok
  in
  check bool "queue identity roundtrips" true
    (Identity.delivery_key_equal key decoded)
;;

let test_transcript_slot_roundtrip () =
  let slots =
    [ Identity.Accepted_user
    ; Identity.Tool_call
        { execution_id = Ids.Execution_id.of_string "exec-delivery-test"
        ; ordinal = 2
        }
    ; Identity.Terminal_assistant
    ]
  in
  List.iter
    (fun slot ->
       let decoded =
         Identity.transcript_slot_to_yojson slot
         |> Identity.transcript_slot_of_yojson
         |> expect_ok
       in
       check bool "transcript slot roundtrips" true
         (Identity.transcript_slot_equal slot decoded))
    slots;
  match
    Identity.transcript_slot_of_yojson
      (`Assoc
          [ "kind", `String "tool_call"
          ; "execution_id", `String "exec-delivery-test"
          ; "ordinal", `Int (-1)
          ])
  with
  | Error _ -> ()
  | Ok _ -> fail "negative tool ordinal was accepted"
;;

let test_identity_rejects_schema_drift () =
  let reject label json decode =
    match decode json with
    | Error _ -> ()
    | Ok _ -> failf "%s was accepted" label
  in
  reject
    "unknown direct identity field"
    (`Assoc
        [ "kind", `String "direct_request"
        ; "request_id", `String "kmsg-direct-test"
        ; "legacy_id", `String "legacy"
        ])
    Identity.delivery_key_of_yojson;
  reject
    "duplicate transcript field"
    (`Assoc
        [ "kind", `String "accepted_user"
        ; "kind", `String "accepted_user"
        ])
    Identity.transcript_slot_of_yojson
;;

let () =
  run
    "keeper chat delivery identity"
    [ ( "identity"
      , [ test_case "direct roundtrip" `Quick test_direct_roundtrip
        ; test_case
            "queue identity is nonempty"
            `Quick
            test_queue_requires_nonempty_receipts
        ; test_case
            "transcript slots roundtrip"
            `Quick
            test_transcript_slot_roundtrip
        ; test_case
            "schema drift fails closed"
            `Quick
            test_identity_rejects_schema_drift
        ] )
    ]
;;
