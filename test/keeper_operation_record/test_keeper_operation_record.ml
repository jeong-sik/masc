module Record = Keeper_operation_record

type event = { sequence : int }

type event_error =
  | Expected_event_object
  | Unknown_event_field of string
  | Duplicate_sequence
  | Missing_sequence
  | Invalid_sequence

let encode_event event = `Assoc [ "sequence", `Int event.sequence ]

let decode_event = function
  | `Assoc fields ->
    (match
       List.find_opt
         (fun (name, _) -> not (String.equal name "sequence"))
         fields
     with
     | Some (name, _) -> Error (Unknown_event_field name)
     | None ->
       (match List.filter (fun (name, _) -> String.equal name "sequence") fields with
        | [] -> Error Missing_sequence
        | [ _, `Int sequence ] -> Ok { sequence }
        | [ _ ] -> Error Invalid_sequence
        | _ -> Error Duplicate_sequence))
  | _ -> Error Expected_event_object
;;

let ok = function
  | Ok value -> value
  | Error _ -> Alcotest.fail "fixture construction failed"
;;

let encode ~recorded_at event =
  Record.encode ~encode_event ~recorded_at event
;;

let decode_rows ~from ~row_number bytes =
  Record.decode_rows ~decode_event ~from ~row_number bytes
;;

let jsonl json = Yojson.Safe.to_string json ^ "\n"

let expect_envelope_issue expected bytes =
  match decode_rows ~from:Record.Cursor.zero ~row_number:(Some 4) bytes with
  | Error { row_number = Some 4; issue = Record.Invalid_envelope actual; _ }
    when expected actual ->
    ()
  | _ -> Alcotest.fail "unexpected envelope result"
;;

let test_roundtrip_and_cursor () =
  let first = ok (encode ~recorded_at:(-1.25) { sequence = 7 }) in
  let second = ok (encode ~recorded_at:2.5 { sequence = 8 }) in
  let from = ok (Record.Cursor.of_int 17) in
  match decode_rows ~from ~row_number:(Some 4) (first ^ second) with
  | Ok [ left; right ] ->
    Alcotest.(check int) "first event" 7 left.event.sequence;
    Alcotest.(check int) "second event" 8 right.event.sequence;
    Alcotest.(check (float 0.0)) "first timestamp" (-1.25) left.recorded_at;
    Alcotest.(check int) "first start" 17 (Record.Cursor.to_int left.start_cursor);
    Alcotest.(check int)
      "first end"
      (17 + String.length first)
      (Record.Cursor.to_int left.end_cursor);
    Alcotest.(check int)
      "second end"
      (17 + String.length first + String.length second)
      (Record.Cursor.to_int right.end_cursor)
  | _ -> Alcotest.fail "canonical rows did not decode"
;;

let test_cursor_rejects_negative () =
  match Record.Cursor.of_int (-1) with
  | Error (Record.Cursor.Negative (-1)) -> ()
  | _ -> Alcotest.fail "negative cursor accepted"
;;

let test_closed_envelope () =
  let event = encode_event { sequence = 1 } in
  expect_envelope_issue
    (function
      | Record.Unknown_field "extra" -> true
      | _ -> false)
    (jsonl
       (`Assoc
          [ "recorded_at", `Float 1.0
          ; "event", event
          ; "extra", `Null
          ]));
  expect_envelope_issue
    (function
      | Record.Duplicate_field "event" -> true
      | _ -> false)
    (jsonl
       (`Assoc
          [ "recorded_at", `Float 1.0
          ; "event", event
          ; "event", event
          ]));
  expect_envelope_issue
    (function
      | Record.Missing_field "event" -> true
      | _ -> false)
    (jsonl (`Assoc [ "recorded_at", `Float 1.0 ]))
;;

let test_invalid_event_is_preserved () =
  let bytes =
    jsonl
      (`Assoc
         [ "recorded_at", `Float 1.0
         ; "event", `Assoc [ "future", `Int 1 ]
         ])
  in
  expect_envelope_issue
    (function
      | Record.Invalid_event (Unknown_event_field "future") -> true
      | _ -> false)
    bytes
;;

let test_incomplete_tail () =
  match
    decode_rows
      ~from:(ok (Record.Cursor.of_int 8))
      ~row_number:None
      "{}"
  with
  | Error
      { row_number = None
      ; start_cursor
      ; end_cursor
      ; issue = Record.Incomplete_tail
      } ->
    Alcotest.(check int) "start" 8 (Record.Cursor.to_int start_cursor);
    Alcotest.(check int) "end" 10 (Record.Cursor.to_int end_cursor)
  | _ -> Alcotest.fail "incomplete tail was accepted"
;;

let test_malformed_json () =
  match decode_rows ~from:Record.Cursor.zero ~row_number:(Some 9) "{]\n" with
  | Error
      { row_number = Some 9
      ; start_cursor
      ; end_cursor
      ; issue = Record.Malformed_json _
      } ->
    Alcotest.(check int) "start" 0 (Record.Cursor.to_int start_cursor);
    Alcotest.(check int) "end" 3 (Record.Cursor.to_int end_cursor)
  | _ -> Alcotest.fail "malformed JSON was accepted"
;;

let test_non_finite_time () =
  List.iter
    (fun recorded_at ->
       match encode ~recorded_at { sequence = 1 } with
       | Error Record.Non_finite_recorded_at -> ()
       | _ -> Alcotest.fail "non-finite timestamp encoded")
    [ Float.nan; Float.infinity; Float.neg_infinity ];
  expect_envelope_issue
    (function
      | Record.Invalid_recorded_at -> true
      | _ -> false)
    (jsonl
       (`Assoc
          [ "recorded_at", `String "not-a-number"
          ; "event", encode_event { sequence = 1 }
          ]))
;;

let () =
  Alcotest.run
    "keeper operation record"
    [ ( "record"
      , [ Alcotest.test_case "roundtrip and cursor" `Quick test_roundtrip_and_cursor
        ; Alcotest.test_case "negative cursor" `Quick test_cursor_rejects_negative
        ; Alcotest.test_case "closed envelope" `Quick test_closed_envelope
        ; Alcotest.test_case "invalid event" `Quick test_invalid_event_is_preserved
        ; Alcotest.test_case "incomplete tail" `Quick test_incomplete_tail
        ; Alcotest.test_case "malformed JSON" `Quick test_malformed_json
        ; Alcotest.test_case "finite time" `Quick test_non_finite_time
        ] )
    ]
;;
