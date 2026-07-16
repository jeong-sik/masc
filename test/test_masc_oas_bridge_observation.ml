open Masc

let require_clockless () =
  match Masc_eio_env.get_opt () with
  | None -> ()
  | Some _ -> Alcotest.fail "test requires an uninitialized Masc_eio_env"
;;

let test_clockless_execution () =
  require_clockless ();
  match
    Masc_oas_bridge.run_safe ~caller:Masc_oas_bridge.Anti_rationalization (fun () ->
      Ok "clockless")
  with
  | Ok value -> Alcotest.(check string) "body result" "clockless" value
  | Error error -> Alcotest.fail (Agent_sdk.Error.to_string error)
;;

let test_inner_timeout_observation () =
  require_clockless ();
  match
    Masc_oas_bridge.run_safe ~caller:Masc_oas_bridge.Operator_judge (fun () ->
      raise Eio.Time.Timeout)
  with
  | Error (Agent_sdk.Error.Api (Agent_sdk.Retry.Timeout _)) -> ()
  | Error error -> Alcotest.fail (Agent_sdk.Error.to_string error)
  | Ok _ -> Alcotest.fail "inner timeout returned success"
;;

let test_structured_cancellation_reraise () =
  require_clockless ();
  match
    try
      Masc_oas_bridge.run_safe ~caller:Masc_oas_bridge.Operator_judge (fun () ->
        raise (Eio.Cancel.Cancelled (Failure "bridge-cancel")))
      |> ignore;
      None
    with
    | Eio.Cancel.Cancelled inner -> Some inner
  with
  | Some (Failure message) -> Alcotest.(check string) "inner cause" "bridge-cancel" message
  | Some exn -> Alcotest.fail (Printexc.to_string exn)
  | None -> Alcotest.fail "structured cancellation was swallowed"
;;

let test_exception_isolation () =
  require_clockless ();
  match
    Masc_oas_bridge.run_safe ~caller:Masc_oas_bridge.Operator_judge (fun () ->
      raise Exit)
  with
  | Error error ->
    (match Keeper_internal_error.classify_masc_internal_error error with
     | Some (Keeper_internal_error.Internal_bridge_exception { caller; _ }) ->
       Alcotest.(check string) "typed caller" "operator_judge" caller
     | Some other ->
       Alcotest.fail (Keeper_internal_error.kind_of_masc_internal_error other)
     | None -> Alcotest.fail (Agent_sdk.Error.to_string error))
  | Ok _ -> Alcotest.fail "unexpected exception escaped as success"
;;

let () =
  Alcotest.run
    "masc_oas_bridge_observation"
    [ ( "boundary"
      , [ Alcotest.test_case "clockless execution" `Quick test_clockless_execution
        ; Alcotest.test_case "inner timeout" `Quick test_inner_timeout_observation
        ; Alcotest.test_case
            "structured cancellation"
            `Quick
            test_structured_cancellation_reraise
        ; Alcotest.test_case "typed exception isolation" `Quick test_exception_isolation
        ] )
    ]
;;
