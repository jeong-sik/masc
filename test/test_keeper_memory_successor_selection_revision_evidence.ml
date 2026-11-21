open Alcotest
module Selection = Masc.Keeper_memory_successor_selection
module Current = Masc.Keeper_memory_os_current
module Memory = Masc.Keeper_memory_os_types
module Jev = Masc.Typesafeai_types

let fact claim = Memory.observed ~claim ~category:Memory.Fact ~now:100.
  ~origin:{kind=Memory.Authored;trace_id="successor-fixture"}
let candidate : Current.successor_recall_candidate =
  let original_target = fact "Production releases R-001 through R-200 require owner approval." in
  let target = fact "Production R-015 now requires two independent approvals; other releases retain owner approval." in
  {binding={candidate_id={queue_generation="generation";request_id="request";sequence=15;
      input_sha256=String.make 64 'a'};
    source_fact=fact "Production R-015 requires owner approval.";
    target_memory_id=Memory.memory_id original_target};
   born_revision=1;original_target;target;
   path=[{snapshot_revision=2;recorded_at=200.;source={kind=Current.Librarian;trace_id="revision"};
     commit_effect=Some Current.Rewritten;
     revision_links=Some [{superseded=Memory.memory_id original_target;superseded_by=Memory.memory_id target}];
     removed_memory_ids=[Memory.memory_id original_target];added_memory_ids=[Memory.memory_id target]}];
   program_steps=[]}
let response choice : Jev.eval_response =
  {model="fixture";usage=None;answers=["applicability",Jev.Choice_answer
    {choice;confidence=1.;probabilities=List.map (fun label -> label,if label=choice then 1. else 0.)
      ["applies_to_query";"different_scope";"uncertain"]}]}

let roundtrip_candidate : Current.successor_recall_candidate =
  let original = candidate.original_target and intermediate = candidate.target in
  let step stage_index from_fact into_fact relation : Current.successor_program_step =
    {program_revision=2;transaction_id="successor-roundtrip";stage_index;
     from_fact;into_fact;relation} in
  {candidate with target=original;
    path=[{snapshot_revision=2;recorded_at=200.;
      source={kind=Current.Librarian;trace_id="ordered-roundtrip"};
      commit_effect=Some Current.Rewritten;revision_links=Some [];
      removed_memory_ids=[];added_memory_ids=[]}];
    program_steps=[step 0 original intermediate Current.Program_absorption;
      step 1 intermediate original Current.Program_revision]}

let test_roundtrip_program_evidence_reaches_semantic_judgment () =
  let original = roundtrip_candidate.original_target and intermediate = candidate.target in
  let endpoint fact = Memory.fact_to_json fact in
  let expected_steps = `List
    [`Assoc ["snapshot_revision",`Int 2;"transaction_id",`String "successor-roundtrip";
       "stage_index",`Int 0;"from_fact",endpoint original;"into_fact",endpoint intermediate;
       "relation",`String "absorption"];
     `Assoc ["snapshot_revision",`Int 2;"transaction_id",`String "successor-roundtrip";
       "stage_index",`Int 1;"from_fact",endpoint intermediate;"into_fact",endpoint original;
       "relation",`String "revision"]] in
  List.iter (fun (choice,applies) ->
    let calls = ref 0 in
    let evaluate ~state ~questions:_ =
      incr calls;
      let member = Yojson.Safe.Util.member in
      let evidence = member "evidence" state in
      check bool "the actual scope request retains the original historical observation" true
        (member "historical_source" evidence=endpoint candidate.binding.source_fact);
      check bool "the current endpoint is the restored A, not the historical intermediate B" true
        (member "original_target" evidence=endpoint original
         && member "current_target" evidence=endpoint original);
      check bool "the actual request preserves both ordered A-to-B-to-A edge witnesses" true
        (member "ordered_program_steps" evidence=expected_steps);
      check bool "two local stages retain only one actual durable revision" true
        (member "committed_revision_path" evidence=
         `List (List.map Current.revision_evidence_to_json roundtrip_candidate.path));
      Ok (response choice) in
    let result = Selection.select_with_evaluate ~evaluate ~query:"R-015"
      [roundtrip_candidate] in
    check int "one scope judgment is requested for the entire path" 1 !calls;
    if applies then
      check bool "an applicable roundtrip selects only the current target with its full witness" true
        (result.selected=[roundtrip_candidate] && result.unresolved=[])
    else
      match result.selected,result.unresolved with
      | [],[observed,Selection.Judgment_uncertain] ->
        check bool "uncertainty retains the entire historical path without selecting it" true
          (observed=roundtrip_candidate)
      | _ -> fail "an uncertain roundtrip became current knowledge or conclusive absence")
    ["applies_to_query",true;"uncertain",false]

let () = run "keeper_memory_successor_selection_revision_evidence"
  ["judgment",[
    test_case "ordered roundtrip endpoints reach semantic judgment and preserve uncertainty" `Quick test_roundtrip_program_evidence_reaches_semantic_judgment]]
