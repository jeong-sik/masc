open Alcotest

module Receipt = Masc_tui_runtime_config_receipt

let routing =
  `Assoc
    [ "status", `String "applied"
    ; "requires_restart", `Bool false
    ; "applied_at", `String "2026-08-26T03:00:00Z"
    ]
;;

let keeper_overlay =
  `Assoc
    [ "status", `String "pending_restart"
    ; "configured_count", `Int 1
    ; "requires_restart", `Bool true
    ; "pending_keys", `List [ `String "turn.temperature" ]
    ; "applied_keys", `List []
    ; "preempted_keys", `List []
    ; "applied_at", `Null
    ]
;;

let published ?(input_source_revision = "source-7") ?(config_state = "configured") () =
  `Assoc
    [ "state", `String "published"
    ; "input_source_revision", `String input_source_revision
    ; "snapshot_revision", `String "snapshot-7"
    ; "catalog_revision", `String "catalog-7"
    ; "config_state", `String config_state
    ]
;;

let superseded ?(commit_order = "7") () =
  `Assoc
    [ "state", `String "superseded"
    ; "commit_order", `String commit_order
    ; "applied_order", `String "8"
    ]
;;

let receipt ?(skills = published ()) ?(routing = routing) ?(keeper = keeper_overlay) () =
  `Assoc
    [ "ok", `Bool true
    ; "state", `String "committed"
    ; ( "commit"
      , `Assoc
          [ "source_revision", `String "source-7"
          ; "order", `String "7"
          ; "durability", `String "durable"
          ] )
    ; ( "application"
      , `Assoc
          [ "operation", `String "raw_save"
          ; "routing", routing
          ; "keeper_overlay", keeper
          ; "skills", skills
          ] )
    ]
;;

let decoded json =
  match Receipt.decode json with
  | Ok receipt -> receipt
  | Error detail -> fail detail
;;

let rejected json =
  match Receipt.decode json with
  | Error _ -> ()
  | Ok _ -> fail "invalid runtime config receipt was accepted"
;;

let test_valid_receipt_preserves_typed_outcomes () =
  let receipt = decoded (receipt ()) in
  check string "operation" "raw_save" receipt.application.operation;
  check (list string) "pending keys" [ "turn.temperature" ]
    receipt.application.keeper_pending_keys;
  (match receipt.application.routing_applied_at with
   | Receipt.Applied_at_string value ->
     check string "routing applied_at" "2026-08-26T03:00:00Z" value
   | Receipt.Not_applied | Receipt.Applied_at_int _ | Receipt.Applied_at_float _ ->
     fail "routing applied_at changed representation");
  (match receipt.application.keeper_applied_at with
   | Receipt.Not_applied -> ()
   | Receipt.Applied_at_string _ | Receipt.Applied_at_int _ | Receipt.Applied_at_float _ ->
     fail "Keeper applied_at changed representation");
  check bool "summary renders routing" true
    (String.starts_with ~prefix:"commit=7 durable routing-applied" (Receipt.summary receipt));
  match receipt.application.skills with
  | Receipt.Skill_published { input_source_revision; config_state; _ } ->
    check string "input revision" "source-7" input_source_revision;
    (match config_state with
     | Receipt.Configured -> ()
     | Receipt.Rejected | Receipt.Unreadable -> fail "configured state changed")
  | _ -> fail "published receipt changed variant"
;;

let test_rejects_causal_mismatches () =
  rejected (receipt ~skills:(published ~input_source_revision:"source-6" ()) ());
  rejected (receipt ~skills:(superseded ~commit_order:"6" ()) ())
;;

let test_rejects_open_or_incomplete_skill_variants () =
  rejected (receipt ~skills:(published ~config_state:"future" ()) ());
  rejected (receipt ~skills:(`Assoc [ "state", `String "workspace_retired" ]) ())
;;

let test_rejects_incomplete_application_receipts () =
  rejected (receipt ~routing:(`Assoc []) ());
  rejected (receipt ~keeper:(`Assoc []) ())
;;

let test_rejects_false_success_receipt () =
  match receipt () with
  | `Assoc fields -> rejected (`Assoc (("ok", `Bool false) :: List.remove_assoc "ok" fields))
  | _ -> fail "receipt fixture must be an object"
;;

let () =
  run
    "tui runtime config receipt"
    [ ( "decode"
      , [ test_case "valid receipt preserves typed outcomes" `Quick
            test_valid_receipt_preserves_typed_outcomes
        ; test_case "causal mismatches are rejected" `Quick
            test_rejects_causal_mismatches
        ; test_case "Skill variants are closed and complete" `Quick
            test_rejects_open_or_incomplete_skill_variants
        ; test_case "application evidence is required" `Quick
            test_rejects_incomplete_application_receipts
        ; test_case "ok=false is rejected" `Quick test_rejects_false_success_receipt
        ] )
    ]
;;
