(* What an answer does to Memory (RFC librarian-call-only-proposes §8.2
   step 1, §8.3). One case per rule. Every case also checks that the Memory
   the plan returns holds no fact twice and no derived fact without its
   premises: a snapshot with either is refused when it is read back. *)

open Alcotest
module Answer = Masc.Librarian_answer
module Effects = Masc.Librarian_effects
module Plan = Masc.Librarian_plan
module Question_id = Masc.Librarian_question_id
module Types = Masc.Keeper_memory_os_types

let asked =
  match
    Question_id.of_halves ~front:(String.make 32 'a') ~back:(String.make 32 'b')
  with
  | Some id -> id
  | None -> fail "the test question id is not two halves"
;;

let authored : Types.origin = { kind = Types.Authored; trace_id = "turn" }

let observed claim : Types.fact =
  { claim
  ; category = Types.Constraint
  ; first_seen = 100.0
  ; last_seen = 100.0
  ; origin = authored
  ; basis = Types.Observed Types.Transcript
  }
;;

let id = Types.memory_id
let id_of_claim = Types.memory_id_of_claim

let derived claim premises =
  match
    Types.derived ~claim ~category:Types.Lesson ~now:100.0 ~origin:authored
      ~derivations:[ { rule_id = "rule"; premise_ids = List.map id premises } ]
  with
  | Ok fact -> fact
  | Error detail -> fail detail
;;

let port = observed "the port is 8935"
let owner = observed "the owner is the release team"
let probe = observed "the probe runs every minute"
let memory = [ port; owner; probe ]
let at = 500.0

let names_of facts = List.mapi (fun index fact -> Printf.sprintf "m%d" (index + 1), id fact) facts

let shown_of facts : Plan.shown =
  Read (Range { memory = names_of facts; units = [ "u1", 10; "u2", 20 ] })
;;

let stated ?(from_units = []) claim : Answer.new_fact =
  { claim; category = Types.Fact; observation = Types.Transcript; from_units }
;;

let claims facts = List.map (fun (fact : Types.fact) -> fact.claim) facts

let removal_text : Effects.removal -> string = function
  | Dropped { reason } -> "dropped: " ^ reason
  | Merged_into successor -> "merged into " ^ successor
  | Revised_into successor -> "revised into " ^ successor
  | Superseded_by successor -> "superseded by " ^ successor
  | Retracted { by = Keeper; reason } -> "retracted by the keeper: " ^ reason
  | Retracted { by = Operator operator; reason } -> "retracted by " ^ operator ^ ": " ^ reason
  | Support_lost { missing } -> "support lost: " ^ String.concat "," missing
;;

let why_text : Effects.why_not -> string = function
  | Unknown_ref -> "unknown ref"
  | Ref_used_twice -> "ref used twice"
  | Source_outside_question -> "source outside question"
  | Removed_during_flight { seq } -> Printf.sprintf "removed during flight at %d" seq
  | Not_valid_alone -> "not valid alone"
  | Not_valid_in_room -> "not valid in room"
  | Successor_unsupported -> "successor unsupported"
;;

let removed (plan : Plan.t) =
  List.map
    (fun ((fact : Types.fact), removal) -> fact.claim, removal_text removal)
    plan.effects.removed
;;

let not_applied (plan : Plan.t) =
  List.map
    (fun (number, why, carried) ->
       ( number
       , why_text why
       , Option.map (fun (fact : Answer.new_fact) -> fact.claim) carried ))
    plan.effects.not_applied
;;

let plan ?shown ?(facts = memory) ?(removed_since = []) ?(working_state = Answer.Keep) ops =
  let shown = Option.value shown ~default:(shown_of facts) in
  let result =
    Plan.of_answer ~shown ~facts ~removed_since ~at ~trace_id:"question"
      { question = asked; ops; working_state }
  in
  let ids = List.map id result.facts in
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
       result.facts);
  result
;;

let pairs = list (pair string string)
let refusals = list (triple int string (option string))

let test_add_new () =
  let result = plan [ Add (stated ~from_units:[ "u2"; "u1"; "u2" ] "the build is green") ] in
  check (list string) "appended after what was held"
    (claims memory @ [ "the build is green" ])
    (claims result.facts);
  (match result.effects.added with
   | [ fact ] ->
     check (float 0.0) "first seen at the commit" at fact.first_seen;
     check (float 0.0) "last seen at the commit" at fact.last_seen;
     check string "origin" "question" fact.origin.trace_id;
     check bool "injected, not authored" true (fact.origin.kind = Types.Injected)
   | added -> failf "expected one added fact, got %d" (List.length added));
  check
    (list (pair string (list int)))
    "unit offsets, ascending, none twice"
    [ id_of_claim "the build is green", [ 10; 20 ] ]
    result.effects.sources
;;

let test_add_held_only_moves_last_seen () =
  let result = plan [ Add (stated ~from_units:[ "u1" ] port.claim) ] in
  check (list string) "nothing added" [] (claims result.effects.added);
  check (list string) "touched" [ id port ] result.effects.touched;
  match result.facts with
  | first :: _ ->
    check (float 0.0) "last seen moves" at first.last_seen;
    check (float 0.0) "first seen stays" 100.0 first.first_seen;
    check bool "an authored row is not repainted" true (first.origin.kind = Types.Authored);
    check string "category stays" "constraint" (Types.category_to_string first.category)
  | [] -> fail "Memory is empty"
;;

(* Without a unit the held claim is the question's Memory read back. *)
let test_add_held_without_a_unit_changes_nothing () =
  let result = plan [ Add (stated port.claim) ] in
  check (list string) "nothing added" [] (claims result.effects.added);
  check (list string) "not touched" [] result.effects.touched;
  match result.facts with
  | first :: _ -> check (float 0.0) "last seen stays" 100.0 first.last_seen
  | [] -> fail "Memory is empty"
;;

let test_drop () =
  let result = plan [ Drop { ref_ = "m2"; reason = "the team changed" } ] in
  check (list string) "the fact left" [ port.claim; probe.claim ] (claims result.facts);
  check pairs "kept on the line with its reason"
    [ owner.claim, "dropped: the team changed" ]
    (removed result)
;;

let test_merge () =
  let merged = "the port is 8935 and the probe checks it every minute" in
  let result = plan [ Merge { refs = [ "m1"; "m3" ]; into = stated merged } ] in
  check (list string) "sources leave, the new fact follows" [ owner.claim; merged ]
    (claims result.facts);
  check pairs "each source names what replaced it"
    [ port.claim, "merged into " ^ id_of_claim merged
    ; probe.claim, "merged into " ^ id_of_claim merged
    ]
    (removed result)
;;

(* The model keeps one of the sources by writing its sentence again. *)
let test_merge_into_one_of_the_sources () =
  let result =
    plan [ Merge { refs = [ "m1"; "m3" ]; into = stated ~from_units:[ "u1" ] port.claim } ]
  in
  check (list string) "the kept source stays in place" [ port.claim; owner.claim ]
    (claims result.facts);
  check pairs "only the other source leaves" [ probe.claim, "merged into " ^ id port ]
    (removed result);
  check (list string) "the kept source is seen again" [ id port ] result.effects.touched
;;

let test_revise () =
  let result = plan [ Revise { ref_ = "m1"; into = stated "the port is 8936" } ] in
  check (list string) "replaced" [ owner.claim; probe.claim; "the port is 8936" ]
    (claims result.facts);
  check pairs "the old claim names the new one"
    [ port.claim, "revised into " ^ id_of_claim "the port is 8936" ]
    (removed result)
;;

(* Memory that has known something for a month still has after the
   Librarian folds it into one sentence. *)
let seen_since first_seen claim : Types.fact = { (observed claim) with first_seen }

let seen_between first_seen last_seen claim : Types.fact =
  { (observed claim) with first_seen; last_seen }

let added_fact (result : Plan.t) claim =
  match
    List.find_opt (fun (fact : Types.fact) -> String.equal fact.claim claim) result.effects.added
  with
  | Some fact -> fact
  | None -> failf "%S was not added" claim
;;

let test_merge_keeps_the_earliest_first_seen () =
  let older = seen_between 40.0 60.0 "the deploy runs on friday" in
  let newer = seen_between 90.0 95.0 "the deploy needs the release team" in
  let facts = [ older; newer; probe ] in
  let merged = "the release team runs the deploy on friday" in
  let merge from_units =
    plan ~facts [ Merge { refs = [ "m2"; "m1" ]; into = stated ~from_units merged } ]
  in
  let fact = added_fact (merge []) merged in
  check (float 0.0) "first seen when the oldest source was" 40.0 fact.first_seen;
  check (float 0.0) "no unit, last seen when the newest source was" 95.0 fact.last_seen;
  let fact = added_fact (merge [ "u2" ]) merged in
  check (float 0.0) "first seen stays with a unit" 40.0 fact.first_seen;
  check (float 0.0) "a unit is evidence, last seen at the commit" at fact.last_seen
;;

let test_revise_keeps_the_first_seen () =
  let facts = [ seen_since 70.0 "the port is 8935"; owner ] in
  let result =
    plan ~facts [ Revise { ref_ = "m1"; into = stated "the port is 8936" } ]
  in
  let fact = added_fact result "the port is 8936" in
  check (float 0.0) "first seen when the revised fact was" 70.0 fact.first_seen;
  check (float 0.0) "no unit, last seen when the revised fact was" 100.0 fact.last_seen
;;

let test_one_flawed_op_leaves_the_others () =
  let result =
    plan
      [ Drop { ref_ = "m9"; reason = "no such fact" }
      ; Add (stated ~from_units:[ "u7" ] "read from a unit that was not shown")
      ; Drop { ref_ = "m2"; reason = "the team changed" }
      ; Revise { ref_ = "m2"; into = stated "the owner is the platform team" }
      ]
  in
  check refusals "each flaw is recorded with its op number"
    [ 0, "unknown ref", None
    ; 1, "source outside question", Some "read from a unit that was not shown"
    ; 3, "ref used twice", Some "the owner is the platform team"
    ]
    (not_applied result);
  check pairs "the sound op applied" [ owner.claim, "dropped: the team changed" ] (removed result);
  check (list string) "a refused op's claim is not added" [ port.claim; probe.claim ]
    (claims result.facts)
;;

(* A name is spent only by an op that passed: a refused op does not block
   a later one from naming the same fact. *)
let test_a_refused_op_does_not_spend_its_names () =
  let result =
    plan
      [ Merge { refs = [ "m1"; "m9" ]; into = stated "two facts in one" }
      ; Drop { ref_ = "m1"; reason = "moved" }
      ]
  in
  check refusals "the merge is refused" [ 0, "unknown ref", Some "two facts in one" ]
    (not_applied result);
  check pairs "the drop applies" [ port.claim, "dropped: moved" ] (removed result)
;;

let test_removed_during_flight () =
  let retracted = observed "the token is in the readme" in
  let shown = shown_of (memory @ [ retracted ]) in
  let result =
    plan ~shown
      ~removed_since:[ id retracted, 41 ]
      [ Revise { ref_ = "m4"; into = stated "the token is in the vault" }
      ; Add (stated retracted.claim)
      ; Drop { ref_ = "m2"; reason = "the team changed" }
      ; Seen { ref_ = "m4"; from_units = [ "u1" ] }
      ]
  in
  check refusals "the ops that name or restate the retracted fact are left out"
    [ 0, "removed during flight at 41", Some "the token is in the vault"
    ; 1, "removed during flight at 41", Some retracted.claim
    ; 3, "removed during flight at 41", None
    ]
    (not_applied result);
  check (list string) "the retraction is not undone and the rest applies"
    [ port.claim; probe.claim ]
    (claims result.facts)
;;

let test_alone () =
  let shown : Plan.shown = Read (Item_alone { units = [ "u1", 10 ] }) in
  let result =
    plan ~shown ~working_state:(Answer.Set "replaced without having seen it")
      [ Add (stated ~from_units:[ "u1" ] "the build is green")
      ; Drop { ref_ = "m1"; reason = "guessed" }
      ; Revise { ref_ = "m1"; into = stated "guessed again" }
      ]
  in
  check refusals "only an add is taken from an answer that saw no Memory"
    [ 1, "not valid alone", None; 2, "not valid alone", Some "guessed again" ]
    (not_applied result);
  check (list string) "the add applies" (claims memory @ [ "the build is green" ])
    (claims result.facts);
  check bool "the attempt on the working state is its own case" true
    (result.working_state = Plan.Alone Not_valid_alone);
  let kept = plan ~shown [ Add (stated "the build is green") ] in
  check bool "an answer that left it alone" true (kept.working_state = Plan.Alone Untouched)
;;

(* Memory and no unit (§7.4 「자리 내기」): the answer names facts it was
   shown and reads nothing new. *)
let test_room () =
  let shown : Plan.shown = Room { memory = names_of memory } in
  let merged = "the port is 8935 and the probe runs every minute" in
  let result =
    plan ~shown ~working_state:(Answer.Set "")
      [ Add (stated "nothing was read")
      ; Merge { refs = [ "m1"; "m3" ]; into = stated merged }
      ; Seen { ref_ = "m2"; from_units = [ "u1" ] }
      ; Drop { ref_ = "m2"; reason = "the team changed" }
      ]
  in
  check refusals "an add and a seen need a unit, so they are left out"
    [ 0, "not valid in room", Some "nothing was read"; 2, "not valid in room", None ]
    (not_applied result);
  check (list string) "the merge and the drop apply" [ merged ] (claims result.facts);
  check bool "the working state is the answer's" true (result.working_state = Plan.Replaced "")
;;

let test_working_state_passes_through () =
  let result = plan ~working_state:(Answer.Set "next: rerun the probe") [] in
  check bool "set" true (result.working_state = Plan.Replaced "next: rerun the probe");
  check bool "keep" true ((plan []).working_state = Plan.Kept);
  check (list string) "an answer with no ops changes nothing" (claims memory)
    (claims result.facts)
;;

let test_support_lost () =
  let lesson = derived "the probe must call 8935" [ port ] in
  let facts = memory @ [ lesson ] in
  let result = plan ~facts [ Drop { ref_ = "m1"; reason = "the port moved" } ] in
  check pairs "the derived fact leaves on the same line"
    [ port.claim, "dropped: the port moved"; lesson.claim, "support lost: " ^ id port ]
    (removed result);
  check (list string) "Memory" [ owner.claim; probe.claim ] (claims result.facts)
;;

(* The claim the merge states is already held as a fact derived from the
   merge's own source. Removing the source would take the stated fact with
   it, so the merge is withdrawn and nothing is lost. *)
let test_successor_unsupported () =
  let lesson = derived "the probe must call 8935" [ port ] in
  let facts = memory @ [ lesson ] in
  let result =
    plan ~facts
      [ Merge { refs = [ "m1" ]; into = stated lesson.claim }
      ; Drop { ref_ = "m2"; reason = "the team changed" }
      ]
  in
  check refusals "the merge is withdrawn with its op number"
    [ 0, "successor unsupported", Some lesson.claim ]
    (not_applied result);
  check pairs "only the unrelated drop removed a fact"
    [ owner.claim, "dropped: the team changed" ]
    (removed result);
  check (list string) "source and stated fact both stay" [ port.claim; probe.claim; lesson.claim ]
    (claims result.facts);
  check (list string) "a withdrawn op touches nothing" [] result.effects.touched
;;

(* Several ops state one new claim from different units: one fact, and the
   units of all of them. *)
let test_two_ops_state_one_claim () =
  let result =
    plan
      [ Add (stated ~from_units:[ "u2" ] "the build is green")
      ; Add (stated ~from_units:[ "u1"; "u2" ] "the build is green")
      ; Add (stated ~from_units:[ "u1" ] "the build is green")
      ]
  in
  check (list string) "one fact" (claims memory @ [ "the build is green" ]) (claims result.facts);
  check int "added once" 1 (List.length result.effects.added);
  check (list (pair string (list int))) "the units of every op, ascending, none twice"
    [ id_of_claim "the build is green", [ 10; 20 ] ]
    result.effects.sources;
  check refusals "every op applied" [] (not_applied result)
;;

(* Withdrawing one op can take the ground from under another.

   The first merge states a lesson derived from the port and removes the
   port, so it is withdrawn. While it was live it had also removed the second
   lesson, which let the second merge add that claim as a new observed fact.
   With the first merge gone the second lesson is back as the derived fact it
   was, and the second merge removes its only premise. *)
let test_withdrawal_runs_until_nothing_changes () =
  let port_lesson = derived "the probe must call 8935" [ port ] in
  let owner_lesson = derived "ask the release team first" [ owner ] in
  let facts = memory @ [ port_lesson; owner_lesson ] in
  let result =
    plan ~facts
      [ Merge { refs = [ "m5"; "m1" ]; into = stated port_lesson.claim }
      ; Merge { refs = [ "m2" ]; into = stated owner_lesson.claim }
      ]
  in
  check refusals "both merges are withdrawn"
    [ 0, "successor unsupported", Some port_lesson.claim
    ; 1, "successor unsupported", Some owner_lesson.claim
    ]
    (not_applied result);
  check pairs "nothing is removed" [] (removed result);
  check (list string) "Memory is as it was" (claims facts) (claims result.facts);
  check int "nothing is added" 0 (List.length result.effects.added)
;;

(* An add that states a held derived fact, in an answer that also drops the
   fact's premise. The fact leaves, and the add is on the line as an op that
   did not take: it is not counted as having seen the fact again. *)
let test_support_lost_takes_a_stated_fact () =
  let lesson = derived "the probe must call 8935" [ port ] in
  let facts = memory @ [ lesson ] in
  let result =
    plan ~facts
      [ Drop { ref_ = "m1"; reason = "the port moved" }
      ; Add (stated ~from_units:[ "u1" ] lesson.claim)
      ]
  in
  check pairs "the premise and the derived fact leave"
    [ port.claim, "dropped: the port moved"; lesson.claim, "support lost: " ^ id port ]
    (removed result);
  check refusals "the add is recorded with its op number"
    [ 1, "successor unsupported", Some lesson.claim ]
    (not_applied result);
  check (list string) "a fact that left is not touched" [] result.effects.touched;
  check (list (pair string (list int))) "and has no source" [] result.effects.sources
;;

(* Seen again by name: no copy of the claim, so no near copy of the fact. *)
let test_seen_moves_last_seen () =
  let result = plan [ Seen { ref_ = "m1"; from_units = [ "u2"; "u1" ] } ] in
  check (list string) "nothing added" [] (claims result.effects.added);
  check (list string) "touched" [ id port ] result.effects.touched;
  check (list (pair string (list int))) "the units that said it again"
    [ id port, [ 10; 20 ] ] result.effects.sources;
  check refusals "nothing refused" [] (not_applied result);
  match result.facts with
  | first :: _ ->
    check string "the same fact" port.claim first.claim;
    check (float 0.0) "last seen moves" at first.last_seen;
    check (float 0.0) "first seen stays" 100.0 first.first_seen
  | [] -> fail "Memory is empty"
;;

let test_seen_is_screened () =
  let result =
    plan
      [ Seen { ref_ = "m9"; from_units = [ "u1" ] }
      ; Seen { ref_ = "m2"; from_units = [ "u9" ] }
      ; Drop { ref_ = "m3"; reason = "the probe stopped" }
      ; Seen { ref_ = "m3"; from_units = [ "u1" ] }
      ; Seen { ref_ = "m1"; from_units = [ "u1" ] }
      ]
  in
  check refusals "each flaw is recorded, with no claim carried"
    [ 0, "unknown ref", None; 1, "source outside question", None; 3, "ref used twice", None ]
    (not_applied result);
  check (list string) "the sound seen applies" [ id port ] result.effects.touched;
  let alone : Plan.shown = Read (Item_alone { units = [ "u1", 10 ] }) in
  check refusals "an answer that saw no Memory cannot see a fact again"
    [ 0, "not valid alone", None ]
    (not_applied (plan ~shown:alone [ Seen { ref_ = "m1"; from_units = [ "u1" ] } ]))
;;

let test_seen_of_a_fact_that_loses_support () =
  let lesson = derived "the probe must call 8935" [ port ] in
  let facts = memory @ [ lesson ] in
  let result =
    plan ~facts
      [ Drop { ref_ = "m1"; reason = "the port moved" }
      ; Seen { ref_ = "m4"; from_units = [ "u1" ] }
      ]
  in
  check pairs "the premise and the derived fact leave"
    [ port.claim, "dropped: the port moved"; lesson.claim, "support lost: " ^ id port ]
    (removed result);
  check refusals "the seen is withdrawn" [ 1, "successor unsupported", None ]
    (not_applied result);
  check (list string) "a fact that left is not touched" [] result.effects.touched;
  check (list (pair string (list int))) "and has no source" [] result.effects.sources
;;

let test_dropped_and_stated_again () =
  let result =
    plan [ Drop { ref_ = "m1"; reason = "stale" }; Add (stated port.claim) ]
  in
  check pairs "the held fact leaves" [ port.claim, "dropped: stale" ] (removed result);
  check (list string) "and the claim is added as a new fact"
    [ owner.claim; probe.claim; port.claim ]
    (claims result.facts)
;;

let test_same_input_same_plan () =
  let run () =
    plan
      [ Add (stated ~from_units:[ "u1" ] "the build is green")
      ; Merge { refs = [ "m1"; "m3" ]; into = stated "port and probe" }
      ]
  in
  let encode (result : Plan.t) =
    String.concat "\n"
      (List.map (fun fact -> Yojson.Safe.to_string (Types.fact_to_json fact)) result.facts)
  in
  check string "bytes" (encode (run ())) (encode (run ()))
;;

let () =
  run "librarian_plan"
    [ ( "ops"
      , [ test_case "add a new claim" `Quick test_add_new
        ; test_case "add a held claim" `Quick test_add_held_only_moves_last_seen
        ; test_case "a held claim without a unit" `Quick
            test_add_held_without_a_unit_changes_nothing
        ; test_case "drop" `Quick test_drop
        ; test_case "merge" `Quick test_merge
        ; test_case "merge into one of the sources" `Quick test_merge_into_one_of_the_sources
        ; test_case "revise" `Quick test_revise
        ; test_case "a merge keeps the earliest first seen" `Quick
            test_merge_keeps_the_earliest_first_seen
        ; test_case "a revision keeps the first seen" `Quick test_revise_keeps_the_first_seen
        ; test_case "seen again by name" `Quick test_seen_moves_last_seen
        ; test_case "dropped and stated again" `Quick test_dropped_and_stated_again
        ; test_case "two ops state one claim" `Quick test_two_ops_state_one_claim
        ] )
    ; ( "screening"
      , [ test_case "one flawed op leaves the others" `Quick
            test_one_flawed_op_leaves_the_others
        ; test_case "a refused op does not spend its names" `Quick
            test_a_refused_op_does_not_spend_its_names
        ; test_case "removed during flight" `Quick test_removed_during_flight
        ; test_case "an answer that saw no Memory" `Quick test_alone
        ; test_case "an answer that saw Memory and no unit" `Quick test_room
        ; test_case "working state" `Quick test_working_state_passes_through
        ; test_case "a seen is screened as a named op" `Quick test_seen_is_screened
        ] )
    ; ( "support"
      , [ test_case "a derived fact loses its premise" `Quick test_support_lost
        ; test_case "a stated fact loses its premise" `Quick
            test_support_lost_takes_a_stated_fact
        ; test_case "withdrawing one op withdraws another" `Quick
            test_withdrawal_runs_until_nothing_changes
        ; test_case "a seen fact loses its premise" `Quick
            test_seen_of_a_fact_that_loses_support
        ; test_case "a merge that would lose its own successor" `Quick
            test_successor_unsupported
        ] )
    ; "purity", [ test_case "same input, same plan" `Quick test_same_input_same_plan ]
    ]
;;
