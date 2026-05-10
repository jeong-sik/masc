(** Pin tests for Cdal_proof — 15-field proof bundle serialization.

    These tests lock the current behavior of the proof bundle type
    against regressions in serialization round-trips, schema version
    stability, and result_status variant coverage.

    Part of #14323: restoring CDAL unit test coverage. *)

open Alcotest
module Cp = Masc_mcp_cdal_runtime.Cdal_proof
module Em = Masc_mcp_cdal_runtime.Execution_mode
module Rc = Masc_mcp_cdal_runtime.Risk_class

let check_int = check int
let check_string = check string
let check_bool = check bool

let provider_snapshot =
  Cp.
    { provider_name = "anthropic"
    ; model_id = "claude-sonnet-4-6"
    ; api_version = Some "2023-06-01"
    }
;;

let capability_snapshot =
  Cp.
    { tools = [ "Read"; "Write"; "Bash" ]
    ; mcp_servers = [ "serena" ]
    ; max_turns = 200
    ; max_tokens = Some 8192
    ; thinking_enabled = Some true
    }
;;

let proof ?(result_status = Cp.Completed) ?scope () =
  Cp.
    { schema_version = Cp.schema_version_current
    ; run_id = "run-001"
    ; contract_id = "md5:abc123"
    ; requested_execution_mode = Em.Execute
    ; effective_execution_mode = Em.Diagnose
    ; mode_decision_source = "risk_downgrade"
    ; risk_class = Rc.Medium
    ; provider_snapshot
    ; capability_snapshot
    ; tool_trace_refs = [ "proof-store://run-001/tool-trace" ]
    ; raw_evidence_refs =
        [ "proof-store://run-001/raw-evidence-1"; "proof-store://run-001/raw-evidence-2" ]
    ; checkpoint_ref = Some "proof-store://run-001/checkpoint"
    ; result_status
    ; started_at = 1715250000.0
    ; ended_at = 1715250300.0
    ; scope
    }
;;

(* ── Schema version pin ────────────────────────────────────────── *)

let test_schema_version_pin () =
  check_int "schema_version_current is 1" 1 Cp.schema_version_current
;;

(* ── result_status round-trip ───────────────────────────────────── *)

let test_result_status_round_trip () =
  let all_status =
    [ Cp.Completed; Cp.Errored; Cp.Timed_out; Cp.Cancelled; Cp.Context_overflow ]
  in
  List.iter
    (fun status ->
       let json = Cp.result_status_to_yojson status in
       match Cp.result_status_of_yojson json with
       | Ok s -> check_bool (Cp.show_result_status status) true (s = status)
       | Error e -> failf "round-trip failed for %s: %s" (Cp.show_result_status status) e)
    all_status
;;

let test_result_status_rejects_unknown () =
  match Cp.result_status_of_yojson (`String "unknown_status") with
  | Ok _ -> fail "expected error for unknown result_status"
  | Error _ -> ()
;;

let test_result_status_rejects_non_string () =
  match Cp.result_status_of_yojson (`Int 42) with
  | Ok _ -> fail "expected error for non-string result_status"
  | Error _ -> ()
;;

(* ── Full proof bundle round-trip ───────────────────────────────── *)

let test_proof_round_trip_completed () =
  let p = proof () in
  let json = Cp.to_json p in
  match Cp.of_json json with
  | Ok p' ->
    check_string "run_id" p.Cp.run_id p'.Cp.run_id;
    check_string "contract_id" p.Cp.contract_id p'.Cp.contract_id;
    check_bool "result_status" true (p.Cp.result_status = p'.Cp.result_status);
    check_int "schema_version" p.Cp.schema_version p'.Cp.schema_version;
    check_int
      "tool_trace_refs length"
      (List.length p.Cp.tool_trace_refs)
      (List.length p'.Cp.tool_trace_refs);
    check_int
      "raw_evidence_refs length"
      (List.length p.Cp.raw_evidence_refs)
      (List.length p'.Cp.raw_evidence_refs);
    check_bool
      "checkpoint_ref"
      (p.Cp.checkpoint_ref <> None)
      (p'.Cp.checkpoint_ref <> None)
  | Error e -> failf "proof round-trip failed: %s" e
;;

let test_proof_round_trip_all_status () =
  let all_status =
    [ Cp.Completed; Cp.Errored; Cp.Timed_out; Cp.Cancelled; Cp.Context_overflow ]
  in
  List.iter
    (fun status ->
       let p = proof ~result_status:status () in
       match Cp.of_json (Cp.to_json p) with
       | Ok p' ->
         check_bool
           (Printf.sprintf "status %s round-trips" (Cp.show_result_status status))
           true
           (p'.Cp.result_status = status)
       | Error e ->
         failf "round-trip failed for status %s: %s" (Cp.show_result_status status) e)
    all_status
;;

let test_proof_without_optional_fields () =
  let base = proof () in
  let p =
    { base with
      Cp.scope = None
    ; checkpoint_ref = None
    ; provider_snapshot = { base.Cp.provider_snapshot with api_version = None }
    }
  in
  match Cp.of_json (Cp.to_json p) with
  | Ok p' ->
    check_bool "checkpoint_ref is None" (p'.Cp.checkpoint_ref = None) true;
    check_bool "api_version is None" (p'.Cp.provider_snapshot.api_version = None) true
  | Error e -> failf "minimal proof round-trip failed: %s" e
;;

let test_proof_with_scope () =
  let p = proof ~scope:"repo:masc-mcp" () in
  match Cp.of_json (Cp.to_json p) with
  | Ok p' ->
    check_string "scope preserved" "repo:masc-mcp" (Option.value p'.Cp.scope ~default:"")
  | Error e -> failf "scoped proof round-trip failed: %s" e
;;

let test_proof_rejects_missing_field () =
  let json = `Assoc [ "schema_version", `Int 1; "run_id", `String "run-001" ] in
  match Cp.of_json json with
  | Ok _ -> fail "expected error for incomplete proof json"
  | Error _ -> ()
;;

(* ── provider_snapshot and capability_snapshot ───────────────────── *)

let test_provider_snapshot_round_trip () =
  let snap =
    Cp.{ provider_name = "openrouter"; model_id = "qwen3-235b"; api_version = None }
  in
  let json = Cp.provider_snapshot_to_yojson snap in
  match Cp.provider_snapshot_of_yojson json with
  | Ok s ->
    check_string "provider_name" "openrouter" s.Cp.provider_name;
    check_bool "api_version is None" (s.Cp.api_version = None) true
  | Error e -> failf "provider_snapshot round-trip failed: %s" e
;;

let test_capability_snapshot_round_trip () =
  let snap =
    Cp.
      { tools = []
      ; mcp_servers = []
      ; max_turns = 10
      ; max_tokens = None
      ; thinking_enabled = None
      }
  in
  let json = Cp.capability_snapshot_to_yojson snap in
  match Cp.capability_snapshot_of_yojson json with
  | Ok s ->
    check_int "max_turns" 10 s.Cp.max_turns;
    check_bool "tools empty" (s.Cp.tools = []) true
  | Error e -> failf "capability_snapshot round-trip failed: %s" e
;;

let () =
  Alcotest.run
    "cdal_proof"
    [ "schema_version", [ test_case "current is 1" `Quick test_schema_version_pin ]
    ; ( "result_status"
      , [ test_case "all variants round-trip" `Quick test_result_status_round_trip
        ; test_case "rejects unknown string" `Quick test_result_status_rejects_unknown
        ; test_case "rejects non-string" `Quick test_result_status_rejects_non_string
        ] )
    ; ( "proof_round_trip"
      , [ test_case "completed proof" `Quick test_proof_round_trip_completed
        ; test_case "all result statuses" `Quick test_proof_round_trip_all_status
        ; test_case "without optional fields" `Quick test_proof_without_optional_fields
        ; test_case "with scope" `Quick test_proof_with_scope
        ; test_case "rejects incomplete json" `Quick test_proof_rejects_missing_field
        ] )
    ; ( "snapshots"
      , [ test_case "provider round-trip" `Quick test_provider_snapshot_round_trip
        ; test_case "capability round-trip" `Quick test_capability_snapshot_round_trip
        ] )
    ]
;;
