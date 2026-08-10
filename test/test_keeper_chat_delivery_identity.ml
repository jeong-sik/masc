open Alcotest

module Identity = Keeper_chat_delivery_identity

let expect_ok = function
  | Ok value -> value
  | Error error -> fail error
;;

let test_operation_roundtrip () =
  let request_id =
    Identity.Request_id.of_string "kmsg-direct-test" |> expect_ok
  in
  let key = Identity.Operation request_id in
  let decoded =
    Identity.delivery_key_to_yojson key
    |> Identity.delivery_key_of_yojson
    |> expect_ok
  in
  check bool "operation identity roundtrips" true
    (Identity.delivery_key_equal key decoded);
  check bool "filename is stable" true
    (String.equal
       (Identity.delivery_key_file_stem key)
       (Identity.delivery_key_file_stem decoded))
;;

let test_fusion_roundtrip () =
  let request_id =
    Identity.Request_id.of_string "fus-async-test" |> expect_ok
  in
  let key = Identity.Fusion_run request_id in
  let decoded =
    Identity.delivery_key_to_yojson key
    |> Identity.delivery_key_of_yojson
    |> expect_ok
  in
  check bool "Fusion identity roundtrips" true
    (Identity.delivery_key_equal key decoded);
  check bool "Fusion namespace differs from operation" false
    (Identity.delivery_key_equal key (Identity.Operation request_id));
  check bool "Fusion filename namespace is stable" true
    (String.equal
       (Identity.delivery_key_file_stem key)
       (Identity.delivery_key_file_stem decoded))
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
    "unknown delivery identity"
    (`Assoc
        [ "kind", `String "unknown"
        ; "operation_id", `String "kmsg-unknown-test"
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
      , [ test_case "operation roundtrip" `Quick test_operation_roundtrip
        ; test_case
            "Fusion run roundtrip"
            `Quick
            test_fusion_roundtrip
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
