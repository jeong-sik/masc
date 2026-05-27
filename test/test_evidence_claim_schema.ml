(** Schema round-trip tests for [Evidence_claim] (RFC-0199 Phase A).

    Locks the yojson serialization for the 6 closed-sum variants and
    confirms unknown variants fail (closed-sum guarantee). Also pins
    [to_human_string] to compact one-line form so transition events
    stay diff-friendly. *)

open Alcotest
module EC = Masc_mcp.Evidence_claim

let check_claim = check (testable EC.pp EC.equal)

let round_trip (c : EC.t) =
  match EC.to_yojson c |> EC.of_yojson with
  | Ok parsed -> check_claim "round-trip" c parsed
  | Error e -> fail (Printf.sprintf "of_yojson failed: %s" e)

let test_round_trip_pr_merged () =
  round_trip (EC.PR_merged { repo = "owner/repo"; pr_number = 1234 })

let test_round_trip_ci_pass () =
  round_trip (EC.CI_pass { repo = "owner/repo"; pr_number = 1234 })

let test_round_trip_tests_pass () =
  round_trip (EC.Tests_pass { command = "dune build @runtest"; expected_exit = 0 })

let test_round_trip_artifact_exists_min_bytes () =
  round_trip (EC.Artifact_exists { path = "build/out.json"; min_bytes = Some 1024 })

let test_round_trip_artifact_exists_no_min () =
  round_trip (EC.Artifact_exists { path = "build/out.json"; min_bytes = None })

let test_round_trip_file_changed () =
  round_trip (EC.File_changed { path = "src/main.ml"; min_bytes = Some 10 })

let test_round_trip_custom_check () =
  round_trip
    (EC.Custom_check
       { id = "lint_clean"; payload = `Assoc [ ("warnings", `Int 0) ] })

let test_unknown_variant_rejected () =
  let bogus = `List [ `String "Made_up_variant"; `Assoc [] ] in
  match EC.of_yojson bogus with
  | Ok _ -> fail "of_yojson accepted unknown variant — closed sum violated"
  | Error _ -> ()

let test_human_string_compact () =
  let claim = EC.PR_merged { repo = "jeong-sik/masc-mcp"; pr_number = 19108 } in
  let s = EC.to_human_string claim in
  check string "compact" "pr_merged(jeong-sik/masc-mcp#19108)" s

let test_human_string_no_newline () =
  let claims =
    [ EC.PR_merged { repo = "r"; pr_number = 1 }
    ; EC.CI_pass { repo = "r"; pr_number = 1 }
    ; EC.Tests_pass { command = "cmd"; expected_exit = 0 }
    ; EC.Artifact_exists { path = "p"; min_bytes = None }
    ; EC.File_changed { path = "p"; min_bytes = Some 10 }
    ; EC.Custom_check { id = "x"; payload = `Null }
    ]
  in
  List.iter
    (fun c ->
      let s = EC.to_human_string c in
      if String.contains s '\n' then
        fail (Printf.sprintf "to_human_string emitted newline: %S" s))
    claims

let () =
  Alcotest.run
    "evidence_claim_schema"
    [ ( "round_trip"
      , [ test_case "PR_merged" `Quick test_round_trip_pr_merged
        ; test_case "CI_pass" `Quick test_round_trip_ci_pass
        ; test_case "Tests_pass" `Quick test_round_trip_tests_pass
        ; test_case
            "Artifact_exists with min_bytes"
            `Quick
            test_round_trip_artifact_exists_min_bytes
        ; test_case
            "Artifact_exists without min_bytes"
            `Quick
            test_round_trip_artifact_exists_no_min
        ; test_case "File_changed" `Quick test_round_trip_file_changed
        ; test_case "Custom_check" `Quick test_round_trip_custom_check
        ] )
    ; ( "closed_sum"
      , [ test_case
            "unknown variant rejected"
            `Quick
            test_unknown_variant_rejected
        ] )
    ; ( "human_string"
      , [ test_case "compact form" `Quick test_human_string_compact
        ; test_case "no newline" `Quick test_human_string_no_newline
        ] )
    ]
;;
