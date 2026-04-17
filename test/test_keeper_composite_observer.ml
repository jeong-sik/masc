(** Tests for Keeper_composite_observer — isolated from the full
    snapshot pipeline. Each test uses a keeper_name prefix unique to
    the case so Prometheus global state does not cross-contaminate. *)

open Alcotest

module Obs = Masc_mcp.Keeper_composite_observer
module P = Masc_mcp.Prometheus

let counter_name = "masc_keeper_invariant_violations_total"

let read ~keeper ~invariant =
  P.metric_value_or_zero
    counter_name
    ~labels:[("keeper", keeper); ("invariant", invariant)]
    ()

let all_satisfied : Obs.invariants_check = {
  phase_turn_alignment = true;
  no_cascade_before_measurement = true;
  compaction_atomicity = true;
  event_priority_monotone = true;
}

let all_violated : Obs.invariants_check = {
  phase_turn_alignment = false;
  no_cascade_before_measurement = false;
  compaction_atomicity = false;
  event_priority_monotone = false;
}

(* --- bump: no-op when all satisfied ------------------------------- *)

let test_bump_noop_when_all_satisfied () =
  let keeper = "test-bump-noop" in
  let before = read ~keeper ~invariant:"PhaseTurnAlignment" in
  Obs.bump_invariant_violations ~keeper_name:keeper all_satisfied;
  let after = read ~keeper ~invariant:"PhaseTurnAlignment" in
  check (float 0.0001) "no bump on satisfied invariants" before after

(* --- bump: increments every violated invariant -------------------- *)

let test_bump_increments_each_violated () =
  let keeper = "test-bump-all-violated" in
  let invariants =
    [ "PhaseTurnAlignment"; "NoCascadeBeforeMeasurement";
      "CompactionAtomicity"; "EventPriorityMonotone" ]
  in
  let before = List.map (fun inv -> (inv, read ~keeper ~invariant:inv)) invariants in
  Obs.bump_invariant_violations ~keeper_name:keeper all_violated;
  List.iter (fun (inv, b) ->
    let a = read ~keeper ~invariant:inv in
    check (float 0.0001)
      (Printf.sprintf "counter %s increments by 1" inv)
      (b +. 1.0) a
  ) before

(* --- bump: only the violated labels move -------------------------- *)

let test_bump_selective_increments () =
  let keeper = "test-bump-mixed" in
  let mixed : Obs.invariants_check = {
    phase_turn_alignment = false;
    no_cascade_before_measurement = true;  (* satisfied, no bump *)
    compaction_atomicity = false;
    event_priority_monotone = true;        (* satisfied, no bump *)
  } in
  let pt_before = read ~keeper ~invariant:"PhaseTurnAlignment" in
  let nc_before = read ~keeper ~invariant:"NoCascadeBeforeMeasurement" in
  let ca_before = read ~keeper ~invariant:"CompactionAtomicity" in
  let ep_before = read ~keeper ~invariant:"EventPriorityMonotone" in
  Obs.bump_invariant_violations ~keeper_name:keeper mixed;
  check (float 0.0001) "phase_turn_alignment +1"
    (pt_before +. 1.0) (read ~keeper ~invariant:"PhaseTurnAlignment");
  check (float 0.0001) "no_cascade_before_measurement unchanged"
    nc_before (read ~keeper ~invariant:"NoCascadeBeforeMeasurement");
  check (float 0.0001) "compaction_atomicity +1"
    (ca_before +. 1.0) (read ~keeper ~invariant:"CompactionAtomicity");
  check (float 0.0001) "event_priority_monotone unchanged"
    ep_before (read ~keeper ~invariant:"EventPriorityMonotone")

(* --- bump: per-keeper isolation ----------------------------------- *)

let test_bump_per_keeper_isolation () =
  let k1 = "test-iso-alpha" in
  let k2 = "test-iso-beta" in
  let k2_before = read ~keeper:k2 ~invariant:"PhaseTurnAlignment" in
  Obs.bump_invariant_violations ~keeper_name:k1 all_violated;
  let k2_after = read ~keeper:k2 ~invariant:"PhaseTurnAlignment" in
  check (float 0.0001)
    "bumping keeper alpha does not touch keeper beta"
    k2_before k2_after

(* --- all invariant keys are covered ------------------------------- *)

let test_all_invariant_keys_mapped () =
  let strings =
    List.map Obs.invariant_key_to_string Obs.all_invariant_keys
  in
  check int "4 invariant keys" 4 (List.length strings);
  check (list string) "key names match alert-rule labels"
    [ "PhaseTurnAlignment"; "NoCascadeBeforeMeasurement";
      "CompactionAtomicity"; "EventPriorityMonotone" ]
    strings

let () =
  run "keeper_composite_observer" [
    "bump_invariant_violations",
    [ test_case "no-op when satisfied" `Quick test_bump_noop_when_all_satisfied
    ; test_case "increments each violated" `Quick test_bump_increments_each_violated
    ; test_case "only violated labels move" `Quick test_bump_selective_increments
    ; test_case "per-keeper isolation" `Quick test_bump_per_keeper_isolation
    ];
    "invariant_key mapping",
    [ test_case "all keys present and named" `Quick test_all_invariant_keys_mapped ];
  ]
