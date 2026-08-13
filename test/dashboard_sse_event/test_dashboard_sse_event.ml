let event_cases =
  [ Dashboard_sse_event.Approval_pending, "approval:pending"
  ; Dashboard_sse_event.Approval_resolved, "approval:resolved"
  ; Dashboard_sse_event.Approval_audit, "approval:audit"
  ; Dashboard_sse_event.Approval_summary_updated, "approval:summary_updated"
  ]
;;

let test_closed_wire_vocabulary () =
  List.iter
    (fun (event, expected) ->
       Alcotest.(check string)
         expected
         expected
         (Dashboard_sse_event.to_string event))
    event_cases;
  let distinct =
    event_cases
    |> List.map snd
    |> List.sort_uniq String.compare
    |> List.length
  in
  Alcotest.(check int) "wire names are unique" (List.length event_cases) distinct
;;

let test_pure_encoder_preserves_payload () =
  let payload = `Assoc [ "id", `String "appr-1" ] in
  let expected =
    `Assoc
      [ "type", `String "approval:pending"
      ; "payload", payload
      ]
  in
  Alcotest.(check (testable (Fmt.of_to_string Yojson.Safe.to_string) ( = )))
    "typed event encodes canonical type before payload"
    expected
    (Dashboard_sse_event.encode Dashboard_sse_event.Approval_pending ~payload)
;;

let () =
  Alcotest.run
    "dashboard_sse_event"
    [ ( "closed_sum"
      , [ Alcotest.test_case "wire vocabulary" `Quick test_closed_wire_vocabulary
        ; Alcotest.test_case "pure encoder" `Quick test_pure_encoder_preserves_payload
        ] )
    ]
;;
