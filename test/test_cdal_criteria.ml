(** RFC-0109 Phase A — round-trip tests for [Masc_mcp_cdal_runtime.Criteria].

    Validates:
    - Each typed variant round-trips through to_yojson / of_yojson.
    - Legacy JSON (untagged, but with [kind] field or recognizable shape)
      is auto-routed to the matching typed variant.
    - Unrecognized JSON falls back to [Free].
    - JSON wire format remains stable across the migration. *)

open Alcotest

module Crit = Masc_mcp_cdal_runtime.Criteria

let yojson : Yojson.Safe.t testable =
  testable
    (fun fmt j -> Format.pp_print_string fmt (Yojson.Safe.to_string j))
    Yojson.Safe.equal

let criteria : Crit.t testable =
  testable Crit.pp Crit.equal

let roundtrip label value =
  match Crit.of_yojson (Crit.to_yojson value) with
  | Ok decoded -> check criteria label value decoded
  | Error err -> failf "round-trip %s failed: %s" label err

let test_keeper_turn_capture_v1_roundtrip () =
  roundtrip
    "keeper_turn_capture_v1"
    (Crit.Keeper_turn_capture_v1
       { keeper_name = "k-1"
       ; agent_name = "agent-1"
       ; sandbox_profile = "local"
       ; sandbox_image = None
       ; network_mode = "none"
       ; tool_access = `Assoc [ "kind", `String "custom"; "tools", `List [ `String "x" ] ]
       ; tool_denylist = [ "danger" ]
       ; allowed_paths = [ "/p1"; "/p2" ]
       ; active_goal_ids = [ "g1"; "g2" ]
       ; current_task_id = Some "task-1"
       })

let test_contract_catalog_invariants_roundtrip () =
  roundtrip
    "contract_catalog_invariants"
    (Crit.Contract_catalog_invariants
       { contract_name = "name-1"
       ; description = "desc"
       ; invariants = [ "inv-a"; "inv-b" ]
       })

let test_verification_request_roundtrip () =
  roundtrip
    "verification_request"
    (Crit.Verification_request { goal_id = "g-1"; request_id = "req-1" })

let test_persona_probe_roundtrip () =
  roundtrip
    "persona_probe"
    (Crit.Persona_probe { persona_id = "p-1"; trace_id = "tr-1" })

let test_free_roundtrip () =
  let payload = `Assoc [ "anything", `Int 42; "other", `Bool true ] in
  roundtrip "free" (Crit.Free payload)

(* Legacy decoding: JSON produced by the pre-RFC-0109 keeper_cdal_contract
   site is auto-routed to Keeper_turn_capture_v1 by virtue of the [kind]
   field, even without the new [criteria_kind] discriminator. *)
let test_legacy_keeper_kind_field () =
  let legacy_json =
    `Assoc
      [ "kind", `String "keeper_turn_capture_v1"
      ; "keeper_name", `String "k"
      ; "agent_name", `String "a"
      ; "sandbox_profile", `String "local"
      ; "sandbox_image", `Null
      ; "network_mode", `String "none"
      ; "tool_access", `Null
      ; "tool_denylist", `List []
      ; "allowed_paths", `List []
      ; "active_goal_ids", `List []
      ]
  in
  match Crit.of_yojson legacy_json with
  | Ok (Crit.Keeper_turn_capture_v1 r) ->
    check string "keeper_name" "k" r.keeper_name;
    check string "criteria_kind" "keeper_turn_capture_v1"
      (Crit.criteria_kind (Crit.Keeper_turn_capture_v1 r))
  | Ok other ->
    failf "expected Keeper_turn_capture_v1 from legacy [kind], got %s"
      (Crit.criteria_kind other)
  | Error err -> failf "decode failed: %s" err

(* Legacy decoding: contract_catalog JSON has no [kind] field but is
   recognized by required-field shape. *)
let test_legacy_catalog_shape () =
  let legacy_json =
    `Assoc
      [ "contract_name", `String "cn"
      ; "description", `String "d"
      ; "invariants", `List [ `String "i1" ]
      ]
  in
  match Crit.of_yojson legacy_json with
  | Ok (Crit.Contract_catalog_invariants r) ->
    check string "contract_name" "cn" r.contract_name;
    check (list string) "invariants" [ "i1" ] r.invariants
  | Ok other ->
    failf "expected Contract_catalog_invariants from legacy shape, got %s"
      (Crit.criteria_kind other)
  | Error err -> failf "decode failed: %s" err

(* Unrecognized JSON falls back to Free. *)
let test_unknown_shape_falls_back_to_free () =
  let unknown = `Assoc [ "novel_field", `String "value" ] in
  match Crit.of_yojson unknown with
  | Ok (Crit.Free j) -> check yojson "free payload" unknown j
  | Ok other ->
    failf "expected Free fallback, got %s" (Crit.criteria_kind other)
  | Error err -> failf "decode failed: %s" err

(* Non-object JSON falls back to Free as well. *)
let test_non_object_falls_back_to_free () =
  let scalar = `String "scalar-payload" in
  match Crit.of_yojson scalar with
  | Ok (Crit.Free j) -> check yojson "free payload" scalar j
  | Ok other ->
    failf "expected Free fallback, got %s" (Crit.criteria_kind other)
  | Error err -> failf "decode failed: %s" err

(* The new tagged form ([criteria_kind]) wins over a legacy [kind] field
   when both are present (forward-compat: future producers can disambiguate). *)
let test_criteria_kind_takes_precedence_over_kind () =
  let json =
    `Assoc
      [ "criteria_kind", `String "verification_request"
      ; "kind", `String "keeper_turn_capture_v1"
      ; "goal_id", `String "g-1"
      ; "request_id", `String "req-1"
      ]
  in
  match Crit.of_yojson json with
  | Ok (Crit.Verification_request r) ->
    check string "goal_id" "g-1" r.goal_id;
    check string "request_id" "req-1" r.request_id
  | Ok other ->
    failf "expected Verification_request, got %s" (Crit.criteria_kind other)
  | Error err -> failf "decode failed: %s" err

let () =
  Alcotest.run
    "cdal_criteria"
    [ ( "round-trip"
      , [ test_case "keeper_turn_capture_v1" `Quick test_keeper_turn_capture_v1_roundtrip
        ; test_case "contract_catalog_invariants" `Quick test_contract_catalog_invariants_roundtrip
        ; test_case "verification_request" `Quick test_verification_request_roundtrip
        ; test_case "persona_probe" `Quick test_persona_probe_roundtrip
        ; test_case "free" `Quick test_free_roundtrip
        ] )
    ; ( "legacy compat"
      , [ test_case "legacy [kind] field routes to typed" `Quick test_legacy_keeper_kind_field
        ; test_case "legacy catalog shape routes by fields" `Quick test_legacy_catalog_shape
        ; test_case "unknown shape -> Free" `Quick test_unknown_shape_falls_back_to_free
        ; test_case "non-object -> Free" `Quick test_non_object_falls_back_to_free
        ] )
    ; ( "tagging"
      , [ test_case "criteria_kind wins over kind" `Quick test_criteria_kind_takes_precedence_over_kind
        ] )
    ]
;;
