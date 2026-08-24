let check_json label expected actual =
  Alcotest.(check bool) label true (Yojson.Safe.equal expected actual)
;;

let test_snapshot_protocol () =
  let snapshot =
    Masc.Snapshot_protocol.respond
      ~revision:"backlog:7"
      ~if_revision:None
      (`List [ `String "task-1" ])
  in
  check_json
    "snapshot"
    (`Assoc
       [ "kind", `String "snapshot"
       ; "revision", `String "backlog:7"
       ; "snapshot", `List [ `String "task-1" ]
       ])
    (Masc.Snapshot_protocol.to_yojson snapshot);
  let unchanged =
    Masc.Snapshot_protocol.respond
      ~revision:"backlog:7"
      ~if_revision:(Some "backlog:7")
      (`List [ `String "task-1" ])
  in
  check_json
    "unchanged"
    (`Assoc [ "kind", `String "unchanged"; "revision", `String "backlog:7" ])
    (Masc.Snapshot_protocol.to_yojson unchanged);
  (match Masc.Snapshot_protocol.if_revision `Null with
   | Ok None -> ()
   | Ok (Some _) -> Alcotest.fail "null arguments produced a revision"
   | Error message -> Alcotest.fail message);
  let revision_a =
    Masc.Snapshot_protocol.revision_of_json
      ~namespace:"test"
      (`Assoc [ "b", `Int 2; "a", `Int 1 ])
  in
  let revision_b =
    Masc.Snapshot_protocol.revision_of_json
      ~namespace:"test"
      (`Assoc [ "a", `Int 1; "b", `Int 2 ])
  in
  Alcotest.(check string) "object key order does not change revision" revision_a revision_b;
  Alcotest.(check bool)
    "revision uses sha256"
    true
    (String.length revision_a = String.length "test:" + 64);
  (match Masc.Snapshot_protocol.if_revision
           (`Assoc [ "if_revision", `String " " ]) with
   | Error message ->
     Alcotest.(check string)
       "blank if_revision is rejected"
       "if_revision must not be blank"
       message
   | Ok _ -> Alcotest.fail "blank if_revision was accepted")
;;

let test_unchanged_snapshot_preserves_deferred_disposition () =
  let result =
    Masc.Keeper_tool_execution.deferred_data (`String "approval required")
  in
  let response = Masc.Snapshot_protocol.Unchanged { revision = "board:7" } in
  let projected =
    Masc.Keeper_tool_board_runtime.For_testing.snapshot_execution_of_response
      result
      response
  in
  (match projected.disposition with
   | Tool_result.Deferred () -> ()
   | Tool_result.Completed () -> Alcotest.fail "unchanged response completed a deferral"
   | Tool_result.Failed _ -> Alcotest.fail "unchanged response replaced the deferral");
  match projected.data with
  | Some data ->
    check_json
      "unchanged deferred payload"
      (`Assoc [ "kind", `String "unchanged"; "revision", `String "board:7" ])
      data
  | None -> Alcotest.fail "unchanged deferred response lost its payload"
;;

let test_unchanged_snapshot_defers_completed_producer () =
  let result = Masc.Keeper_tool_execution.success_data (`String "board snapshot") in
  let response = Masc.Snapshot_protocol.Unchanged { revision = "board:8" } in
  let projected =
    Masc.Keeper_tool_board_runtime.For_testing.snapshot_execution_of_response
      result
      response
  in
  (match projected.disposition with
   | Tool_result.Deferred () -> ()
   | Tool_result.Completed () ->
     Alcotest.fail "unchanged response completed a polling read"
   | Tool_result.Failed _ ->
     Alcotest.fail "unchanged response failed a completed producer");
  match projected.data with
  | Some data ->
    check_json
      "unchanged completed-producer payload"
      (`Assoc [ "kind", `String "unchanged"; "revision", `String "board:8" ])
      data
  | None -> Alcotest.fail "unchanged completed-producer response lost its payload"
;;

let () =
  Alcotest.run
    "keeper efficiency protocol"
    [ ( "snapshot protocol"
      , [ Alcotest.test_case "snapshot and unchanged" `Quick test_snapshot_protocol
        ; Alcotest.test_case
            "unchanged preserves deferred disposition"
            `Quick
            test_unchanged_snapshot_preserves_deferred_disposition
        ; Alcotest.test_case
            "unchanged defers a completed producer"
            `Quick
            test_unchanged_snapshot_defers_completed_producer
        ] ) ]
;;
