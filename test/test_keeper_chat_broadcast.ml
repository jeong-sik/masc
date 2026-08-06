module B = Masc.Keeper_chat_broadcast

let yojson_testable =
  Alcotest.testable
    (fun fmt json -> Format.fprintf fmt "%s" (Yojson.Safe.to_string json))
    ( = )

let fields_without_ts_unix json =
  match json with
  | `Assoc fields ->
      (match List.assoc_opt "ts_unix" fields with
       | Some (`Float _) -> ()
       | _ -> Alcotest.fail "ts_unix missing or not a float");
      List.remove_assoc "ts_unix" fields
  | _ -> Alcotest.fail "expected assoc payload"

let test_tool_call_started_payload () =
  let json =
    B.turn_progress_to_json ~keeper_name:"taskmaster" ~run_id:"run-1"
      ~kind:B.Tool_call_started ~tool_call_id:"tc-1" ~tool_name:(Some "Grep")
      ~receipt_ids:[ "chatq-1"; "chatq-2" ]
  in
  Alcotest.(check (list (pair string yojson_testable)))
    "start payload"
    [ ("type", `String "keeper_chat_turn_progress")
    ; ("name", `String "taskmaster")
    ; ("run_id", `String "run-1")
    ; ("kind", `String "tool_call_start")
    ; ("tool_call_id", `String "tc-1")
    ; ("tool_name", `String "Grep")
    ; ("receipt_ids", `List [ `String "chatq-1"; `String "chatq-2" ])
    ]
    (fields_without_ts_unix json)

let test_tool_call_ended_payload () =
  let json =
    B.turn_progress_to_json ~keeper_name:"taskmaster" ~run_id:"run-1"
      ~kind:B.Tool_call_ended ~tool_call_id:"tc-1" ~tool_name:None
      ~receipt_ids:[]
  in
  Alcotest.(check (list (pair string yojson_testable)))
    "end payload omits tool_name and empty receipt_ids"
    [ ("type", `String "keeper_chat_turn_progress")
    ; ("name", `String "taskmaster")
    ; ("run_id", `String "run-1")
    ; ("kind", `String "tool_call_end")
    ; ("tool_call_id", `String "tc-1")
    ]
    (fields_without_ts_unix json)

let () =
  Alcotest.run "keeper_chat_broadcast"
    [ ( "turn_progress"
      , [ Alcotest.test_case "tool_call_start payload" `Quick
            test_tool_call_started_payload
        ; Alcotest.test_case "tool_call_end payload" `Quick
            test_tool_call_ended_payload
        ] )
    ]
