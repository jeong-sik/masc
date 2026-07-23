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
         ; "owner_nonce", `Int 7
         ; "operator_operation_id", `String "dashboard-resume-7"
         ])
    |> require_ok "parse exact Resume_owner"
  in
  check (pair int string) "exact fences" (7, "dashboard-resume-7") parsed
;;

let test_bulk_resume_requires_per_owner_targets () =
  let names_only =
    `Assoc
      [ "action", `String "resume"
      ; "names", `List [ `String "rondo"; `String "qa-king" ]
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
                   [ "name", `String "rondo"
                   ; "owner_nonce", `Int 3
                   ; "operator_operation_id", `String "resume-rondo-1"
                   ]
               ; `Assoc
                   [ "name", `String "qa-king"
                   ; "owner_nonce", `Int 5
                   ; "operator_operation_id", `String "resume-qa-1"
                   ]
               ] )
         ])
    |> require_ok "parse bulk Resume_owner"
  in
  check
    (list (triple string int string))
    "per-owner fences"
    [ "rondo", 3, "resume-rondo-1"; "qa-king", 5, "resume-qa-1" ]
    parsed
;;

let test_legacy_owner_generation_key_is_accepted () =
  (* Regression (#25599): pre-rename dashboard clients send the fencing counter
     as ["owner_generation"]. During the deprecation window both keys are
     accepted; the new ["owner_nonce"] key wins when a request carries both. *)
  let legacy =
    Surface.parse_resume_request
      (`Assoc
         [ "action", `String "resume"
         ; "owner_generation", `Int 7
         ; "operator_operation_id", `String "dashboard-resume-legacy-7"
         ])
    |> require_ok "parse legacy-key Resume_owner"
  in
  check (pair int string) "legacy key fences" (7, "dashboard-resume-legacy-7") legacy;
  let both_keys =
    Surface.parse_resume_request
      (`Assoc
         [ "action", `String "resume"
         ; "owner_generation", `Int 99
         ; "owner_nonce", `Int 7
         ; "operator_operation_id", `String "dashboard-resume-both-7"
         ])
    |> require_ok "parse both-keys Resume_owner"
  in
  check
    (pair int string)
    "owner_nonce wins over legacy owner_generation"
    (7, "dashboard-resume-both-7")
    both_keys
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
        ; test_case
            "legacy owner_generation key is accepted"
            `Quick
            test_legacy_owner_generation_key_is_accepted
        ] )
    ]
;;
