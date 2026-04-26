(** Tests for [Keeper_identity.validation_error_outcome_label] — RFC P3-a
    Prometheus label SSOT. The compiler enforces exhaustiveness on the
    match in [keeper_identity.ml]; these tests fix the actual label
    strings so a rename in one variant doesn't silently break dashboards
    that pivot on [outcome=...]. *)

open Alcotest
open Masc_mcp

let label_of = Keeper_identity.validation_error_outcome_label

let test_empty_input () =
  check string "Empty_input" "empty_input" (label_of Keeper_identity.Empty_input)
;;

let dummy_input = "kpper"

let test_persona_not_found () =
  let err =
    Keeper_identity.Persona_not_found
      { input = dummy_input; resolved = "kpper"; searched = "/x" }
  in
  check string "Persona_not_found" "persona_not_found" (label_of err)
;;

let test_credential_missing () =
  let err =
    Keeper_identity.Credential_missing
      { input = dummy_input; resolved = "kpper"; searched = "/x" }
  in
  check string "Credential_missing" "credential_missing" (label_of err)
;;

let test_name_ambiguous () =
  let err =
    Keeper_identity.Name_ambiguous { input = dummy_input; candidates = [ "a"; "b" ] }
  in
  check string "Name_ambiguous" "name_ambiguous" (label_of err)
;;

let test_ephemeral_suffix_rejected () =
  let err =
    Keeper_identity.Ephemeral_suffix_rejected { input = dummy_input; stripped = "kpper" }
  in
  check string "Ephemeral_suffix_rejected" "ephemeral_suffix_rejected" (label_of err)
;;

let () =
  run
    "keeper_identity_outcome_label"
    [ ( "P3-a outcome labels"
      , [ test_case "Empty_input" `Quick test_empty_input
        ; test_case "Persona_not_found" `Quick test_persona_not_found
        ; test_case "Credential_missing" `Quick test_credential_missing
        ; test_case "Name_ambiguous" `Quick test_name_ambiguous
        ; test_case "Ephemeral_suffix_rejected" `Quick test_ephemeral_suffix_rejected
        ] )
    ]
;;
