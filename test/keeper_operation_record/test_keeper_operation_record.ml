module Operation = Keeper_compaction_operation
module Event = Keeper_operation_event
module Record = Keeper_operation_record

let ok = function
  | Ok value -> value
  | Error _ -> Alcotest.fail "fixture construction failed"
;;

let checkpoint_option_equal left right =
  match left, right with
  | None, None -> true
  | Some left, Some right -> Keeper_checkpoint_ref.equal left right
  | None, Some _ | Some _, None -> false
;;

let keeper_name = ok (Keeper_id.Keeper_name.of_string "record-keeper")
let trace_id = ok (Keeper_id.Trace_id.of_string "record-trace")
let cause = ok (Operation.Cause.of_string "manual compaction")

let source =
  ok
    (Keeper_checkpoint_ref.create
       ~trace_id
       ~generation:1
       ~turn_count:3
       ~canonical_checkpoint_bytes:"source")
;;

let event =
  let operation_id =
    ok
      (Operation.Operation_id.of_string
         "00000000-0000-4000-8000-000000000001")
  in
  Operation.requested
    ~operation_id
    ~keeper_name
    ~source_checkpoint:source
    ~trigger:Compaction_trigger.Manual
    ~cause
    ~producer:None
;;

let journal_event event = Event.Compaction event

let test_roundtrip_and_cursor () =
  let encoded =
    ok (Record.encode ~recorded_at:(-1.25) (journal_event event))
  in
  let from = ok (Record.Cursor.of_int 17) in
  match Record.decode_rows ~from ~row_number:None encoded with
  | Ok [ row ] ->
    Alcotest.(check (float 0.0)) "timestamp" (-1.25) row.recorded_at;
    Alcotest.(check int) "start" 17 (Record.Cursor.to_int row.start_cursor);
    Alcotest.(check int)
      "newline end"
      (17 + String.length encoded)
      (Record.Cursor.to_int row.end_cursor);
    (match row.event with
     | Event.Compaction actual ->
       Alcotest.(check bool)
         "operation identity"
         true
         (Operation.Operation_id.equal
            (Operation.operation_id actual)
            (Operation.operation_id event));
       (match Operation.view actual with
        | Operation.Requested request ->
          Alcotest.(check bool) "keeper" true
            (Keeper_id.Keeper_name.equal keeper_name request.keeper_name);
          Alcotest.(check bool) "exact source" true
            (Keeper_checkpoint_ref.equal source request.source_checkpoint);
          Alcotest.(check bool) "cause" true
            (Operation.Cause.equal cause request.cause);
          (match request.trigger, request.producer with
           | Compaction_trigger.Manual, None -> ()
           | _ -> Alcotest.fail "typed request facts changed")
        | _ -> Alcotest.fail "compaction event kind changed"))
  | _ -> Alcotest.fail "canonical row did not decode"
;;

let test_closed_envelope_and_finite_time () =
  (match Record.encode ~recorded_at:Float.nan (journal_event event) with
   | Error Record.Invalid_recorded_at -> ()
   | _ -> Alcotest.fail "non-finite timestamp encoded");
  let canonical = ok (Record.encode ~recorded_at:1.0 (journal_event event)) in
  let malformed =
    String.sub canonical 0 (String.length canonical - 2)
    ^ ",\"extra\":null}\n"
  in
  match Record.decode_rows ~from:Record.Cursor.zero ~row_number:(Some 1) malformed with
  | Error
      { row_number = Some 1
      ; issue = Record.Invalid_envelope (Record.Unknown_field "extra")
      ; _
      } ->
    ()
  | _ -> Alcotest.fail "unknown envelope field was accepted"
;;

let test_unknown_domain_is_explicit () =
  let unknown =
    "{\"recorded_at\":1.0,\"domain\":\"future\",\"event\":null}\n"
  in
  match Record.decode_rows ~from:Record.Cursor.zero ~row_number:(Some 1) unknown with
  | Error
      { row_number = Some 1
      ; issue = Record.Invalid_envelope (Record.Unknown_domain "future")
      ; _
      } ->
    ()
  | _ -> Alcotest.fail "unknown operation domain was not rejected explicitly"
;;

let test_incomplete_tail_is_located () =
  match
    Record.decode_rows
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

let test_superseded_roundtrip () =
  let attempt_id =
    ok
      (Operation.Attempt_id.of_string
         "00000000-0000-4000-8000-000000000011")
  in
  List.iter
    (fun observed_checkpoint ->
       let superseded =
         Operation.source_superseded
           ~operation_id:(Operation.operation_id event)
           ~attempt_id
           ~observed_checkpoint
       in
       let encoded =
         ok (Record.encode ~recorded_at:1.0 (journal_event superseded))
       in
       match Record.decode_rows ~from:Record.Cursor.zero ~row_number:(Some 1) encoded with
       | Ok [ row ] ->
         (match row.event with
          | Event.Compaction actual ->
            (match Operation.view actual with
             | Operation.Source_superseded actual ->
               Alcotest.(check bool)
                 "exact optional checkpoint"
                 true
                 (checkpoint_option_equal
                    actual.observed_checkpoint
                    observed_checkpoint)
             | _ -> Alcotest.fail "supersession kind changed"))
       | _ -> Alcotest.fail "supersession did not roundtrip")
    [ None; Some source ]
;;

let () =
  Alcotest.run
    "keeper operation record"
    [ ( "record"
      , [ Alcotest.test_case "roundtrip and cursor" `Quick test_roundtrip_and_cursor
        ; Alcotest.test_case "closed envelope" `Quick test_closed_envelope_and_finite_time
        ; Alcotest.test_case "unknown domain" `Quick test_unknown_domain_is_explicit
        ; Alcotest.test_case "incomplete tail" `Quick test_incomplete_tail_is_located
        ; Alcotest.test_case "superseded roundtrip" `Quick test_superseded_roundtrip
        ] )
    ]
;;
