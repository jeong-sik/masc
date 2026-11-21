open Masc

let consumed_source =
  {Keeper_librarian_context.reference="consumed"; content=`String "An answered question"}

let () =
  let prompt_shape name input expected =
    Alcotest.test_case name `Quick (fun () ->
      Alcotest.(check bool) "eligibility reads the prompt" expected
        (Keeper_librarian_context.shows_no_working_context input);
      Alcotest.(check bool) "the prompt matches the empty projection" expected
        (Yojson.Safe.equal (Keeper_librarian_context.prompt_json input)
           (Keeper_librarian_context.prompt_json Keeper_librarian_context.empty))) in
  let prior = {Keeper_librarian_context.generation="fixture"; revision=1;
    execution_basis=Some "fixture-old-basis"; sources=[consumed_source];
    pockets=[{Keeper_librarian_context.id="fixture"; merge_contexts=[]; sources=["consumed"];
      context="The answered question"; next_steps=[]; completeness=Current}]} in
  Alcotest.run "Librarian JEV preflight"
    ["prompt projection", [
      prompt_shape "empty" Keeper_librarian_context.empty true;
      prompt_shape "running keeper with nothing pending"
        {Keeper_librarian_context.sources=[]; previous=Some prior; unavailable=[];
         withheld=[]; execution_basis=Some "fixture-live-basis"} true;
      prompt_shape "pending source"
        {Keeper_librarian_context.empty with sources=[consumed_source]} false;
      prompt_shape "unavailable source"
        {Keeper_librarian_context.empty with unavailable=["events: fixture"]} false]]
