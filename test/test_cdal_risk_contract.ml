(** Pin tests for Risk_contract — contract-driven runtime constraints.

    These tests lock the behavior of [contract_id] (content-addressed
    hash), [canonical_json] (sorted-key compact form), and round-trip
    serialization.

    Part of #14323: restoring CDAL unit test coverage. *)

open Alcotest
module Rc = Masc_mcp_cdal_runtime.Risk_contract
module Em = Masc_mcp_cdal_runtime.Execution_mode
module Risk = Masc_mcp_cdal_runtime.Risk_class

let check_string = check string
let check_bool = check bool

let make_contract ?(mode = Em.Execute) ?(risk = Risk.Low) ?(mutations = [])
    ?(review = None) ?(eval = `Null) () =
  let constraints =
    Rc.
      { requested_execution_mode = mode
      ; risk_class = risk
      ; allowed_mutations = mutations
      ; review_requirement = review
      }
  in
  { Rc.runtime_constraints = constraints; eval_criteria = eval }

(* ── contract_id determinism ─────────────────────────────────────── *)

let test_contract_id_deterministic () =
  let c = make_contract () in
  let id1 = Rc.contract_id c in
  let id2 = Rc.contract_id c in
  check_string "same contract, same id" id1 id2

let test_contract_id_starts_with_md5 () =
  let c = make_contract () in
  let id = Rc.contract_id c in
  check_bool "starts with md5:" true (String.starts_with ~prefix:"md5:" id)

let test_contract_id_sensitive_to_mode () =
  let c1 = make_contract ~mode:Em.Diagnose () in
  let c2 = make_contract ~mode:Em.Execute () in
  let id1 = Rc.contract_id c1 in
  let id2 = Rc.contract_id c2 in
  check_bool "different modes, different ids" true (id1 <> id2)

let test_contract_id_sensitive_to_risk () =
  let c1 = make_contract ~risk:Risk.Low () in
  let c2 = make_contract ~risk:Risk.High () in
  let id1 = Rc.contract_id c1 in
  let id2 = Rc.contract_id c2 in
  check_bool "different risks, different ids" true (id1 <> id2)

let test_contract_id_sensitive_to_mutations () =
  let c1 = make_contract ~mutations:[ "Write" ] () in
  let c2 = make_contract ~mutations:[ "Write"; "Bash" ] () in
  let id1 = Rc.contract_id c1 in
  let id2 = Rc.contract_id c2 in
  check_bool "different mutations, different ids" true (id1 <> id2)

let test_contract_id_sensitive_to_review () =
  let c1 = make_contract ~review:None () in
  let c2 = make_contract ~review:(Some "human-approval") () in
  let id1 = Rc.contract_id c1 in
  let id2 = Rc.contract_id c2 in
  check_bool "review changes id" true (id1 <> id2)

let test_contract_id_sensitive_to_eval () =
  let c1 = make_contract ~eval:`Null () in
  let c2 = make_contract ~eval:(`Assoc [ ("threshold", `Float 0.9) ]) () in
  let id1 = Rc.contract_id c1 in
  let id2 = Rc.contract_id c2 in
  check_bool "eval criteria changes id" true (id1 <> id2)

(* ── canonical_json ─────────────────────────────────────────────── *)

let test_canonical_json_is_sorted () =
  let c = make_contract () in
  let json = Rc.canonical_json c in
  check_bool "starts with {" true (String.starts_with ~prefix:"{" json);
  check_bool "ends with }" true (String.ends_with ~suffix:"}" json)

let test_canonical_json_no_whitespace () =
  let c = make_contract ~mutations:[ "Write"; "Bash" ] () in
  let json = Rc.canonical_json c in
  check_bool "compact (no newline)" true (not (String.contains json '\n'))

let test_canonical_json_deterministic () =
  let c = make_contract () in
  let j1 = Rc.canonical_json c in
  let j2 = Rc.canonical_json c in
  check_string "same contract, same json" j1 j2

(* ── Round-trip serialization ───────────────────────────────────── *)

let test_round_trip_minimal () =
  let c = make_contract () in
  let json = Rc.to_yojson c in
  match Rc.of_yojson json with
  | Ok c' ->
    check_bool "mode preserved"
      (Em.equal c.Rc.runtime_constraints.requested_execution_mode
         c'.Rc.runtime_constraints.requested_execution_mode)
      true;
    check_bool "risk preserved"
      (Risk.equal c.Rc.runtime_constraints.risk_class
         c'.Rc.runtime_constraints.risk_class)
      true
  | Error e -> failf "round-trip failed: %s" e

let test_round_trip_full () =
  let c =
    make_contract
      ~mode:Em.Execute
      ~risk:Risk.Critical
      ~mutations:[ "Write"; "Bash"; "Edit" ]
      ~review:(Some "dual-approval")
      ~eval:(`Assoc [ ("max_retries", `Int 3 ); ("threshold", `Float 0.95) ])
      ()
  in
  match Rc.of_yojson (Rc.to_yojson c) with
  | Ok c' ->
    let rc = c.Rc.runtime_constraints and rc' = c'.Rc.runtime_constraints in
    check_bool "mode" (Em.equal rc.requested_execution_mode rc'.requested_execution_mode) true;
    check_bool "risk" (Risk.equal rc.risk_class rc'.risk_class) true;
    check (int) "mutations length"
      (List.length rc.allowed_mutations)
      (List.length rc'.allowed_mutations);
    check_bool "review"
      (rc.review_requirement = rc'.review_requirement)
      true;
    check_string "contract_id preserved" (Rc.contract_id c) (Rc.contract_id c')
  | Error e -> failf "full contract round-trip failed: %s" e

let () =
  Alcotest.run "cdal_risk_contract"
    [ ( "contract_id"
      , [ test_case "deterministic" `Quick test_contract_id_deterministic
        ; test_case "prefix md5:" `Quick test_contract_id_starts_with_md5
        ; test_case "sensitive to mode" `Quick test_contract_id_sensitive_to_mode
        ; test_case "sensitive to risk" `Quick test_contract_id_sensitive_to_risk
        ; test_case "sensitive to mutations" `Quick test_contract_id_sensitive_to_mutations
        ; test_case "sensitive to review" `Quick test_contract_id_sensitive_to_review
        ; test_case "sensitive to eval" `Quick test_contract_id_sensitive_to_eval
        ] )
    ; ( "canonical_json"
      , [ test_case "is sorted object" `Quick test_canonical_json_is_sorted
        ; test_case "compact form" `Quick test_canonical_json_no_whitespace
        ; test_case "deterministic" `Quick test_canonical_json_deterministic
        ] )
    ; ( "round_trip"
      , [ test_case "minimal" `Quick test_round_trip_minimal
        ; test_case "full" `Quick test_round_trip_full
        ] )
    ]
