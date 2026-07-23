(** Tests for multi-dimensional reputation observations. *)

open Alcotest
open Masc

(* ── Reputation v2 observation defaults ─────────────────────────── *)

let test_default_reputation_v2_fields () =
  let rep = Reputation.default_reputation ~agent_name:"test-agent" in
  check (float 0.0001) "execution_reliability default" 1.0
    rep.execution_reliability;
  check (float 0.0001) "goal_adherence default" 1.0
    rep.goal_adherence;
  check (float 0.0001) "safety_compliance default" 1.0
    rep.safety_compliance;
  check string "evidence_state default" "default"
    rep.evidence_state

let test_reputation_json_roundtrip_v2_fields () =
  let rep = { (Reputation.default_reputation ~agent_name:"json-test") with
              evidence_state = "measured" } in
  let json = Reputation.reputation_to_json rep in
  match Reputation.reputation_of_json json with
  | Some r ->
    check (float 0.0001) "execution_reliability preserved" 1.0
      r.execution_reliability;
    check string "evidence_state preserved" "measured"
      r.evidence_state
  | None ->
    fail "reputation_of_json returned None"

let () =
  run "Reputation_multi_dim"
    [ ( "agent_reputation_v2",
        [ test_case "default v2 fields are neutral" `Quick
            test_default_reputation_v2_fields
        ; test_case "json round-trip preserves v2 fields" `Quick
            test_reputation_json_roundtrip_v2_fields
        ] )
    ]
