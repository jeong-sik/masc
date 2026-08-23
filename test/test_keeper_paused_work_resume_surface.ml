open Alcotest
open Masc

module Surface = Server_dashboard_http_keeper_api_post.For_testing

let require_ok label = function
  | Ok value -> value
  | Error error -> failf "%s: %s" label error
;;

let test_single_resume_requires_exact_fences () =
  let action_only = `Assoc [ "action", `String "resume" ] in
  (match Surface.parse_resume_request action_only with
   | Error _ -> ()
   | Ok _ -> fail "action-only resume was accepted");
  let parsed =
    Surface.parse_resume_request
      (`Assoc
         [ "action", `String "resume"
         ; "operator_operation_id", `String "dashboard-resume-7"
         ])
    |> require_ok "parse exact Resume_owner"
  in
  check string "exact fences" "dashboard-resume-7" parsed
;;

let test_bulk_resume_requires_per_owner_targets () =
  let names_only =
    `Assoc
      [ "action", `String "resume"
      ; "names", `List [ `String "beta"; `String "mu-king" ]
      ]
  in
  (match Surface.parse_bulk_resume_requests names_only with
   | Error _ -> ()
   | Ok _ -> fail "names-only bulk resume was accepted");
  let parsed =
    Surface.parse_bulk_resume_requests
      (`Assoc
         [ "action", `String "resume"
         ; ( "targets"
           , `List
               [ `Assoc
                   [ "name", `String "beta"
                   ; "owner_nonce", `Int 3
                   ; "operator_operation_id", `String "resume-beta-1"
                   ]
               ; `Assoc
                   [ "name", `String "mu-king"
                   ; "owner_nonce", `Int 5
                   ; "operator_operation_id", `String "resume-qa-1"
                   ]
               ] )
         ])
    |> require_ok "parse bulk Resume_owner"
  in
  check
    (list (pair string string))
    "per-owner fences"
    [ "beta", "resume-beta-1"; "mu-king", "resume-qa-1" ]
    parsed
;;

let () =
  run
    "keeper paused-work resume surface"
    [ ( "resume request contract"
      , [ test_case
            "single requires generation and operation id"
            `Quick
            test_single_resume_requires_exact_fences
        ; test_case
            "bulk requires per-owner targets"
            `Quick
            test_bulk_resume_requires_per_owner_targets
        ] )
    ]
;;
