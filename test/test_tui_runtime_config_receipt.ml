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

let exact_output_registry ?(status = "applied") ?(requires_restart = false) ?extra () =
  let extra =
    match extra, status with
    | Some extra, _ -> extra
    | None, "applied" -> [ "targets", `String "runtime_bindings" ]
    | None, "kept" ->
      [ "next_boot_publishes", `Bool false; "reason", `String "catalog read failed" ]
    | None, _ -> []
  in
  `Assoc ([ "status", `String status; "requires_restart", `Bool requires_restart ] @ extra)
;;

let receipt
      ?(skills = published ())
      ?(routing = routing)
      ?(keeper = keeper_overlay)
      ?(exact = exact_output_registry ())
      ?(warnings = `List [])
      ()
  =
  `Assoc
    [ "ok", `Bool true
    ; "state", `String "committed"
    ; ( "commit"
      , `Assoc
          [ "source_revision", `String "source-7"
          ; "order", `String "7"
          ; "durability", `String "durable"
          ; "warnings", warnings
          ] )
    ; ( "application"
      , `Assoc
          [ "operation", `String "raw_save"
          ; "routing", routing
          ; "keeper_overlay", keeper
          ; "skills", skills
          ; "exact_output_registry", exact
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

(* The server always writes [commit.warnings] and, on a commit, the
   exact-output registry row; a decoder that refuses either refuses every
   real receipt. *)
let test_exact_output_registry_and_lock_warnings () =
  let lock_warning =
    `Assoc
      [ "code", `String "runtime_config_lock_release_unconfirmed"
      ; "detail", `String "lock file stayed"
      ]
  in
  let applied = decoded (receipt ~warnings:(`List [ lock_warning ]) ()) in
  (match applied.application.exact_output_registry with
   | Receipt.Exact_output_registry_applied Receipt.Targets_runtime_bindings -> ()
   | Receipt.Exact_output_registry_applied Receipt.Targets_replacement_catalog
   | Receipt.Exact_output_registry_unpublished
   | Receipt.Exact_output_registry_kept _ -> fail "applied registry changed variant");
  check (list string) "lock warning codes"
    [ "runtime_config_lock_release_unconfirmed" ]
    (List.map (fun (warning : Receipt.lock_warning) -> warning.code) applied.lock_warnings);
  check bool "summary names the applied registry" true
    (String.ends_with ~suffix:"exact-registry-applied" (Receipt.summary applied));
  check bool "summary names the lock warning" true
    (let summary = Receipt.summary applied in
     let needle = "lock-warnings=runtime_config_lock_release_unconfirmed" in
     let rec find i =
       i + String.length needle <= String.length summary
       && (String.equal (String.sub summary i (String.length needle)) needle || find (i + 1))
     in
     find 0);
  let unpublished =
    decoded
      (receipt
         ~exact:(exact_output_registry ~status:"unpublished" ~requires_restart:true ())
         ())
  in
  (match unpublished.application.exact_output_registry with
   | Receipt.Exact_output_registry_unpublished -> ()
   | Receipt.Exact_output_registry_applied _ | Receipt.Exact_output_registry_kept _ ->
     fail "unpublished registry read as applied");
  let kept =
    decoded (receipt ~exact:(exact_output_registry ~status:"kept" ()) ())
  in
  (match kept.application.exact_output_registry with
   | Receipt.Exact_output_registry_kept { reason } ->
     check string "kept reason" "catalog read failed" reason
   | Receipt.Exact_output_registry_applied _ | Receipt.Exact_output_registry_unpublished ->
     fail "kept registry changed variant");
  check bool "summary names the kept registry" true
    (String.ends_with ~suffix:"exact-registry-kept/next-boot-unpublished" (Receipt.summary kept));
  rejected
    (receipt
       ~exact:
         (exact_output_registry
            ~status:"kept"
            ~extra:[ "next_boot_publishes", `Bool true; "reason", `String "x" ]
            ())
       ());
  rejected (receipt ~exact:(exact_output_registry ~status:"kept" ~extra:[] ()) ());
  rejected
    (receipt
       ~exact:(exact_output_registry ~extra:[ "targets", `String "future" ] ())
       ());
  rejected
    (receipt ~exact:(exact_output_registry ~status:"unpublished" ~requires_restart:false ()) ());
  rejected
    (receipt ~exact:(exact_output_registry ~status:"applied" ~requires_restart:true ()) ());
  rejected (receipt ~exact:(exact_output_registry ~status:"future" ()) ());
  rejected (receipt ~warnings:(`List [ `Assoc [ "code", `String "x" ] ]) ());
  match receipt () with
  | `Assoc fields ->
    (match List.assoc "application" fields with
     | `Assoc application ->
       rejected
         (`Assoc
            (("application", `Assoc (List.remove_assoc "exact_output_registry" application))
             :: List.remove_assoc "application" fields))
     | _ -> fail "application fixture must be an object")
  | _ -> fail "receipt fixture must be an object"
;;

let test_rejects_false_success_receipt () =
  match receipt () with
  | `Assoc fields -> rejected (`Assoc (("ok", `Bool false) :: List.remove_assoc "ok" fields))
  | _ -> fail "receipt fixture must be an object"
;;

(* The preview route's answer, shaped as the server writes it: ok is true on
   every parsed text, so only can_save says whether the save would pass. *)
let preview ?runtime_validation ?(issues = []) can_save =
  `Assoc
    [ "ok", `Bool true
    ; "can_save", `Bool can_save
    ; ( "validation"
      , `Assoc
          [ "valid", `Bool (issues = [])
          ; ( "issues"
            , `List
                (List.map
                   (fun detail -> `Assoc [ "key", `String "turn.x"; "detail", `String detail ])
                   issues) )
          ] )
    ; ( "runtime_validation"
      , match runtime_validation with
        | None -> `Null
        | Some reason -> `String reason )
    ]
;;

let preview_answer json =
  match Receipt.decode_preview json with
  | Ok Receipt.Can_save -> "save"
  | Ok (Receipt.Cannot_save reason) -> "refused: " ^ reason
  | Error detail -> "unreadable: " ^ detail
;;

let test_preview_reads_can_save () =
  check string "can_save true saves" "save" (preview_answer (preview true));
  check string "a runtime refusal carries the runtime reason"
    "refused: provider voice: reserved"
    (preview_answer (preview ~runtime_validation:"provider voice: reserved" false));
  check string "a schema refusal carries the issues"
    "refused: expected a boolean; unknown key"
    (preview_answer (preview ~issues:[ "expected a boolean"; "unknown key" ] false))
;;

(* The TUI used to read validation.ok, which the route never writes, and
   saved whenever it could not tell. An answer it cannot read is not a pass. *)
let test_preview_without_can_save_is_not_a_pass () =
  let without_can_save =
    match preview true with
    | `Assoc fields -> `Assoc (List.remove_assoc "can_save" fields)
    | other -> other
  in
  check bool "no can_save" true
    (Result.is_error (Receipt.decode_preview without_can_save));
  check bool "a refusal with no reason" true
    (Result.is_error (Receipt.decode_preview (preview false)));
  check bool "not an object" true (Result.is_error (Receipt.decode_preview (`List [])))
;;

let test_lane_notice_retains_application_and_durability () =
  let decode json = match Receipt.decode json with Ok value -> value | Error e -> fail e in
  let kept = decode (receipt ~exact:(exact_output_registry ~status:"kept" ()) ()) in
  check bool "kept warns" true (Receipt.lane_needs_attention kept);
  check string "kept explains why restarting is not a repair"
    "File saved · exact lanes unchanged: catalog read failed; correct configuration before restart · routing applied · Keeper settings await restart: turn.temperature"
    (Receipt.lane_summary kept);
  let unpublished = decode (receipt ~exact:(exact_output_registry ~status:"unpublished" ~requires_restart:true ()) ()) in
  let unpublished = {unpublished with Receipt.durability = Receipt.Durability_unconfirmed} in
  check bool "unpublished warns" true (Receipt.lane_needs_attention unpublished);
  check string "file uncertainty and missing registry are distinct"
    "File written; durability unconfirmed · exact lanes unavailable; restart required · routing applied · Keeper settings await restart: turn.temperature"
    (Receipt.lane_summary unpublished)
;;

let test_lane_notice_reports_environment_preemption () =
  List.iter (fun (status, applied, expected) ->
    let keeper = `Assoc ["status", `String status; "configured_count", `Int (1 + List.length applied);
      "requires_restart", `Bool false; "pending_keys", `List [];
      "applied_keys", `List (List.map (fun key -> `String key) applied);
      "preempted_keys", `List [`String "turn.temperature"]; "applied_at", `Null] in
    let value = decoded (receipt ~keeper ()) in
    check bool "environment preemption needs attention without restart" true
      (Receipt.lane_needs_attention value);
    check string "lane summary retains preemption and affected keys"
      ("File saved · exact lanes applied · routing applied · " ^ expected)
      (Receipt.lane_summary value))
    ["preempted_by_env", [], "Keeper settings overridden by environment: turn.temperature";
     "mixed", ["turn.max_tokens"],
       "Keeper settings partially applied; overridden by environment: turn.temperature"]
;;

let () =
  run
    "tui runtime config receipt"
    [ ( "decode"
      , [ test_case "lane preemption is visible without restart" `Quick test_lane_notice_reports_environment_preemption;
          test_case "lane notices preserve application and durability" `Quick
            test_lane_notice_retains_application_and_durability
        ; test_case "valid receipt preserves typed outcomes" `Quick
            test_valid_receipt_preserves_typed_outcomes
        ; test_case "causal mismatches are rejected" `Quick
            test_rejects_causal_mismatches
        ; test_case "Skill variants are closed and complete" `Quick
            test_rejects_open_or_incomplete_skill_variants
        ; test_case "application evidence is required" `Quick
            test_rejects_incomplete_application_receipts
        ; test_case "exact-output registry row and lock warnings are decoded" `Quick
            test_exact_output_registry_and_lock_warnings
        ; test_case "ok=false is rejected" `Quick test_rejects_false_success_receipt
        ] )
    ; ( "preview"
      , [ test_case "can_save decides and a refusal says why" `Quick
            test_preview_reads_can_save
        ; test_case "an answer without can_save is not a pass" `Quick
            test_preview_without_can_save_is_not_a_pass
        ] )
    ]
;;
