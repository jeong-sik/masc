(* What a direct write does to Memory (RFC librarian-call-only-proposes
   §8.5). One case per row of the table. Every case that writes also checks
   that the Memory it returns holds no fact twice and no derived fact without
   its premises: a snapshot with either is refused when it is read back. *)

open Alcotest
module Direct = Masc.Librarian_direct
module Effects = Masc.Librarian_effects
module Types = Masc.Keeper_memory_os_types

let injected : Types.origin = { kind = Types.Injected; trace_id = "question" }

let observed claim : Types.fact =
  { claim
  ; category = Types.Constraint
  ; first_seen = 100.0
  ; last_seen = 100.0
  ; origin = injected
  ; basis = Types.Observed Types.Transcript
  }
;;

let id = Types.memory_id
let id_of_claim = Types.memory_id_of_claim
let rule premises : Types.derivation = { rule_id = "rule"; premise_ids = List.map id premises }

let derived claim premises =
  match
    Types.derived ~claim ~category:Types.Lesson ~now:100.0 ~origin:injected
      ~derivations:[ rule premises ]
  with
  | Ok fact -> fact
  | Error detail -> fail detail
;;

let port = observed "the port is 8935"
let owner = observed "the owner is the release team"
let memory = [ port; owner ]
let at = 500.0
let transcript = Types.Observed Types.Transcript

let outcome_text : Direct.t -> string = function
  | Writes _ -> "writes"
  | Already_held -> "already held"
  | Already_done -> "already done"
  | Already_absent -> "already absent"
  | Refused Unknown_fact -> "refused: unknown fact"
  | Refused Supersedes_itself -> "refused: supersedes itself"
  | Refused Blank_claim -> "refused: blank claim"
  | Refused Blank_trace -> "refused: blank trace"
  | Refused Malformed_derivation -> "refused: malformed derivation"
  | Refused (Premises_missing missing) -> "refused: premises missing " ^ String.concat "," missing
;;

let removal_text : Effects.removal -> string = function
  | Dropped { reason } -> "dropped: " ^ reason
  | Merged_into successor -> "merged into " ^ successor
  | Revised_into successor -> "revised into " ^ successor
  | Superseded_by successor -> "superseded by " ^ successor
  | Retracted { by = Keeper; reason } -> "retracted by the keeper: " ^ reason
  | Retracted { by = Operator operator; reason } -> "retracted by " ^ operator ^ ": " ^ reason
  | Support_lost { missing } -> "support lost: " ^ String.concat "," missing
;;

let plan ?(by = Effects.Keeper) ?(facts = memory) write =
  Direct.plan ~by ~at ~trace_id:"turn" facts write
;;

let claims facts = List.map (fun (fact : Types.fact) -> fact.claim) facts

(* The outcome has to write. Its Memory is checked against the invariants a
   snapshot is read back with. *)
let written ?by ?(facts = memory) write =
  match plan ?by ~facts write with
  | Writes { facts = after; effects } ->
    let ids = List.map id after in
    check int "no fact is held twice" (List.length ids)
      (List.length (List.sort_uniq String.compare ids));
    check bool "every derived fact has its premises" true
      (List.for_all
         (fun (fact : Types.fact) ->
            match fact.basis with
            | Observed _ -> true
            | Derived derivations ->
              List.exists
                (fun (derivation : Types.derivation) ->
                   List.for_all (fun premise -> List.mem premise ids) derivation.premise_ids)
                derivations)
         after);
    check (list string) "the effects are the whole change" (claims after)
      (claims (Effects.apply ~at facts effects));
    check int "a direct write leaves no op out" 0 (List.length effects.not_applied);
    check int "a direct write names no unit" 0 (List.length effects.sources);
    after, effects
  | (Already_held | Already_done | Already_absent | Refused _) as other ->
    fail ("expected a write, got: " ^ outcome_text other)
;;

let removed (effects : Effects.t) =
  List.map
    (fun ((fact : Types.fact), removal) -> fact.claim, removal_text removal)
    effects.removed
;;

let outcome ?facts write = outcome_text (plan ?facts write)
let remember claim = Direct.Remember { claim; category = Types.Constraint; basis = transcript }

let supersede old claim =
  Direct.Supersede { old = id old; claim; category = Types.Constraint; basis = transcript }
;;

let test_remember_adds () =
  let after, effects = written (remember "the probe runs every minute") in
  check (list string) "the claim follows what was held"
    [ port.claim; owner.claim; "the probe runs every minute" ]
    (claims after);
  match effects.added with
  | [ fact ] ->
    check (float 0.0) "first seen when written" at fact.first_seen;
    check (float 0.0) "last seen when written" at fact.last_seen;
    check bool "authored" true
      (match fact.origin.kind with
       | Authored -> true
       | Injected -> false);
    check string "from the turn that wrote it" "turn" fact.origin.trace_id;
    check (list string) "nothing is touched" [] effects.touched;
    check (list (pair string string)) "nothing leaves" [] (removed effects)
  | [] | _ :: _ :: _ -> fail "one fact is added"
;;

let test_remember_held_moves_last_seen () =
  let after, effects = written (remember port.claim) in
  check (list string) "touched" [ id port ] effects.touched;
  check int "nothing is added" 0 (List.length effects.added);
  match List.find_opt (fun fact -> String.equal (id fact) (id port)) after with
  | Some (fact : Types.fact) ->
    check (float 0.0) "last seen moved" at fact.last_seen;
    check (float 0.0) "first seen kept" 100.0 fact.first_seen;
    check bool "the origin is not repainted" true
      (match fact.origin.kind with
       | Injected -> true
       | Authored -> false)
  | None -> fail "the held claim is gone"
;;

let test_remember_held_otherwise () =
  check string "another category" "already held"
    (outcome
       (Direct.Remember { claim = port.claim; category = Types.Lesson; basis = transcript }));
  check string "another basis" "already held"
    (outcome
       (Direct.Remember
          { claim = port.claim
          ; category = Types.Constraint
          ; basis = Types.Derived [ rule [ owner ] ]
          }))
;;

let test_supersede () =
  let after, effects = written (supersede port "the port is 9000") in
  check (list string) "the old claim left and the new one arrived"
    [ owner.claim; "the port is 9000" ]
    (claims after);
  check (list (pair string string)) "superseded by the new claim"
    [ port.claim, "superseded by " ^ id_of_claim "the port is 9000" ]
    (removed effects)
;;

let test_supersede_into_a_held_claim () =
  let after, effects = written (supersede port owner.claim) in
  check (list string) "only the old claim left" [ owner.claim ] (claims after);
  check (list string) "the held claim is seen again" [ id owner ] effects.touched;
  check int "nothing is added" 0 (List.length effects.added);
  check (list (pair string string)) "superseded by the held claim"
    [ port.claim, "superseded by " ^ id owner ]
    (removed effects)
;;

(* The claim that replaces a fact is first seen when that fact was. A claim
   Memory already holds keeps its own first seen. *)
let older : Types.fact =
  { (observed "the port was 8000") with first_seen = 50.0; last_seen = 60.0 }
;;

let seen_of claim facts =
  match List.find_opt (fun (fact : Types.fact) -> String.equal fact.claim claim) facts with
  | Some (fact : Types.fact) -> fact.first_seen, fact.last_seen
  | None -> fail ("not held: " ^ claim)
;;

let test_supersede_keeps_the_age () =
  let facts = older :: memory in
  let after, (_ : Effects.t) = written ~facts (supersede older "the port is 9000") in
  check (pair (float 0.0) (float 0.0)) "first seen when the old fact was, last seen now"
    (50.0, at)
    (seen_of "the port is 9000" after);
  let after, (_ : Effects.t) = written ~facts (supersede older owner.claim) in
  check (pair (float 0.0) (float 0.0)) "a held claim keeps its own first seen"
    (100.0, at)
    (seen_of owner.claim after)
;;

let test_supersede_without_the_old_fact () =
  let gone = observed "the port is 8000" in
  check string "the new claim is held" "already done" (outcome (supersede gone owner.claim));
  check string "neither is held" "refused: unknown fact"
    (outcome (supersede gone "the port is 9000"))
;;

let test_supersede_itself () =
  check string "the claim is the old fact" "refused: supersedes itself"
    (outcome (supersede port port.claim))
;;

let test_retract () =
  let after, effects =
    written (Direct.Retract { id = id port; reason = "the port moved" })
  in
  check (list string) "the fact left" [ owner.claim ] (claims after);
  check (list (pair string string)) "by the keeper"
    [ port.claim, "retracted by the keeper: the port moved" ]
    (removed effects);
  let (_ : Types.fact list), by_operator =
    written ~by:(Effects.Operator "operator-1")
      (Direct.Retract { id = id port; reason = "wrong" })
  in
  check (list (pair string string)) "by the operator"
    [ port.claim, "retracted by operator-1: wrong" ]
    (removed by_operator)
;;

let test_retract_absent () =
  check string "not held" "already absent"
    (outcome (Direct.Retract { id = id_of_claim "never written"; reason = "wrong" }))
;;

let test_retract_takes_what_rested_on_it () =
  let rests = derived "requests go to 8935" [ port ] in
  let further = derived "the probe asks 8935" [ rests ] in
  let after, effects =
    written ~facts:[ port; owner; rests; further ]
      (Direct.Retract { id = id port; reason = "the port moved" })
  in
  check (list string) "what rested on it left with it" [ owner.claim ] (claims after);
  check (list (pair string string)) "each with its reason"
    [ port.claim, "retracted by the keeper: the port moved"
    ; rests.claim, "support lost: " ^ id port
    ; further.claim, "support lost: " ^ id rests
    ]
    (removed effects)
;;

let test_derived_claim_needs_its_premises () =
  let absent = observed "the port is 8000" in
  check string "a premise Memory does not hold"
    ("refused: premises missing " ^ id absent)
    (outcome
       (Direct.Remember
          { claim = "requests go to 8000"
          ; category = Types.Lesson
          ; basis = Types.Derived [ rule [ absent ] ]
          }));
  check string "a claim derived from the fact it supersedes"
    ("refused: premises missing " ^ id port)
    (outcome
       (Direct.Supersede
          { old = id port
          ; claim = "requests go to 8935"
          ; category = Types.Lesson
          ; basis = Types.Derived [ rule [ port ] ]
          }));
  let after, (_ : Effects.t) =
    written
      (Direct.Remember
         { claim = "requests go to 8935"
         ; category = Types.Lesson
         ; basis = Types.Derived [ rule [ port ] ]
         })
  in
  check (list string) "a premise Memory holds"
    [ port.claim; owner.claim; "requests go to 8935" ]
    (claims after)
;;

let test_blank_claim () =
  check string "remember" "refused: blank claim" (outcome (remember " \n"));
  check string "supersede" "refused: blank claim" (outcome (supersede port ""))
;;

let test_blank_trace () =
  let on_no_trace write = outcome_text (Direct.plan ~by:Effects.Keeper ~at ~trace_id:" " memory write) in
  check string "remember" "refused: blank trace" (on_no_trace (remember "the probe runs every minute"));
  check string "retract" "refused: blank trace"
    (on_no_trace (Direct.Retract { id = id port; reason = "the port moved" }))
;;

let test_malformed_derivation () =
  check string "no derivation" "refused: malformed derivation"
    (outcome
       (Direct.Remember
          { claim = "requests go to 8935"; category = Types.Lesson; basis = Types.Derived [] }))
;;

let test_same_write_twice () =
  let write = supersede port "the port is 9000" in
  let after, (_ : Effects.t) = written write in
  check string "the second time it is already done" "already done" (outcome ~facts:after write);
  let retract = Direct.Retract { id = id port; reason = "the port moved" } in
  let after, (_ : Effects.t) = written retract in
  check string "the second retraction finds nothing" "already absent"
    (outcome ~facts:after retract)
;;

let () =
  run "librarian_direct"
    [ ( "remember"
      , [ test_case "a claim not held" `Quick test_remember_adds
        ; test_case "a held claim said the same way" `Quick test_remember_held_moves_last_seen
        ; test_case "a held claim said another way" `Quick test_remember_held_otherwise
        ] )
    ; ( "supersede"
      , [ test_case "the old fact is held" `Quick test_supersede
        ; test_case "into a held claim" `Quick test_supersede_into_a_held_claim
        ; test_case "the new claim is as old as the fact it replaces" `Quick
            test_supersede_keeps_the_age
        ; test_case "the old fact is not held" `Quick test_supersede_without_the_old_fact
        ; test_case "itself" `Quick test_supersede_itself
        ] )
    ; ( "retract"
      , [ test_case "a held fact" `Quick test_retract
        ; test_case "a fact not held" `Quick test_retract_absent
        ; test_case "what rested on it" `Quick test_retract_takes_what_rested_on_it
        ] )
    ; ( "support"
      , [ test_case "a derived claim needs its premises" `Quick
            test_derived_claim_needs_its_premises
        ; test_case "a malformed derivation" `Quick test_malformed_derivation
        ] )
    ; ( "what the snapshot cannot hold"
      , [ test_case "a blank claim" `Quick test_blank_claim
        ; test_case "a blank trace" `Quick test_blank_trace
        ] )
    ; "repeat", [ test_case "the same write twice" `Quick test_same_write_twice ]
    ]
;;
