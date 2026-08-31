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
    (Identity.delivery_key_equal key decoded)
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
    (Identity.delivery_key_equal key (Identity.Operation request_id))
;;

let test_approval_lifecycle_roundtrip () =
  let approval_id =
    Identity.Request_id.of_string "appr_01typed" |> expect_ok
  in
  let key = Identity.Approval_lifecycle approval_id in
  let decoded =
    Identity.delivery_key_to_yojson key
    |> Identity.delivery_key_of_yojson
    |> expect_ok
  in
  check bool "approval lifecycle identity roundtrips" true
    (Identity.delivery_key_equal key decoded)
;;

let test_transcript_slot_roundtrip () =
  let slots =
    [ Identity.Accepted_user
    ; Identity.Tool_call
        { execution_id = Ids.Execution_id.of_string "exec-delivery-test"
        ; ordinal = 2
        }
    ; Identity.Tool_delivery { ordinal = 3 }
    ; Identity.Terminal_assistant
    ; Identity.Approval_resolution
    ; Identity.Approval_replay
    ; Identity.Approval_continuation
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

let test_tool_delivery_rejects_execution_identity () =
  match
    Identity.transcript_slot_of_yojson
      (`Assoc
          [ "kind", `String "tool_delivery"
          ; "execution_id", `String "provider-call"
          ; "ordinal", `Int 0
          ])
  with
  | Error _ -> ()
  | Ok _ -> fail "a delivery-only slot accepted an execution identity"
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

(* The pair invariant lives in the decoder, so both durable readers inherit
   it. Half a pair answers no question: a key without a slot cannot say
   which row of the delivery it is, a slot without a key belongs to no
   delivery. *)
let test_provenance_pair_is_all_or_nothing () =
  let request_id = Identity.Request_id.of_string "kmsg-pair-test" |> expect_ok in
  let provenance =
    { Identity.delivery_key = Identity.Operation request_id
    ; transcript_slot = Identity.Accepted_user
    }
  in
  let fields = Identity.delivery_provenance_fields provenance in
  check int "the pair writes exactly two fields" 2 (List.length fields);
  (match Identity.delivery_provenance_of_fields fields with
   | Ok (Some decoded) ->
     check bool "the pair roundtrips" true
       (Identity.delivery_provenance_equal provenance decoded)
   | Ok None -> fail "a written pair decoded as absent"
   | Error error -> fail error);
  (match Identity.delivery_provenance_of_fields [ "id", `String "msg-1" ] with
   | Ok None -> ()
   | Ok (Some _) -> fail "a row with neither field decoded as present"
   | Error error -> failf "a row with neither field was rejected: %s" error);
  let reject label fields =
    match Identity.delivery_provenance_of_fields fields with
    | Error _ -> ()
    | Ok _ -> failf "%s was accepted" label
  in
  reject
    "delivery_key without transcript_slot"
    (List.filter (fun (name, _) -> name = "delivery_key") fields);
  reject
    "transcript_slot without delivery_key"
    (List.filter (fun (name, _) -> name = "transcript_slot") fields);
  reject
    "pair carrying an undecodable delivery_key"
    [ "delivery_key", `Assoc [ "kind", `String "direct_request" ]
    ; "transcript_slot", Identity.transcript_slot_to_yojson Identity.Accepted_user
    ]
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
            "approval lifecycle roundtrip"
            `Quick
            test_approval_lifecycle_roundtrip
        ; test_case
            "transcript slots roundtrip"
            `Quick
            test_transcript_slot_roundtrip
        ; test_case
            "schema drift fails closed"
            `Quick
            test_identity_rejects_schema_drift
        ; test_case
            "delivery-only slot rejects execution identity"
            `Quick
            test_tool_delivery_rejects_execution_identity
        ; test_case
            "provenance pair is all or nothing"
            `Quick
            test_provenance_pair_is_all_or_nothing
        ] )
    ]
;;
