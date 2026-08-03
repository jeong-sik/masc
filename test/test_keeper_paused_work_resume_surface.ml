open Alcotest
open Masc

module Surface = Server_dashboard_http_keeper_api_post.For_testing

let require_ok label = function
  | Ok value -> value
  | Error error -> failf "%s: %s" label error
;;

let test_single_resume_requires_operation_id () =
  let action_only = `Assoc [ "action", `String "resume" ] in
  (match Surface.parse_resume_request action_only with
   | Error _ -> ()
   | Ok _ -> fail "resume without operation ID was accepted");
  let parsed =
    Surface.parse_resume_request
      (`Assoc
         [ "action", `String "resume"
         ; "operator_operation_id", `String "dashboard-resume-7"
         ])
    |> require_ok "parse resume operation ID"
  in
  check string "operation ID" "dashboard-resume-7" parsed
;;

let test_bulk_resume_requires_operation_ids () =
  let names_only =
    `Assoc
      [ "action", `String "resume"
      ; "names", `List [ `String "rondo"; `String "qa-king" ]
      ]
  in
  (match Surface.parse_bulk_resume_requests names_only with
   | Error _ -> ()
   | Ok _ -> fail "bulk resume without targets was accepted");
  let parsed =
    Surface.parse_bulk_resume_requests
      (`Assoc
         [ "action", `String "resume"
         ; ( "targets"
           , `List
               [ `Assoc
                   [ "name", `String "rondo"
                   ; "operator_operation_id", `String "resume-rondo-1"
                   ]
               ; `Assoc
                   [ "name", `String "qa-king"
                   ; "operator_operation_id", `String "resume-qa-1"
                   ]
               ] )
         ])
    |> require_ok "parse bulk Resume_owner"
  in
  check
    (list (pair string string))
    "resume operation IDs"
    [ "rondo", "resume-rondo-1"; "qa-king", "resume-qa-1" ]
    parsed
;;

let () =
  run
    "keeper paused-work resume surface"
    [ ( "resume request contract"
      , [ test_case
            "single requires operation id"
            `Quick
            test_single_resume_requires_operation_id
        ; test_case
            "bulk requires operation IDs"
            `Quick
            test_bulk_resume_requires_operation_ids
        ] )
    ]
;;
